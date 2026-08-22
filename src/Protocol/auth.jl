# Authentication plugins and the authentication exchange.
#
# Per-plugin transport-security rules (TCP only; Unix sockets/named pipes are deferred):
#
# | plugin step                          | TLS (any mode)                         | plain TCP            |
# |--------------------------------------|----------------------------------------|----------------------|
# | caching_sha2 full auth (cleartext)   | allowed                                | RSA path (opt-in)    |
# | sha256 full auth (cleartext)         | allowed                                | RSA path (opt-in)    |
# | mysql_clear_password                 | :verify_identity only, else opt-in     | opt-in only          |
#
# The RSA path needs `server_public_key` (PEM) or `get_server_public_key=true`; the cleartext
# plugin needs explicit enablement (`enable_cleartext_plugin` or `default_auth`).

"""
    AuthPolicy(; secure_transport=false, identity_verified=false, server_public_key=nothing,
                 get_server_public_key=false, enable_cleartext_plugin=false,
                 insecure_cleartext_auth=false)

Connection-level facts and user policy the plugins consult. `secure_transport` is true on
TLS (any mode); `identity_verified` only under `ssl_mode = :verify_identity`.
"""
struct AuthPolicy
    secure_transport::Bool
    identity_verified::Bool
    server_public_key::Union{Nothing, Vector{UInt8}}
    get_server_public_key::Bool
    enable_cleartext_plugin::Bool
    insecure_cleartext_auth::Bool
end

function AuthPolicy(; secure_transport::Bool=false, identity_verified::Bool=false, server_public_key::Union{Nothing, AbstractVector{UInt8}, AbstractString}=nothing, get_server_public_key::Bool=false, enable_cleartext_plugin::Bool=false, insecure_cleartext_auth::Bool=false)
    pem = server_public_key === nothing ? nothing : server_public_key isa AbstractString ? Vector{UInt8}(codeunits(server_public_key)) : Vector{UInt8}(server_public_key)
    return AuthPolicy(secure_transport, identity_verified, pem, get_server_public_key, enable_cleartext_plugin, insecure_cleartext_auth)
end

abstract type AuthPlugin end
struct NativePassword <: AuthPlugin end
struct CachingSha2Password <: AuthPlugin end
struct Sha256Password <: AuthPlugin end
struct ClearPassword <: AuthPlugin end

plugin_name(::NativePassword) = PLUGIN_NATIVE_PASSWORD
plugin_name(::CachingSha2Password) = PLUGIN_CACHING_SHA2_PASSWORD
plugin_name(::Sha256Password) = PLUGIN_SHA256_PASSWORD
plugin_name(::ClearPassword) = PLUGIN_CLEAR_PASSWORD

const SUPPORTED_PLUGINS = Dict{String, AuthPlugin}(
    PLUGIN_NATIVE_PASSWORD => NativePassword(),
    PLUGIN_CACHING_SHA2_PASSWORD => CachingSha2Password(),
    PLUGIN_SHA256_PASSWORD => Sha256Password(),
    PLUGIN_CLEAR_PASSWORD => ClearPassword(),
)

is_supported_plugin(name::AbstractString) = haskey(SUPPORTED_PLUGINS, name)

function plugin_for(name::AbstractString)
    return get(SUPPORTED_PLUGINS, name) do
        throw(UnsupportedAuthError(String(name)))
    end
end

# ---- scrambles (pure functions) ----

function xor_bytes!(a::Vector{UInt8}, b::AbstractVector{UInt8})
    @inbounds for i in eachindex(a)
        a[i] ⊻= b[i]
    end
    return a
end

"""
    native_scramble(password, nonce) -> 20 bytes

`SHA1(password) XOR SHA1(nonce ‖ SHA1(SHA1(password)))`; empty for an empty password.
"""
function native_scramble(password::AbstractVector{UInt8}, nonce::AbstractVector{UInt8})
    isempty(password) && return UInt8[]
    length(nonce) == SCRAMBLE_LENGTH || throw(AuthError("mysql_native_password needs a $SCRAMBLE_LENGTH-byte nonce, got $(length(nonce))"))
    stage1 = SHA.sha1(password)
    stage2 = SHA.sha1(stage1)
    mixed = SHA.sha1(vcat(Vector{UInt8}(nonce), stage2))
    try
        return xor_bytes!(stage1, mixed)
    finally
        securezero!(stage2)
        securezero!(mixed)
    end
end

"""
    caching_sha2_scramble(password, nonce) -> 32 bytes

`SHA256(password) XOR SHA256(SHA256(SHA256(password)) ‖ nonce)`; empty for an empty password.
"""
function caching_sha2_scramble(password::AbstractVector{UInt8}, nonce::AbstractVector{UInt8})
    isempty(password) && return UInt8[]
    length(nonce) == SCRAMBLE_LENGTH || throw(AuthError("caching_sha2_password needs a $SCRAMBLE_LENGTH-byte nonce, got $(length(nonce))"))
    stage1 = SHA.sha256(password)
    stage2 = SHA.sha256(stage1)
    mixed = SHA.sha256(vcat(stage2, Vector{UInt8}(nonce)))
    try
        return xor_bytes!(stage1, mixed)
    finally
        securezero!(stage2)
        securezero!(mixed)
    end
end

# password ‖ NUL, XORed with the nonce cycled over the length.
function nonce_masked_password(password::AbstractVector{UInt8}, nonce::AbstractVector{UInt8})
    isempty(nonce) && throw(AuthError("RSA password exchange needs a non-empty nonce"))
    plain = vcat(Vector{UInt8}(password), UInt8[0x00])
    n = length(nonce)
    @inbounds for i in eachindex(plain)
        plain[i] ⊻= nonce[mod1(i, n)]
    end
    return plain
end

"""
    rsa_encrypt_password(password, nonce, pem) -> ciphertext

RSAES-OAEP(SHA-1) of `(password ‖ NUL) XOR nonce` with the server's public key; the masked
plaintext is zeroed afterwards.
"""
function rsa_encrypt_password(password::AbstractVector{UInt8}, nonce::AbstractVector{UInt8}, pem::AbstractVector{UInt8})
    plain = nonce_masked_password(password, nonce)
    try
        return rsa_oaep_sha1_encrypt(pem, plain)
    finally
        securezero!(plain)
    end
end

cleartext_password(password::AbstractVector{UInt8}) = vcat(Vector{UInt8}(password), UInt8[0x00])

# ---- policy ----

@noinline rsa_unavailable(plugin::String) = throw(AuthError("$plugin requires a secure connection for full authentication; over plain TCP pass `server_public_key=<PEM path>` or `get_server_public_key=true` to use RSA password exchange, or connect with `ssl_mode=:required`"))

function require_cleartext_allowed(policy::AuthPolicy)
    policy.enable_cleartext_plugin || throw(AuthError("the server requested mysql_clear_password, which is disabled; pass `enable_cleartext_plugin=true` (or `default_auth=\"mysql_clear_password\"`)"))
    (policy.identity_verified || policy.insecure_cleartext_auth) && return nothing
    throw(AuthError("mysql_clear_password would send the password in clear text over a connection whose peer identity is not verified; use `ssl_mode=:verify_identity` or opt in with `insecure_cleartext_auth=true`"))
end

# ---- plugin state machine ----

mutable struct AuthState
    plugin::AuthPlugin
    nonce::Vector{UInt8}
    awaiting_public_key::Bool
    full_auth::Bool
end

AuthState(plugin::AuthPlugin, nonce::AbstractVector{UInt8}) = AuthState(plugin, Vector{UInt8}(nonce), false, false)

# Servers append a NUL to the 20-byte scramble in AuthSwitchRequest data.
function strip_nonce(data::AbstractVector{UInt8})
    nonce = Vector{UInt8}(data)
    (!isempty(nonce) && nonce[end] == 0x00) && pop!(nonce)
    return nonce
end

"""
    initial_response(plugin, password, nonce, policy) -> Vector{UInt8}

The auth-response bytes for HandshakeResponse41 or an AuthSwitchResponse.
"""
initial_response(::NativePassword, password::AbstractVector{UInt8}, nonce::AbstractVector{UInt8}, ::AuthPolicy) = native_scramble(password, nonce)
initial_response(::CachingSha2Password, password::AbstractVector{UInt8}, nonce::AbstractVector{UInt8}, ::AuthPolicy) = caching_sha2_scramble(password, nonce)

function initial_response(::Sha256Password, password::AbstractVector{UInt8}, nonce::AbstractVector{UInt8}, policy::AuthPolicy)
    isempty(password) && return UInt8[]
    policy.secure_transport && return cleartext_password(password)
    policy.server_public_key === nothing || return rsa_encrypt_password(password, nonce, policy.server_public_key)
    policy.get_server_public_key && return UInt8[SHA256_REQUEST_PUBLIC_KEY]
    return rsa_unavailable(PLUGIN_SHA256_PASSWORD)
end

function initial_response(::ClearPassword, password::AbstractVector{UInt8}, ::AbstractVector{UInt8}, policy::AuthPolicy)
    require_cleartext_allowed(policy)
    return cleartext_password(password)
end

is_pem(data::AbstractVector{UInt8}) = length(data) > 10 && String(data[1:10]) == "-----BEGIN"

"""
    step!(state, data, password, policy) -> Union{Nothing, Vector{UInt8}}

Consumes plugin continuation data (the payload of AuthMoreData, or MariaDB's unwrapped
payload) and returns the reply to send, or `nothing` when an OK/ERR must follow.
"""
function step!(state::AuthState, data::AbstractVector{UInt8}, password::AbstractVector{UInt8}, policy::AuthPolicy)
    return step!(state.plugin, state, data, password, policy)
end

step!(::NativePassword, ::AuthState, ::AbstractVector{UInt8}, ::AbstractVector{UInt8}, ::AuthPolicy) = protocol_error("mysql_native_password received unexpected continuation data")
step!(::ClearPassword, ::AuthState, ::AbstractVector{UInt8}, ::AbstractVector{UInt8}, ::AuthPolicy) = protocol_error("mysql_clear_password received unexpected continuation data")

function step!(::CachingSha2Password, state::AuthState, data::AbstractVector{UInt8}, password::AbstractVector{UInt8}, policy::AuthPolicy)
    if state.awaiting_public_key
        is_pem(data) || protocol_error("expected the server RSA public key, got $(length(data)) bytes")
        state.awaiting_public_key = false
        return rsa_encrypt_password(password, state.nonce, data)
    end
    length(data) == 1 || protocol_error("caching_sha2_password status packet must contain exactly one byte, got $(length(data))")
    data[1] == CACHING_SHA2_FAST_AUTH_SUCCESS && return nothing
    data[1] == CACHING_SHA2_PERFORM_FULL_AUTH || protocol_error("unexpected caching_sha2_password status byte 0x$(string(data[1], base=16, pad=2))")
    state.full_auth = true
    policy.secure_transport && return cleartext_password(password)
    policy.server_public_key === nothing || return rsa_encrypt_password(password, state.nonce, policy.server_public_key)
    if policy.get_server_public_key
        state.awaiting_public_key = true
        return UInt8[CACHING_SHA2_REQUEST_PUBLIC_KEY]
    end
    return rsa_unavailable(PLUGIN_CACHING_SHA2_PASSWORD)
end

function step!(::Sha256Password, state::AuthState, data::AbstractVector{UInt8}, password::AbstractVector{UInt8}, policy::AuthPolicy)
    is_pem(data) || protocol_error("expected the server RSA public key, got $(length(data)) bytes")
    return rsa_encrypt_password(password, state.nonce, data)
end

# ---- the exchange ----

# Names one continuation round for the optional trace: which caching_sha2 branch ran and
# whether a public key travelled.
function trace_event(state::AuthState, data::AbstractVector{UInt8}, policy::AuthPolicy)
    is_pem(data) && return :rsa_response
    state.plugin isa CachingSha2Password || return :continue
    isempty(data) && return :continue
    data[1] == CACHING_SHA2_FAST_AUTH_SUCCESS && return :fast_auth
    data[1] == CACHING_SHA2_PERFORM_FULL_AUTH || return :continue
    policy.secure_transport && return :full_auth_cleartext
    state.awaiting_public_key && return :rsa_request
    return :full_auth_rsa
end

# The packet writer keeps the last frame; during authentication that frame can hold the
# password, so it is wiped after every send.
function wipe_outbuf!(s::Session)
    securezero!(s.io.outbuf)
    return nothing
end

function select_plugin(server::ServerInfo, default_auth::Union{Nothing, AbstractString})
    default_auth === nothing || return plugin_for(default_auth)
    return plugin_for(server.auth_plugin)
end

function send_wiped!(s::Session, reply::Vector{UInt8})
    try
        send_auth_data!(s, reply)
    finally
        securezero!(reply)
        wipe_outbuf!(s)
    end
    return nothing
end

"""
    authenticate!(s, user, password, policy; db="", attrs=[], default_auth=nothing) -> OKPacket

Runs the connection-phase authentication exchange from `HANDSHAKE` to `READY`: sends
HandshakeResponse41 with the initial response of the selected plugin, then answers
AuthSwitchRequest / AuthMoreData / MariaDB plugin data until the server sends OK.
Policy violations raise `AuthError`, unknown plugins `UnsupportedAuthError`, server refusals
`Error`; in all cases the session is closed.
"""
function authenticate!(s::Session, user::AbstractString, password::Union{Nothing, AbstractString, AbstractVector{UInt8}}, policy::AuthPolicy; db::AbstractString="", attrs::Vector{Pair{String, String}}=Pair{String, String}[], default_auth::Union{Nothing, AbstractString}=nothing, trace::Union{Nothing, Vector{Symbol}}=nothing)
    require_phase(s, HANDSHAKE)
    note(event::Symbol) = (trace === nothing || push!(trace, event); nothing)
    pw = password === nothing ? UInt8[] : password isa AbstractString ? Vector{UInt8}(codeunits(password)) : Vector{UInt8}(password)
    try
        plugin = select_plugin(s.server, default_auth)
        state = AuthState(plugin, s.server.auth_plugin_data)
        note(Symbol("initial_", plugin_name(plugin)))
        response = initial_response(plugin, pw, state.nonce, policy)
        try
            send_handshake_response!(s, user, response, plugin_name(plugin); db=db, attrs=attrs)
        finally
            securezero!(response)
            wipe_outbuf!(s)
        end
        round_number = 1
        auth_bytes = 0
        while true
            response_bytes = s.io.response_bytes
            kind, value = read_auth_packet!(s, round_number, auth_bytes)
            auth_bytes += s.io.response_bytes - response_bytes
            round_number += 1
            if kind == :ok
                note(:ok)
                return value
            elseif kind == :auth_switch
                state = AuthState(plugin_for(value.plugin), strip_nonce(value.data))
                note(Symbol("switch_", value.plugin))
                send_wiped!(s, initial_response(state.plugin, pw, state.nonce, policy))
            else
                data = kind == :auth_more ? value.data : value
                reply = step!(state, data, pw, policy)
                note(trace_event(state, data, policy))
                reply === nothing || send_wiped!(s, reply)
            end
        end
    catch err
        if err isa ProtocolError && !is_terminal(s.phase)
            throw(fault!(s, err))
        end
        is_terminal(s.phase) || close!(s)
        rethrow()
    finally
        securezero!(pw)
    end
end
