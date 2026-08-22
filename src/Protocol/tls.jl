# STARTTLS orchestration on top of Reseau TLS.

"""
    SSLMode

`SSL_DISABLED` never sends SSLRequest; `SSL_PREFERRED` (the default) uses TLS when the
server advertises `CLIENT_SSL` and continues in plaintext only when it does not (a failed
TLS handshake never falls back); `SSL_REQUIRED` fails without TLS; `SSL_VERIFY_CA` also
verifies the certificate chain; `SSL_VERIFY_IDENTITY` also verifies the host name / IP SAN.
Only the last two authenticate the server; `SSL_PREFERRED`/`SSL_REQUIRED` give
confidentiality against passive observers and no protection against an active MITM.
"""
@enum SSLMode SSL_DISABLED SSL_PREFERRED SSL_REQUIRED SSL_VERIFY_CA SSL_VERIFY_IDENTITY

const SSL_MODE_NAMES = Dict{Symbol, SSLMode}(:disabled => SSL_DISABLED, :preferred => SSL_PREFERRED, :required => SSL_REQUIRED, :verify_ca => SSL_VERIFY_CA, :verify_identity => SSL_VERIFY_IDENTITY)

function ssl_mode(x)
    x isa SSLMode && return x
    sym = x isa Symbol ? x : Symbol(replace(lowercase(string(x)), "-" => "_", "ssl_mode_" => ""))
    return get(SSL_MODE_NAMES, sym) do
        throw(ArgumentError("unknown ssl_mode $(repr(x)); expected one of :disabled, :preferred, :required, :verify_ca, :verify_identity"))
    end
end

"""
    TLSOptions(; mode=SSL_PREFERRED, ca_file=nothing, cert_file=nothing, key_file=nothing,
                 server_name=nothing, min_version=nothing, max_version=nothing)

`ca_file` may be a bundle or a hashed CA directory (Reseau accepts both); `cert_file`/`key_file`
enable mutual TLS; `server_name` overrides the SNI/verification name derived from the host.
"""
struct TLSOptions
    mode::SSLMode
    ca_file::Union{Nothing, String}
    cert_file::Union{Nothing, String}
    key_file::Union{Nothing, String}
    server_name::Union{Nothing, String}
    min_version::Union{Nothing, UInt16}
    max_version::Union{Nothing, UInt16}
end

function TLSOptions(; mode=SSL_PREFERRED, ca_file=nothing, cert_file=nothing, key_file=nothing, server_name=nothing, min_version=nothing, max_version=nothing)
    xor(cert_file === nothing, key_file === nothing) && throw(ArgumentError("ssl_cert and ssl_key must be provided together"))
    m = ssl_mode(mode)
    return TLSOptions(m, ca_file === nothing ? nothing : String(ca_file), cert_file === nothing ? nothing : String(cert_file), key_file === nothing ? nothing : String(key_file), server_name === nothing ? nothing : String(server_name), min_version, max_version)
end

is_ip_literal(host::AbstractString) = occursin(r"^\d{1,3}(\.\d{1,3}){3}$", host) || occursin(':', host)

# SNI is sent for DNS names in every TLS mode; an IP literal is passed only when it is needed
# for verification (RFC 6066 forbids IP literals in SNI, and Reseau needs the name to check
# the IP SAN).
function tls_server_name(opts::TLSOptions, host::AbstractString)
    opts.server_name === nothing || return opts.server_name
    name = (startswith(host, '[') && endswith(host, ']')) ? String(host[2:(end - 1)]) : String(host)
    is_ip_literal(name) || return name
    (opts.mode == SSL_VERIFY_CA || opts.mode == SSL_VERIFY_IDENTITY) && return name
    return nothing
end

function tls_config(opts::TLSOptions, host::AbstractString, handshake_timeout_ns::Integer)
    verify_peer = opts.mode == SSL_VERIFY_CA || opts.mode == SSL_VERIFY_IDENTITY
    verify_hostname = opts.mode == SSL_VERIFY_IDENTITY
    return Reseau.TLS.Config(; server_name=tls_server_name(opts, host), verify_peer=verify_peer, verify_hostname=verify_hostname, cert_file=opts.cert_file, key_file=opts.key_file, ca_file=opts.ca_file, handshake_timeout_ns=max(Int64(0), Int64(handshake_timeout_ns)), min_version=opts.min_version === nothing ? Reseau.TLS.TLS1_2_VERSION : opts.min_version, max_version=opts.max_version)
end

raw_tcp(t::Reseau.TCP.Conn) = t
raw_tcp(t::FaultTransport) = t.inner isa Reseau.TCP.Conn ? t.inner : throw(ArgumentError("STARTTLS needs a TCP transport"))
raw_tcp(::Reseau.TLS.Conn) = throw(ArgumentError("the session is already on TLS"))

is_secure_transport(t::Reseau.TLS.Conn) = true
is_secure_transport(t::Reseau.TCP.Conn) = false
is_secure_transport(t::FaultTransport) = t.inner isa Reseau.TLS.Conn
is_secure_transport(s::Session) = is_secure_transport(s.transport)

"""
    starttls!(s, opts, host; handshake_timeout_ns=0) -> Bool

Applies the `ssl_mode` policy after the greeting (phase `HANDSHAKE`): returns `false` when
the connection legitimately stays in plaintext (`SSL_DISABLED`, or `SSL_PREFERRED` against a
server without `CLIENT_SSL`), `true` after a completed TLS handshake. A server that lacks
TLS under `SSL_REQUIRED` or stricter raises `TLSNegotiationError`; a failed handshake faults
the session (`TLSNegotiationError`, or `TimeoutError` on a deadline) — there is never a
plaintext fallback once SSLRequest has been sent.
"""
function starttls!(s::Session, opts::TLSOptions, host::AbstractString; handshake_timeout_ns::Integer=0)
    require_phase(s, HANDSHAKE)
    opts.mode == SSL_DISABLED && return false
    if !has_capability(s.server.capabilities, CLIENT_SSL)
        opts.mode == SSL_PREFERRED && return false
        throw(TLSNegotiationError("the server does not support TLS but ssl_mode=$(opts.mode) requires it", nothing))
    end
    tcp = raw_tcp(s.transport)
    config = tls_config(opts, host, handshake_timeout_ns)
    send_ssl_request!(s)
    tls = Reseau.TLS.client(tcp, config)
    try
        Reseau.TLS.handshake!(tls)
    catch err
        transport_close(tls)
        throw(fault!(s, tls_failure(err)))
    end
    replace_transport!(s, tls)
    return true
end

function tls_failure(err)
    err isa Reseau.TLS.TLSHandshakeTimeoutError && return Reseau.IOPoll.DeadlineExceededError()
    is_deadline_error(err) && return err
    (err isa Reseau.TLS.TLSError && is_deadline_error(err.cause)) && return err.cause
    err isa Reseau.TLS.TLSError && return TLSNegotiationError("TLS handshake failed: $(err.message)", err)
    err isa Reseau.TLS.ConfigError && return TLSNegotiationError("invalid TLS configuration: $(sprint(showerror, err))", err)
    err isa EOFError && return TLSNegotiationError("the server closed the connection during the TLS handshake", err)
    return err
end
