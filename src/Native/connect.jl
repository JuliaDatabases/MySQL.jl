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

Base.isopen(h::Handle) = isopen(h.session)

function finalize_handle(h::Handle)
    enqueue_from_finalizer!(h.entry, () -> finalizer(finalize_handle, h))
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

deadline_from(connect_timeout::Union{Nothing, Int}) = connect_timeout === nothing ? Int64(0) : Int64(time_ns()) + Int64(connect_timeout) * 1_000_000_000

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

function dial(opts::ConnectOptions, deadline::Int64)
    address = hostport(opts.host, opts.port)
    try
        deadline == 0 && return Reseau.TCP.connect(address)
        return Reseau.TCP.connect(address; timeout_ns=remaining_ns(deadline))
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
    charset_already_utf8mb4(ok) && return false
    P.query!(s, "SET NAMES utf8mb4")
    P.read_command_response!(s; kind=P.CMD_SIMPLE) isa P.OKPacket || P.protocol_error("SET NAMES utf8mb4 did not return OK")
    return true
end

function run_init_command!(s::P.Session, sql::String, read_timeout::Union{Nothing, Int})
    read_timeout === nothing || P.set_read_deadline!(s.transport, Int64(time_ns()) + Int64(read_timeout) * 1_000_000_000)
    try
        P.query!(s, sql)
        P.read_command_response!(s)
        P.drain!(s)
    finally
        read_timeout === nothing || P.set_read_deadline!(s.transport, 0)
    end
    return nothing
end

"""
    connect(opts::ConnectOptions) -> Handle
    connect(host, user, password=nothing; kw...) -> Handle

Establishes an authenticated, utf8mb4-bootstrapped session: dial, greeting, STARTTLS per
`ssl_mode`, authentication, charset bootstrap, then `init_command`. `connect_timeout` bounds
everything up to the bootstrap as a single deadline. Any failure closes the transport.
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
        opts.init_command === nothing || run_init_command!(s, opts.init_command, opts.read_timeout)
        return register!(Handle(s, opts, ReapEntry(s.transport), bootstrapped, trace))
    catch
        P.is_terminal(s.phase) || P.close!(s)
        rethrow()
    end
end

connect(host::AbstractString, user::AbstractString, password::Union{Nothing, AbstractString}=nothing; kw...) = connect(ConnectOptions(host, user, password; kw...))
