# Connection-phase packets: HandshakeV10 (server → client), SSLRequest and
# HandshakeResponse41 (client → server), capability negotiation.

"""
    ServerInfo

Everything learned from the server's HandshakeV10 greeting. `version` is normalized (a
MariaDB 10.x `5.5.5-` prefix is stripped); `raw_version` is the exact string; `kind` is
`:mysql`, `:mariadb`, `:tidb`, or `:vitess`. `capabilities` includes MariaDB's extended bits
(32..37) when the server is MariaDB. `auth_plugin_data` is the scramble with its trailing
NUL stripped.
"""
struct ServerInfo
    protocol_version::UInt8
    raw_version::String
    version::VersionNumber
    kind::Symbol
    connection_id::UInt32
    capabilities::UInt64
    charset::UInt8
    status::UInt16
    auth_plugin::String
    auth_plugin_data::Vector{UInt8}
end

is_mariadb(info::ServerInfo) = info.kind == :mariadb
has_capability(caps::UInt64, flag::UInt64) = (caps & flag) == flag

function detect_kind(raw_version::String, caps::UInt64)
    lower = lowercase(raw_version)
    occursin("mariadb", lower) && return :mariadb
    has_capability(caps, CLIENT_MYSQL) || return :mariadb
    occursin("tidb", lower) && return :tidb
    occursin("vitess", lower) && return :vitess
    return :mysql
end

"""
    normalize_version(raw, kind) -> VersionNumber

`VersionNumber("5.5.5-10.11.8-MariaDB")` parses as 5.5.5 with a prerelease tag, so a MariaDB
10.x greeting must have exactly one leading `5.5.5-` removed before the leading
`major.minor.patch` is parsed. Unparseable strings become `v"0.0.0"`.
"""
function normalize_version(raw::String, kind::Symbol)
    s = raw
    kind == :mariadb && startswith(s, "5.5.5-") && (s = s[7:end])
    m = match(r"^(\d+)\.(\d+)\.(\d+)", s)
    m === nothing && return v"0.0.0"
    return VersionNumber(parse(Int, m.captures[1]), parse(Int, m.captures[2]), parse(Int, m.captures[3]))
end

"""
    parse_handshake_v10(p::PacketView) -> ServerInfo

Optional tails are parsed from the capability flags *and* the remaining length, never from
a fixed modern layout. A `0xFF` first byte is not handled here (see `parse_initial_err`).
"""
function parse_handshake_v10(p::PacketView)
    c = PacketCursor(p)
    protocol_version = read_u8!(c)
    protocol_version == HANDSHAKE_PROTOCOL_VERSION || protocol_error("unsupported handshake protocol version $(Int(protocol_version)) (expected 10)")
    raw_version = read_nul_string!(c, "server version")
    connection_id = read_u32!(c)
    scramble = read_fixed_bytes!(c, AUTH_PLUGIN_DATA_PART_1_LENGTH, "auth-plugin-data-part-1")
    skip!(c, 1, "filler")
    caps = UInt64(read_u16!(c))
    charset = 0x00
    status = 0x0000
    plugin = ""
    if remaining(c) > 0
        charset = read_u8!(c)
        status = read_u16!(c)
        caps |= UInt64(read_u16!(c)) << 16
        auth_data_len = Int(read_u8!(c))
        has_capability(caps, CLIENT_PLUGIN_AUTH) || (auth_data_len = 0)
        skip!(c, 6, "reserved")
        if has_capability(caps, CLIENT_MYSQL)
            skip!(c, 4, "reserved")
        else
            caps |= UInt64(read_u32!(c)) << 32
        end
        if has_capability(caps, CLIENT_SECURE_CONNECTION)
            len2 = max(13, auth_data_len - AUTH_PLUGIN_DATA_PART_1_LENGTH)
            len2 = min(len2, remaining(c))
            append!(scramble, read_fixed_bytes!(c, len2, "auth-plugin-data-part-2"))
            !isempty(scramble) && scramble[end] == 0x00 && pop!(scramble)
        end
        if has_capability(caps, CLIENT_PLUGIN_AUTH)
            plugin = plugin_name_tail!(c)
        end
    end
    has_capability(caps, CLIENT_PROTOCOL_41) || protocol_error("server does not support the 4.1 protocol")
    kind = detect_kind(raw_version, caps)
    return ServerInfo(protocol_version, raw_version, normalize_version(raw_version, kind), kind, connection_id, caps, charset, status, plugin, scramble)
end

# Some old servers omit the terminating NUL of the plugin name; accept both forms.
function plugin_name_tail!(c::PacketCursor)
    atend(c) && return ""
    idx = findnext(==(0x00), c.buf, c.pos)
    (idx === nothing || idx > c.stop) && return read_eof_string!(c)
    return read_nul_string!(c, "auth plugin name")
end

"""
    parse_initial_err(p::PacketView) -> ERRPacket

An ERR sent before capabilities are negotiated (host blocked, too many connections, ...).
Oracle's connection-phase page says this packet carries no SQLSTATE while MariaDB's generic
ERR description applies the `#` heuristic; the server family is unknown at this point, so
the whole remainder is kept as the message and `sqlstate` is empty until live captures
settle the conflict.
"""
function parse_initial_err(p::PacketView)
    c = PacketCursor(p)
    read_u8!(c) == ERR_HEADER || protocol_error("expected ERR packet")
    code = read_u16!(c)
    return ERRPacket(code, "", read_eof_string!(c))
end

# ---- capabilities ----

const DEFAULT_CLIENT_CAPABILITIES = CLIENT_LONG_PASSWORD | CLIENT_LONG_FLAG | CLIENT_PROTOCOL_41 |
    CLIENT_TRANSACTIONS | CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH |
    CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA | CLIENT_CONNECT_ATTRS | CLIENT_SESSION_TRACK |
    CLIENT_DEPRECATE_EOF | CLIENT_MULTI_RESULTS | CLIENT_PS_MULTI_RESULTS

# Capabilities that change packet layouts in ways 2.0 does not implement; never requested.
const UNSUPPORTED_CLIENT_CAPABILITIES = CLIENT_OPTIONAL_RESULTSET_METADATA | CLIENT_QUERY_ATTRIBUTES |
    CLIENT_ZSTD_COMPRESSION_ALGORITHM | CLIENT_MULTI_FACTOR_AUTHENTICATION | CLIENT_COMPRESS |
    MARIADB_CLIENT_PROGRESS | MARIADB_CLIENT_COM_MULTI | MARIADB_CLIENT_STMT_BULK_OPERATIONS |
    MARIADB_CLIENT_EXTENDED_METADATA | MARIADB_CLIENT_CACHE_METADATA | MARIADB_CLIENT_BULK_UNIT_RESULTS

const REQUIRED_SERVER_CAPABILITIES = CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH

"""
    negotiate(server::ServerInfo, requested) -> UInt64

Effective capabilities = requested ∧ advertised, with policy-only and unsupported bits
removed. Servers lacking PROTOCOL_41, SECURE_CONNECTION, or PLUGIN_AUTH are rejected.
For MariaDB the `CLIENT_MYSQL` bit is cleared so the server reads the extended-capability
field of the response.
"""
function negotiate(server::ServerInfo, requested::UInt64)
    lacking = REQUIRED_SERVER_CAPABILITIES & ~server.capabilities
    lacking == 0 || protocol_error("server lacks required capabilities: $(capability_names(lacking))")
    effective = (requested | REQUIRED_SERVER_CAPABILITIES) & server.capabilities
    effective &= ~CLIENT_POLICY_ONLY_FLAGS
    effective &= ~UNSUPPORTED_CLIENT_CAPABILITIES
    is_mariadb(server) && (effective &= ~CLIENT_MYSQL)
    return effective
end

const CAPABILITY_NAMES = Dict{UInt64, String}(
    CLIENT_LONG_PASSWORD => "CLIENT_LONG_PASSWORD", CLIENT_FOUND_ROWS => "CLIENT_FOUND_ROWS",
    CLIENT_LONG_FLAG => "CLIENT_LONG_FLAG", CLIENT_CONNECT_WITH_DB => "CLIENT_CONNECT_WITH_DB",
    CLIENT_NO_SCHEMA => "CLIENT_NO_SCHEMA", CLIENT_COMPRESS => "CLIENT_COMPRESS", CLIENT_ODBC => "CLIENT_ODBC",
    CLIENT_LOCAL_FILES => "CLIENT_LOCAL_FILES", CLIENT_IGNORE_SPACE => "CLIENT_IGNORE_SPACE",
    CLIENT_PROTOCOL_41 => "CLIENT_PROTOCOL_41", CLIENT_INTERACTIVE => "CLIENT_INTERACTIVE", CLIENT_SSL => "CLIENT_SSL",
    CLIENT_IGNORE_SIGPIPE => "CLIENT_IGNORE_SIGPIPE", CLIENT_TRANSACTIONS => "CLIENT_TRANSACTIONS",
    CLIENT_RESERVED => "CLIENT_RESERVED", CLIENT_SECURE_CONNECTION => "CLIENT_SECURE_CONNECTION",
    CLIENT_MULTI_STATEMENTS => "CLIENT_MULTI_STATEMENTS", CLIENT_MULTI_RESULTS => "CLIENT_MULTI_RESULTS",
    CLIENT_PS_MULTI_RESULTS => "CLIENT_PS_MULTI_RESULTS", CLIENT_PLUGIN_AUTH => "CLIENT_PLUGIN_AUTH",
    CLIENT_CONNECT_ATTRS => "CLIENT_CONNECT_ATTRS", CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA => "CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA",
    CLIENT_CAN_HANDLE_EXPIRED_PASSWORDS => "CLIENT_CAN_HANDLE_EXPIRED_PASSWORDS", CLIENT_SESSION_TRACK => "CLIENT_SESSION_TRACK",
    CLIENT_DEPRECATE_EOF => "CLIENT_DEPRECATE_EOF", CLIENT_OPTIONAL_RESULTSET_METADATA => "CLIENT_OPTIONAL_RESULTSET_METADATA",
    CLIENT_ZSTD_COMPRESSION_ALGORITHM => "CLIENT_ZSTD_COMPRESSION_ALGORITHM", CLIENT_QUERY_ATTRIBUTES => "CLIENT_QUERY_ATTRIBUTES",
    CLIENT_MULTI_FACTOR_AUTHENTICATION => "CLIENT_MULTI_FACTOR_AUTHENTICATION", CLIENT_CAPABILITY_EXTENSION => "CLIENT_CAPABILITY_EXTENSION",
    CLIENT_SSL_VERIFY_SERVER_CERT => "CLIENT_SSL_VERIFY_SERVER_CERT", CLIENT_REMEMBER_OPTIONS => "CLIENT_REMEMBER_OPTIONS",
    MARIADB_CLIENT_PROGRESS => "MARIADB_CLIENT_PROGRESS", MARIADB_CLIENT_COM_MULTI => "MARIADB_CLIENT_COM_MULTI",
    MARIADB_CLIENT_STMT_BULK_OPERATIONS => "MARIADB_CLIENT_STMT_BULK_OPERATIONS", MARIADB_CLIENT_EXTENDED_METADATA => "MARIADB_CLIENT_EXTENDED_METADATA",
    MARIADB_CLIENT_CACHE_METADATA => "MARIADB_CLIENT_CACHE_METADATA", MARIADB_CLIENT_BULK_UNIT_RESULTS => "MARIADB_CLIENT_BULK_UNIT_RESULTS",
)

function capability_names(caps::UInt64)
    names = String[]
    for bit in 0:63
        flag = UInt64(1) << bit
        (caps & flag) == 0 && continue
        push!(names, get(() -> "bit$bit", CAPABILITY_NAMES, flag))
    end
    return join(names, "|")
end

# ---- client → server packets ----

function write_response_prefix!(buf::Vector{UInt8}, caps::UInt64, max_packet::Integer, charset::UInt8, mariadb::Bool)
    write_u32!(buf, caps & 0xFFFFFFFF)
    write_u32!(buf, max_packet)
    write_u8!(buf, charset)
    if mariadb
        write_zeros!(buf, HANDSHAKE_RESPONSE_FILLER_LENGTH - 4)
        write_u32!(buf, (caps >> 32) & 0xFFFFFFFF)
    else
        write_zeros!(buf, HANDSHAKE_RESPONSE_FILLER_LENGTH)
    end
    return nothing
end

"""
    build_ssl_request(caps, max_packet, charset; mariadb=false) -> Vector{UInt8}

HandshakeResponse41 truncated before the username. `caps` must include `CLIENT_SSL`.
"""
function build_ssl_request(caps::UInt64, max_packet::Integer, charset::UInt8; mariadb::Bool=false)
    has_capability(caps, CLIENT_SSL) || throw(ArgumentError("SSLRequest requires CLIENT_SSL in the capability flags"))
    buf = UInt8[]
    write_response_prefix!(buf, caps, max_packet, charset, mariadb)
    return buf
end

"""
    build_handshake_response(caps, max_packet, charset, user, auth_response, plugin; db="", attrs=[], mariadb=false, zstd_level=nothing)

Protocol::HandshakeResponse41. The auth response is length-encoded when
`CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA` is negotiated and otherwise limited to 255 bytes.
"""
function build_handshake_response(caps::UInt64, max_packet::Integer, charset::UInt8, user::AbstractString, auth_response::AbstractVector{UInt8}, plugin::AbstractString; db::AbstractString="", attrs::Vector{Pair{String, String}}=Pair{String, String}[], mariadb::Bool=false, zstd_level::Union{Nothing, Integer}=nothing)
    buf = UInt8[]
    write_response_prefix!(buf, caps, max_packet, charset, mariadb)
    write_nul_string!(buf, user)
    if has_capability(caps, CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA)
        write_lenenc_bytes!(buf, auth_response)
    else
        length(auth_response) <= 255 || throw(ArgumentError("auth response longer than 255 bytes requires CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA"))
        write_u8!(buf, length(auth_response))
        write_bytes!(buf, auth_response)
    end
    if has_capability(caps, CLIENT_CONNECT_WITH_DB)
        write_nul_string!(buf, db)
    end
    if has_capability(caps, CLIENT_PLUGIN_AUTH)
        write_nul_string!(buf, plugin)
    end
    if has_capability(caps, CLIENT_CONNECT_ATTRS)
        attrbuf = UInt8[]
        for (k, v) in attrs
            write_lenenc_string!(attrbuf, k)
            write_lenenc_string!(attrbuf, v)
        end
        write_lenenc_bytes!(buf, attrbuf)
    end
    if has_capability(caps, CLIENT_ZSTD_COMPRESSION_ALGORITHM)
        zstd_level === nothing && throw(ArgumentError("CLIENT_ZSTD_COMPRESSION_ALGORITHM requires a zstd level"))
        write_u8!(buf, zstd_level)
    end
    return buf
end
