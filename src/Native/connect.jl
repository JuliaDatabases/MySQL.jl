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

function finalize_handle(h::Handle)
    enqueue_from_finalizer!(h.entry) || finalizer(finalize_handle, h)
    return nothing
end

function register!(h::Handle)
    ensure_reaper!()
    finalizer(finalize_handle, h)
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

deadline_from(connect_timeout::Union{Nothing, Int}) = return connect_timeout === nothing ? Int64(0) : Int64(time_ns()) + Int64(connect_timeout) * 1_000_000_000

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

function resolve_bind(
        bind::Union{Nothing, String},
        deadline::Int64,
        resolver::F=Reseau.HostResolvers.resolve_tcp_addrs,
    ) where {F}
    bind === nothing && return nothing
    address = hostport(bind, 0)
    deadline == 0 && return resolver("tcp", address)
    timeout_message = "connect_timeout expired while resolving bind address $bind"
    result = Channel{Tuple{Bool, Any}}(1)
    task = errormonitor(Threads.@spawn begin
        try
            put!(result, (true, resolver("tcp", address)))
        catch err
            put!(result, (false, err))
        end
        return nothing
    end)
    left = deadline - Int64(time_ns())
    left > 0 || throw(P.TimeoutError(timeout_message))
    seconds = left / 1_000_000_000
    status = timedwait(() -> isready(result), seconds; pollint=clamp(seconds, 0.001, 0.01))
    if status === :timed_out && !isready(result)
        throw(P.TimeoutError(timeout_message))
    end
    ok, value = take!(result)
    wait(task)
    ok || throw(value)
    return value
end

function dial_one(address::String, deadline::Int64, local_addr)
    deadline == 0 && return Reseau.TCP.connect(address; local_addr=local_addr)
    return Reseau.TCP.connect(address; timeout_ns=remaining_ns(deadline), local_addr=local_addr)
end

function dial(opts::ConnectOptions, deadline::Int64)
    address = hostport(opts.host, opts.port)
    try
        local_addrs = resolve_bind(opts.bind, deadline)
        local_addrs === nothing && return dial_one(address, deadline, nothing)
        first_err = nothing
        for local_addr in local_addrs
            try
                return dial_one(address, deadline, local_addr)
            catch err
                (err isa P.TimeoutError || P.is_deadline_error(err)) && rethrow()
                first_err === nothing && (first_err = err)
            end
        end
        first_err === nothing && error("bind resolver returned no addresses for $(opts.bind)")
        throw(first_err::Exception)
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

function run_init_command!(s::P.Session, sql::String)
    P.query!(s, sql)
    P.read_command_response!(s)
    while !P.is_terminal(s.phase) && s.phase != P.READY
        P.drain_step!(s)
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
        opts.init_command === nothing || run_init_command!(s, opts.init_command)
        return register!(Handle(s, opts, ReapEntry(s.transport), bootstrapped, trace))
    catch
        P.is_terminal(s.phase) || P.close!(s)
        rethrow()
    end
end

connect(host::AbstractString, user::AbstractString, password::Union{Nothing, AbstractString}=nothing; kw...) = return connect(ConnectOptions(host, user, password; kw...))
