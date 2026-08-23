"""
    Session(transport; limits=Limits(), capabilities=DEFAULT_CLIENT_CAPABILITIES, debug=false, log_transitions=false)

Protocol state for one connection: the transport (replaced in place at STARTTLS), the
shared packet reader/writer, negotiated capabilities, server info, the current `Phase`, the
last status flags, and per-command accounting against `Limits`.

Every I/O failure (deadline, EOF, malformed packet, limit) moves the session to `BROKEN`
and closes the transport: after any such failure the stream position is unknowable.
"""
mutable struct Session
    transport::Transport
    io::PacketIO
    limits::Limits
    phase::Phase
    debug::Bool
    requested_capabilities::UInt64
    capabilities::UInt64
    server::Union{Nothing, ServerInfo}
    status::UInt16
    generation::Int
    authenticated::Bool
    command_kind::CommandKind
    result_sets::Int
    metadata_bytes::Int
    transition_log::Union{Nothing, Vector{Tuple{Phase, Symbol, Phase}}}
end

function Session(transport::Transport; limits::Limits=Limits(), capabilities::UInt64=DEFAULT_CLIENT_CAPABILITIES, debug::Bool=false, log_transitions::Bool=false)
    log = log_transitions ? Tuple{Phase, Symbol, Phase}[] : nothing
    return Session(transport, PacketIO(), limits, CONNECTING, debug, capabilities, capabilities, nothing, 0x0000, 1, false, CMD_QUERY, 0, 0, log)
end

has_capability(s::Session, flag::UInt64) = has_capability(s.capabilities, flag)
server_kind(s::Session) = s.server === nothing ? :unknown : s.server.kind
is_mariadb(s::Session) = server_kind(s) == :mariadb
deprecate_eof(s::Session) = has_capability(s, CLIENT_DEPRECATE_EOF)
Base.isopen(s::Session) = !is_terminal(s.phase) && transport_isopen(s.transport)

function transition!(s::Session, event::Symbol, to::Phase)
    t = (s.phase, event, to)
    t in TRANSITIONS || illegal_transition(s.phase, event, to)
    record_coverage(t)
    s.transition_log === nothing || push!(s.transition_log, t)
    s.debug && @debug "MySQL.Protocol transition" from=s.phase event=event to=to
    s.phase = to
    return nothing
end

# The per-row `(ROWS, :row, ROWS)` self-transition is statically legal (the caller already
# required phase ROWS), so the hot path skips the `TRANSITIONS` set lookup — it cost ~15%
# of a 1M-row scan (§8.9) — while preserving coverage recording and the transition log.
@inline function row_transition!(s::Session)
    t = (ROWS, :row, ROWS)
    COVERAGE_ENABLED[] && record_coverage(t)
    s.transition_log === nothing || push!(s.transition_log, t)
    s.debug && @debug "MySQL.Protocol transition" from=ROWS event=:row to=ROWS
    return nothing
end

@noinline wrong_phase(s::Session, expected) = error("internal error: operation requires phase $expected, session is $(s.phase)")

@inline function require_phase(s::Session, expected::Phase)
    s.phase == expected || wrong_phase(s, expected)
    return nothing
end

max_payload(s::Session) = s.authenticated ? s.limits.max_packet : s.limits.max_preauth_packet

"""
    set_timeouts!(s, read_timeout_ns, write_timeout_ns)

Per-operation timeouts (0 = none) re-armed before every transport read and write; distinct
from the absolute deadlines a caller may set on the transport for connection establishment.
"""
function set_timeouts!(s::Session, read_timeout_ns::Integer, write_timeout_ns::Integer)
    s.io.read_timeout_ns = Int64(read_timeout_ns)
    s.io.write_timeout_ns = Int64(write_timeout_ns)
    return nothing
end

"""
    fault!(s, err) -> Exception

Marks the session `BROKEN`, closes the transport, and returns the exception the caller
should throw: deadlines become `TimeoutError`, a peer EOF becomes `ProtocolError`, and
everything else (including `InterruptException` and `ProtocolError`) is returned as is.
"""
function fault!(s::Session, err)
    phase = s.phase
    is_terminal(s.phase) || transition!(s, :fault, BROKEN)
    transport_close(s.transport)
    is_deadline_error(err) && return TimeoutError("deadline expired while waiting for the server (phase $phase); the connection has been closed")
    (err isa EOFError || (err isa Reseau.TLS.TLSError && err.cause isa EOFError)) && return ProtocolError("connection closed by the server in the middle of the protocol stream")
    # A TLS 1.3 server may reject the session (e.g. a missing client certificate) on the
    # first record after the handshake; before authentication that is still a negotiation
    # failure from the caller's point of view.
    err isa Reseau.TLS.TLSError && !s.authenticated && return TLSNegotiationError("TLS failure while establishing the connection ($(err.op)): $(err.message)", err)
    err isa Reseau.TLS.TLSError && return ProtocolError("TLS transport failure ($(err.op)): $(err.message)")
    return err
end

# Runs a classification/parse step; any exception (malformed packet, limit) faults the session.
function guarded(f::F, s::Session) where {F}
    try
        return f()
    catch err
        throw(fault!(s, err))
    end
end

"""
    readpacket!(s; packet_limit=max_payload(s), dest=s.io.inbuf) -> PacketView

Reads one logical packet under the phase-dependent size bound; any failure faults the
session. `packet_limit` can impose a smaller state-specific bound; `dest` is the buffer the
payload is read into (a cursor passes its own). The view is valid until the next read into
the same buffer.
"""
function readpacket!(s::Session; packet_limit::Int=max_payload(s), dest::Vector{UInt8}=s.io.inbuf)
    try
        # buffered reads only after authentication: the connection phase stays byte-exact
        # so STARTTLS never has bytes stranded in the reader
        p = readpacket!(s.io, s.transport, min(packet_limit, max_payload(s)); max_response=s.authenticated ? s.limits.max_response_bytes : nothing, dest=dest, buffered=s.authenticated)
        s.debug && @debug "MySQL.Protocol read" phase=s.phase length=payload_length(p) header=first_byte(p) seq=p.seq chunks=p.nchunks
        return p
    catch err
        throw(fault!(s, err))
    end
end

"""
    sendpacket!(s, payload)

Frames and writes one logical packet; any failure faults the session (a partial write
leaves the amount actually sent unknown).
"""
function sendpacket!(s::Session, payload::AbstractVector{UInt8})
    try
        check_limit("packet length", length(payload), max_payload(s))
        s.debug && @debug "MySQL.Protocol write" phase=s.phase length=length(payload) seq=s.io.seq
        sendpacket!(s.io, s.transport, payload)
    catch err
        throw(fault!(s, err))
    end
    return nothing
end

"""
    close!(s)

Closes the transport without protocol I/O (use `quit!` for a best-effort COM_QUIT first).
"""
function close!(s::Session)
    is_terminal(s.phase) || transition!(s, :close, CLOSED)
    transport_close(s.transport)
    return nothing
end

# ---- connection phase (framing level; authentication plugins arrive in M2) ----

"""
    read_greeting!(s) -> ServerInfo

Reads the server greeting. A pre-capability ERR (host blocked, too many connections) is
thrown as `Error` with an empty SQLSTATE and the session is closed.
"""
function read_greeting!(s::Session)
    require_phase(s, CONNECTING)
    p = readpacket!(s)
    kind = guarded(() -> classify_greeting(p), s)
    if kind == :initial_err
        e = guarded(() -> parse_initial_err(p), s)
        transition!(s, :initial_err, CLOSED)
        transport_close(s.transport)
        throw(Error(e))
    end
    info = guarded(() -> parse_handshake_v10(p), s)
    s.server = info
    s.status = info.status
    s.capabilities = guarded(() -> negotiate(info, s.requested_capabilities), s)
    transition!(s, :greeting, HANDSHAKE)
    return info
end

"""
    replace_transport!(s, tls)

Replaces the transport after a STARTTLS handshake. The packet reader must hold no unread
bytes (the TLS wrapper took over the raw TCP connection; bytes already consumed from it can
never reach the TLS decoder), so only the sequence counter and accounting survive.
"""
function replace_transport!(s::Session, transport::Transport)
    require_phase(s, TLS_UPGRADE)
    # reads are unbuffered until authentication completes, so nothing can be stranded here
    buffered_bytes_available(s.io) == 0 || protocol_error("internal error: buffered reader bytes at STARTTLS")
    s.transport = transport
    transition!(s, :tls_established, HANDSHAKE)
    return nothing
end

"""
    send_ssl_request!(s, charset)

Writes the SSLRequest packet (HANDSHAKE → TLS_UPGRADE); the caller then wraps the TCP
connection with Reseau TLS and calls `replace_transport!`.
"""
function send_ssl_request!(s::Session, charset::UInt8=CHARSET_UTF8MB4_GENERAL_CI)
    require_phase(s, HANDSHAKE)
    has_capability(s.server.capabilities, CLIENT_SSL) || throw(AuthError("server does not advertise CLIENT_SSL"))
    caps = s.capabilities | CLIENT_SSL
    sendpacket!(s, build_ssl_request(caps, s.limits.max_packet, charset; mariadb=is_mariadb(s)))
    s.capabilities = caps
    transition!(s, :ssl_request, TLS_UPGRADE)
    return nothing
end

"""
    send_handshake_response!(s, user, auth_response, plugin; db="", attrs=[], charset=CHARSET_UTF8MB4_GENERAL_CI)

Writes HandshakeResponse41 (HANDSHAKE → AUTH). The auth response bytes come from the
selected plugin (M2); M1 only frames the packet.
"""
function send_handshake_response!(s::Session, user::AbstractString, auth_response::AbstractVector{UInt8}, plugin::AbstractString; db::AbstractString="", attrs::Vector{Pair{String, String}}=Pair{String, String}[], charset::UInt8=CHARSET_UTF8MB4_GENERAL_CI)
    require_phase(s, HANDSHAKE)
    caps = s.capabilities
    isempty(db) || has_capability(caps, CLIENT_CONNECT_WITH_DB) || throw(ProtocolError("a database was requested but CLIENT_CONNECT_WITH_DB was not negotiated"))
    payload = build_handshake_response(caps, s.limits.max_packet, charset, user, auth_response, plugin; db=db, attrs=attrs, mariadb=is_mariadb(s))
    try
        sendpacket!(s, payload)
    finally
        securezero!(payload)
    end
    transition!(s, :handshake_response, AUTH)
    return nothing
end

"""
    read_auth_packet!(s) -> (kind, value)

Reads and classifies one authentication-phase packet:
`(:ok, OKPacket)` (session becomes READY), `(:auth_switch, AuthSwitchRequest)`,
`(:auth_more, AuthMoreData)` (MySQL envelope), `(:plugin_data, Vector{UInt8})` (MariaDB;
the optional leading `0x01` already stripped). Server ERR is thrown as `AuthError`-free
`Error` after closing; old-style switch and multi-factor requests raise
`UnsupportedAuthError`. Each call counts one authentication round against `Limits`.
"""
function read_auth_packet!(s::Session, round_number::Int, auth_bytes::Int)
    require_phase(s, AUTH)
    1 <= round_number <= s.limits.max_auth_rounds || throw(fault!(s, ProtocolError("authentication exceeded $(s.limits.max_auth_rounds) rounds")))
    0 <= auth_bytes <= s.limits.max_auth_bytes || throw(fault!(s, ProtocolError("authentication exchange exceeded $(s.limits.max_auth_bytes) bytes")))
    p = readpacket!(s; packet_limit=s.limits.max_auth_bytes - auth_bytes)
    auth_bytes + payload_length(p) <= s.limits.max_auth_bytes || throw(fault!(s, ProtocolError("authentication exchange exceeded $(s.limits.max_auth_bytes) bytes")))
    kind = guarded(() -> classify_auth(p, is_mariadb(s)), s)
    if kind == :ok
        ok = guarded(() -> parse_ok(p, s.capabilities, s.limits), s)
        s.status = ok.status
        s.authenticated = true
        transition!(s, :auth_ok, READY)
        return (:ok, ok)
    elseif kind == :err
        e = guarded(() -> parse_err(p, s.capabilities), s)
        transition!(s, :auth_err, CLOSED)
        transport_close(s.transport)
        throw(Error(e))
    elseif kind == :auth_switch
        req = guarded(() -> parse_auth_switch(p), s)
        transition!(s, :auth_continue, AUTH)
        return (:auth_switch, req)
    elseif kind == :auth_more
        more = guarded(() -> parse_auth_more_data(p), s)
        transition!(s, :auth_continue, AUTH)
        return (:auth_more, more)
    elseif kind == :plugin_data
        transition!(s, :auth_continue, AUTH)
        bytes = payload(p)
        (!isempty(bytes) && bytes[1] == AUTH_MORE_DATA_HEADER) && popfirst!(bytes)
        return (:plugin_data, bytes)
    elseif kind == :old_auth_switch
        close!(s)
        throw(UnsupportedAuthError(PLUGIN_OLD_PASSWORD))
    end
    close!(s)
    throw(UnsupportedAuthError("multi-factor authentication", "the server requested multi-factor authentication (AuthNextFactor), which is not supported"))
end

"""
    send_auth_data!(s, bytes)

Writes a raw authentication reply (AuthSwitchResponse / plugin continuation data).
"""
function send_auth_data!(s::Session, bytes::AbstractVector{UInt8})
    require_phase(s, AUTH)
    sendpacket!(s, bytes)
    return nothing
end
