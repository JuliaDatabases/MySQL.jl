# Connection establishment: one monotonic deadline from name resolution through the utf8mb4
# bootstrap; STARTTLS policy; authentication; finalizer-safe ownership via the reaper.

"""
    Handle

Owner of a `Protocol.Session`. Close it with `close!` (best-effort COM_QUIT, then the
transport). A `Handle` that is dropped without being closed is reclaimed by the reaper
(`reap_now!`/timer), never by finalizer I/O.
"""
mutable struct Handle
    session::P.Session
    options::ConnectOptions
    entry::ReapEntry
    bootstrapped::Bool
    auth_trace::Vector{Symbol}
end

Base.isopen(h::Handle) = return isopen(h.session)

@noinline function finalize_handle(h::Handle)
    enqueue_from_finalizer!(h.entry) || trim_finalizer!(finalize_handle, h)
    return nothing
end

function register!(h::Handle)
    ensure_reaper!()
    TRIM_CALL_EDGE[] && finalize_handle(h)
    trim_finalizer!(finalize_handle, h)
    return h
end

"""
    close!(h::Handle)

Sends COM_QUIT when the session is idle, closes the transport, and retires the reaper entry.
"""
function close!(h::Handle)
    t = retire!(h.entry)
    t === nothing && return nothing
    P.quit!(h.session)
    return nothing
end

# `host:port` with IPv6 literals bracketed.
function hostport(host::AbstractString, port::Integer)
    h = String(host)
    (startswith(h, '[') && endswith(h, ']')) && return string(h, ":", port)
    return occursin(':', h) ? string("[", h, "]:", port) : string(h, ":", port)
end

deadline_from(connect_timeout::Union{Nothing, Int}) = return connect_timeout === nothing ? Int64(0) : P.deadline_after_ns(Int64(connect_timeout) * 1_000_000_000)

function remaining_ns(deadline::Int64)
    deadline == 0 && return Int64(0)
    left = deadline - Int64(time_ns())
    left > 0 || throw(P.TimeoutError("connect_timeout expired while establishing the connection"))
    return left
end

function apply_deadline!(t::P.Transport, deadline::Int64)
    P.set_read_deadline!(t, deadline)
    P.set_write_deadline!(t, deadline)
    return nothing
end

# A concrete channel element (tuple types are covariant, so `Tuple{Bool, Any}` is abstract
# and a `put!` with it cannot be statically resolved by `--trim`).
struct BindResolveOutcome
    ok::Bool
    value::Any
end

# A named functor (not a closure) runs the resolver on its own task; `resolve_bind` gives
# `--trim` a static call edge to this `@noinline` body so its specialization is emitted.
struct BindResolve{F}
    resolver::F
    address::String
    result::Channel{BindResolveOutcome}
end

@noinline function (t::BindResolve)()
    outcome = try
        BindResolveOutcome(true, t.resolver("tcp", t.address))
    catch err
        BindResolveOutcome(false, err)
    end
    put!(t.result, outcome)
    return nothing
end

function resolve_bind(
        bind::Union{Nothing, String},
        deadline::Int64,
        resolver::F=Reseau.HostResolvers.resolve_tcp_addrs,
    ) where {F}
    bind === nothing && return nothing
    address = hostport(bind, 0)
    deadline == 0 && return resolver("tcp", address)::Reseau.HostResolvers.ResolvedConnectAddrs
    timeout_message = "connect_timeout expired while resolving bind address $bind"
    result = Channel{BindResolveOutcome}(1)
    work = BindResolve(resolver, address, result)
    TRIM_CALL_EDGE[] && work()
    task = Task(work)
    task.sticky = false
    errormonitor(task)
    schedule(task)
    left = deadline - Int64(time_ns())
    left > 0 || throw(P.TimeoutError(timeout_message))
    seconds = left / 1_000_000_000
    status = timedwait(() -> isready(result), seconds; pollint=clamp(seconds, 0.001, 0.01))
    if status === :timed_out && !isready(result)
        throw(P.TimeoutError(timeout_message))
    end
    outcome = take!(result)
    wait(task)
    outcome.ok || throw(outcome.value)
    return outcome.value::Reseau.HostResolvers.ResolvedConnectAddrs
end

function dial_one(address::String, deadline::Int64, local_addr)
    deadline == 0 && return Reseau.TCP.connect(address; local_addr=local_addr)
    return Reseau.TCP.connect(address; timeout_ns=remaining_ns(deadline), local_addr=local_addr)
end

# A function barrier per resolved-address vector type (`ResolvedConnectAddrs` is a union of
# three concrete vector types) keeps the loop and each `dial_one` concretely typed.
function dial_with_bind(address::String, deadline::Int64, bind::String, local_addrs::Vector{T}) where {T}
    first_err = nothing
    for local_addr in local_addrs
        try
            return dial_one(address, deadline, local_addr)
        catch err
            (err isa P.TimeoutError || P.is_deadline_error(err)) && rethrow()
            first_err === nothing && (first_err = err)
        end
    end
    first_err === nothing && error("bind resolver returned no addresses for $bind")
    throw(first_err::Exception)
end

function dial(opts::ConnectOptions, deadline::Int64)
    address = hostport(opts.host, opts.port)
    try
        local_addrs = resolve_bind(opts.bind, deadline)
        local_addrs === nothing && return dial_one(address, deadline, nothing)
        bind = something(opts.bind, "")
        # explicit split: the resolved-addrs union stays concrete into the parametric barrier
        local_addrs isa Vector{Reseau.TCP.SocketAddrV4} && return dial_with_bind(address, deadline, bind, local_addrs)
        local_addrs isa Vector{Reseau.TCP.SocketAddrV6} && return dial_with_bind(address, deadline, bind, local_addrs)
        return dial_with_bind(address, deadline, bind, local_addrs::Vector{Reseau.TCP.SocketEndpoint})
    catch err
        P.is_deadline_error(err) && throw(P.TimeoutError("connect_timeout expired while connecting to $address"))
        rethrow()
    end
end

function charset_already_utf8mb4(ok::P.OKPacket)
    vars = Dict(P.system_variables(ok))
    for name in ("character_set_client", "character_set_connection", "character_set_results")
        get(vars, name, "") == UTF8MB4 || return false
    end
    return true
end

"""
    bootstrap_charset!(s, ok) -> Bool

The utf8mb4 contract: skipped when the connect OK's session tracking reports all three
`character_set_*` variables as utf8mb4, otherwise `SET NAMES utf8mb4` is executed and must
succeed. Returns whether the statement was sent.
"""
function bootstrap_charset!(s::P.Session, ok::P.OKPacket)
    P.guarded(() -> charset_already_utf8mb4(ok), s) && return false
    P.query!(s, "SET NAMES utf8mb4")
    response = P.read_command_response!(s; kind=P.CMD_SIMPLE)
    if !(response isa P.OKPacket) || s.phase != P.READY
        throw(P.fault!(s, P.ProtocolError("SET NAMES utf8mb4 did not return one final OK")))
    end
    return true
end

function resync_local_infile!(s::P.Session)
    P.send_local_infile!(s, nothing)
    try
        return P.read_command_response!(s)
    catch server_err
        server_err isa P.ServerError || rethrow()
        return server_err
    end
end
# ServerError is abstract (Error / StmtError); split before `sprint` so the call is
# statically resolvable.
@inline server_error_text(e::P.ServerError) = return e isa P.StmtError ? sprint(showerror, e) : sprint(showerror, e::P.Error)

@inline function throw_with_server_cause(err, cause::P.ServerError)
    try
        throw(cause)
    catch
        throw(err)
    end
end
# The user-supplied handler is a deliberately dynamic call, routed through the C runtime's
# generic dispatch entry so `--trim=safe` sees a resolvable ccall. In a trimmed executable a
# custom handler works only if its methods were compiled into the binary (call it from your
# entrypoint, or connect without a handler).
@inline function call_infile_handler(handler, filename::String)
    args = Any[filename]
    return GC.@preserve args ccall(:jl_apply_generic, Any, (Any, Ptr{Any}, UInt32), handler, pointer(args), UInt32(1))
end

# The handler's returned `IO` is a user type too: the upload send is routed through the
# same dynamic-dispatch entry (same trimmed-binary caveat as `call_infile_handler`).
@inline function call_send_local_infile(s::P.Session, source, max_bytes::Int)
    args = Any[(max_bytes=max_bytes,), P.send_local_infile!, s, source]
    return GC.@preserve args ccall(:jl_apply_generic, Any, (Any, Ptr{Any}, UInt32), Core.kwcall, pointer(args), UInt32(4))
end

function handle_local_infile!(handler::Union{Nothing, LocalInfileHandlerBox}, max_bytes::Int, s::P.Session, req::P.LocalInfileRequest)
    handler === nothing && throw(P.fault!(s, P.ProtocolError("the server requested a LOCAL INFILE upload but no local_infile_handler is configured")))
    filename = req.filename isa AbstractString ? String(req.filename) : String(copy(req.filename))
    source = try
        call_infile_handler(handler.f, filename)
    catch handler_err
        reply = resync_local_infile!(s)
        reply isa P.ServerError && throw_with_server_cause(handler_err, reply)
        rethrow()
    end
    if source === nothing
        reply = resync_local_infile!(s)
        detail = if reply isa P.ServerError
            "the server replied: $(server_error_text(reply))"
        else
            "the server accepted the empty upload"
        end
        cause = reply isa P.ServerError ? reply : nothing
        throw(P.LocalInfileRefused(filename, "the LOCAL INFILE upload of \"$filename\" was refused by local_infile_handler; $detail", cause))
    end
    if !(source isa IO)
        err = ArgumentError("local_infile_handler must return an IO or nothing, got $(typeof(source))")
        reply = resync_local_infile!(s)
        reply isa P.ServerError && throw_with_server_cause(err, reply)
        throw(err)
    end
    try
        call_send_local_infile(s, source, max_bytes)
    catch err
        if !P.is_terminal(s.phase)
            reply = resync_local_infile!(s)
            reply isa P.ServerError && throw_with_server_cause(err, reply)
        end
        rethrow()
    end
    return P.read_command_response!(s)
end
function run_init_command!(s::P.Session, opts::ConnectOptions)
    P.query!(s, opts.init_command)
    response = P.read_command_response!(s)
    while s.phase != P.READY
        if response isa P.LocalInfileRequest
            response = handle_local_infile!(opts.local_infile_handler, opts.max_local_infile_bytes, s, response)
        elseif s.phase == P.ROWS
            response = P.read_row!(s)
        elseif s.phase == P.RESULT_END
            response = P.next_result!(s)
        elseif s.phase == P.CMD_SENT
            response = P.read_command_response!(s)
        else
            P.wrong_phase(s, "an init_command response phase")
        end
    end
    return nothing
end

timeout_ns(seconds::Union{Nothing, Int}) = return seconds === nothing ? Int64(0) : Int64(seconds) * 1_000_000_000

"""
    connect(opts::ConnectOptions) -> Handle
    connect(host, user, password=nothing; kw...) -> Handle

Establishes an authenticated, utf8mb4-bootstrapped session: dial, greeting, STARTTLS per
`ssl_mode`, authentication, charset bootstrap, then `init_command`. `connect_timeout` bounds
everything up to the bootstrap as a single deadline; afterwards `read_timeout` and
`write_timeout` bound each transport read and write. Any failure closes the transport.
"""
function connect(opts::ConnectOptions)
    deadline = deadline_from(opts.connect_timeout)
    tcp = dial(opts, deadline)
    s = P.Session(tcp; limits=opts.limits, capabilities=opts.client_flags, debug=opts.debug)
    try
        deadline == 0 || apply_deadline!(tcp, deadline)
        P.read_greeting!(s)
        secure = P.starttls!(s, opts.tls, opts.host; handshake_timeout_ns=deadline == 0 ? 0 : remaining_ns(deadline))
        (secure && deadline != 0) && apply_deadline!(s.transport, deadline)
        policy = P.AuthPolicy(opts.auth.secure_transport || secure, secure && opts.tls.mode == P.SSL_VERIFY_IDENTITY, opts.auth.server_public_key, opts.auth.get_server_public_key, opts.auth.enable_cleartext_plugin, opts.auth.insecure_cleartext_auth)
        trace = Symbol[]
        ok = P.authenticate!(s, opts.user, opts.password, policy; db=opts.db, attrs=opts.attrs, default_auth=opts.default_auth, trace=trace)
        bootstrapped = bootstrap_charset!(s, ok)
        deadline == 0 || apply_deadline!(s.transport, Int64(0))
        # from here on `read_timeout`/`write_timeout` apply per transport operation
        P.set_timeouts!(s, timeout_ns(opts.read_timeout), timeout_ns(opts.write_timeout))
        opts.init_command === nothing || run_init_command!(s, opts)
        return register!(Handle(s, opts, ReapEntry(s.transport), bootstrapped, trace))
    catch
        P.is_terminal(s.phase) || P.close!(s)
        rethrow()
    end
end

connect(host::AbstractString, user::AbstractString, password::Union{Nothing, AbstractString}=nothing; kw...) = return connect(ConnectOptions(host, user, password; kw...))
