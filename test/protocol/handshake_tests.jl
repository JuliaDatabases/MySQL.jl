view_of(packet::Vector{UInt8}) = P.PacketView(Vectors.payload(packet), 1, length(packet) - 4, packet[4], 1, length(packet) - 4)

# Realistic MySQL 8.x server capability set (everything a stock server advertises).
const MYSQL8_SERVER_CAPS = P.CLIENT_LONG_PASSWORD | P.CLIENT_FOUND_ROWS | P.CLIENT_LONG_FLAG |
    P.CLIENT_CONNECT_WITH_DB | P.CLIENT_NO_SCHEMA | P.CLIENT_COMPRESS | P.CLIENT_ODBC |
    P.CLIENT_LOCAL_FILES | P.CLIENT_IGNORE_SPACE | P.CLIENT_PROTOCOL_41 | P.CLIENT_INTERACTIVE |
    P.CLIENT_SSL | P.CLIENT_IGNORE_SIGPIPE | P.CLIENT_TRANSACTIONS | P.CLIENT_RESERVED |
    P.CLIENT_SECURE_CONNECTION | P.CLIENT_MULTI_STATEMENTS | P.CLIENT_MULTI_RESULTS |
    P.CLIENT_PS_MULTI_RESULTS | P.CLIENT_PLUGIN_AUTH | P.CLIENT_CONNECT_ATTRS |
    P.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA | P.CLIENT_CAN_HANDLE_EXPIRED_PASSWORDS |
    P.CLIENT_SESSION_TRACK | P.CLIENT_DEPRECATE_EOF | P.CLIENT_OPTIONAL_RESULTSET_METADATA |
    P.CLIENT_ZSTD_COMPRESSION_ALGORITHM | P.CLIENT_QUERY_ATTRIBUTES |
    P.CLIENT_MULTI_FACTOR_AUTHENTICATION | P.CLIENT_CAPABILITY_EXTENSION |
    P.CLIENT_SSL_VERIFY_SERVER_CERT | P.CLIENT_REMEMBER_OPTIONS

# A MariaDB server: CLIENT_MYSQL clear, extended bits present.
const MARIADB_SERVER_CAPS = (MYSQL8_SERVER_CAPS & ~(P.CLIENT_MYSQL | P.CLIENT_OPTIONAL_RESULTSET_METADATA | P.CLIENT_QUERY_ATTRIBUTES | P.CLIENT_ZSTD_COMPRESSION_ALGORITHM | P.CLIENT_MULTI_FACTOR_AUTHENTICATION)) |
    P.MARIADB_CLIENT_PROGRESS | P.MARIADB_CLIENT_STMT_BULK_OPERATIONS | P.MARIADB_CLIENT_EXTENDED_METADATA | P.MARIADB_CLIENT_CACHE_METADATA

"""
    greeting(; kw...) -> Vector{UInt8}

Builds a synthetic HandshakeV10 payload. `caps` may carry MariaDB extended bits (written
into the reserved field when `CLIENT_MYSQL` is clear).
"""
function greeting(; version="8.4.3", connection_id=7, caps=MYSQL8_SERVER_CAPS, charset=0xFF, status=0x0002, plugin="caching_sha2_password", scramble=collect(UInt8, 1:20))
    buf = UInt8[P.HANDSHAKE_PROTOCOL_VERSION]
    P.write_nul_string!(buf, version)
    P.write_u32!(buf, connection_id)
    P.write_bytes!(buf, scramble[1:8])
    P.write_u8!(buf, 0x00)
    P.write_u16!(buf, caps & 0xFFFF)
    P.write_u8!(buf, charset)
    P.write_u16!(buf, status)
    P.write_u16!(buf, (caps >> 16) & 0xFFFF)
    P.write_u8!(buf, (caps & P.CLIENT_PLUGIN_AUTH) != 0 ? length(scramble) + 1 : 0)
    P.write_zeros!(buf, 6)
    if (caps & P.CLIENT_MYSQL) != 0
        P.write_zeros!(buf, 4)
    else
        P.write_u32!(buf, (caps >> 32) & 0xFFFFFFFF)
    end
    P.write_bytes!(buf, scramble[9:end])
    P.write_u8!(buf, 0x00)
    (caps & P.CLIENT_PLUGIN_AUTH) != 0 && P.write_nul_string!(buf, plugin)
    return buf
end

pview(payload::Vector{UInt8}; seq=0x00) = P.PacketView(payload, 1, length(payload), UInt8(seq), 1, length(payload))

@testset "handshake" begin
    @testset "vendor HandshakeV10 (5.5.2-m2, no PLUGIN_AUTH)" begin
        info = P.parse_handshake_v10(view_of(Vectors.HANDSHAKE_V10_552))
        @test info.raw_version == "5.5.2-m2"
        @test info.version == v"5.5.2"
        @test info.kind == :mysql
        @test info.connection_id == 0x52
        @test info.capabilities == 0xFFFF
        @test info.charset == 8
        @test info.status == 0x0002
        @test info.auth_plugin == ""
        @test info.auth_plugin_data == Vector{UInt8}(codeunits("\"=NP)u9V)d@R\\Uxz|!)K"))
        @test length(info.auth_plugin_data) == 20
        err = try; P.negotiate(info, P.DEFAULT_CLIENT_CAPABILITIES); nothing; catch e; e; end
        @test err isa P.ProtocolError && occursin("CLIENT_PLUGIN_AUTH", err.msg)
    end

    @testset "synthetic MySQL 8.4 greeting and negotiation" begin
        info = P.parse_handshake_v10(pview(greeting()))
        @test info.version == v"8.4.3" && info.kind == :mysql
        @test info.auth_plugin == "caching_sha2_password"
        @test info.auth_plugin_data == collect(UInt8, 1:20)
        @test info.charset == 0xFF
        @test P.has_capability(info.capabilities, P.CLIENT_DEPRECATE_EOF)
        caps = P.negotiate(info, P.DEFAULT_CLIENT_CAPABILITIES)
        @test caps == P.DEFAULT_CLIENT_CAPABILITIES
        # policy-only and unsupported bits are stripped even when requested
        caps = P.negotiate(info, P.DEFAULT_CLIENT_CAPABILITIES | P.CLIENT_SSL_VERIFY_SERVER_CERT | P.CLIENT_QUERY_ATTRIBUTES | P.CLIENT_COMPRESS)
        @test caps == P.DEFAULT_CLIENT_CAPABILITIES
        # a flag the server did not advertise is dropped
        info = P.parse_handshake_v10(pview(greeting(; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_DEPRECATE_EOF)))
        @test !P.has_capability(P.negotiate(info, P.DEFAULT_CLIENT_CAPABILITIES), P.CLIENT_DEPRECATE_EOF)
        # servers without PROTOCOL_41 or SECURE_CONNECTION are rejected
        info = P.parse_handshake_v10(pview(greeting(; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SECURE_CONNECTION)))
        @test_throws P.ProtocolError P.negotiate(info, P.DEFAULT_CLIENT_CAPABILITIES)
        @test_throws P.ProtocolError P.parse_handshake_v10(pview(greeting(; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_PROTOCOL_41)))
        @test_throws P.ProtocolError P.parse_handshake_v10(pview(UInt8[0x09, 0x00]))
        # truncated greeting
        @test_throws P.ProtocolError P.parse_handshake_v10(pview(greeting()[1:20]))
    end

    @testset "MariaDB greeting: extended capabilities and version normalization" begin
        info = P.parse_handshake_v10(pview(greeting(; version="5.5.5-10.11.8-MariaDB-log", caps=MARIADB_SERVER_CAPS, plugin="mysql_native_password")))
        @test info.kind == :mariadb
        @test info.version == v"10.11.8"
        @test P.has_capability(info.capabilities, P.MARIADB_CLIENT_STMT_BULK_OPERATIONS)
        @test P.has_capability(info.capabilities, P.MARIADB_CLIENT_CACHE_METADATA)
        @test !P.has_capability(info.capabilities, P.CLIENT_MYSQL)
        caps = P.negotiate(info, P.DEFAULT_CLIENT_CAPABILITIES | P.MARIADB_CLIENT_STMT_BULK_OPERATIONS)
        @test !P.has_capability(caps, P.CLIENT_MYSQL)
        @test (caps >> 32) == 0
        @test P.has_capability(caps, P.CLIENT_DEPRECATE_EOF)
        info = P.parse_handshake_v10(pview(greeting(; version="11.4.2-MariaDB", caps=MARIADB_SERVER_CAPS)))
        @test info.version == v"11.4.2" && info.kind == :mariadb
        # the 5.5.5- prefix is only stripped for MariaDB
        @test P.normalize_version("5.5.5-10.6.1-MariaDB", :mysql) == v"5.5.5"
        @test P.normalize_version("garbage", :mysql) == v"0.0.0"
        @test P.detect_kind("8.0.11-TiDB-v7.5.0", MYSQL8_SERVER_CAPS) == :tidb
        @test P.detect_kind("8.0.30-Vitess", MYSQL8_SERVER_CAPS) == :vitess
        @test P.detect_kind("8.4.3", MYSQL8_SERVER_CAPS) == :mysql
        @test P.detect_kind("10.6.1-xyz", MYSQL8_SERVER_CAPS & ~P.CLIENT_MYSQL) == :mariadb
    end

    @testset "initial ERR keeps the whole message and no SQLSTATE" begin
        e = P.parse_initial_err(pview(vcat(UInt8[0xFF, 0x10, 0x04], codeunits("#ABCDEToo many connections"))))
        @test e.code == 0x0410
        @test e.sqlstate == ""
        @test e.msg == "#ABCDEToo many connections"
        @test_throws P.ProtocolError P.parse_initial_err(pview(UInt8[0xFF, 0xDD, 0x07]))
        @test_throws P.ProtocolError P.parse_initial_err(pview(UInt8[0xFF, 0xFF, 0xFF]))
    end

    @testset "vendor SSLRequest and HandshakeResponse41" begin
        @test P.build_ssl_request(UInt64(0x0003ae05), 16777216, 0x08) == Vectors.payload(Vectors.SSL_REQUEST_552)
        @test_throws ArgumentError P.build_ssl_request(UInt64(0x0003a605), 16777216, 0x08)
        auth = hexbytes("14 63 6b 70 99 8a b6 9e 96 87 a2 30 9a 40 67 2b 83 38 85 4b")
        @test P.build_handshake_response(UInt64(0x0003a605), 16777216, 0x08, "root", auth, "") == Vectors.payload(Vectors.HANDSHAKE_RESPONSE_552)
        auth = hexbytes("22 50 79 a2 12 d4 e8 82 e5 b3 f4 1a 97 75 6b c8 be db 9f 80")
        attrs = ["_os" => "debian6.0", "_client_name" => "libmysql", "_pid" => "22344", "_client_version" => "5.6.6-m9", "_platform" => "x86_64", "foo" => "bar"]
        response = P.build_handshake_response(UInt64(0x001ea285), 0x40000000, 0x08, "root", auth, "mysql_native_password"; attrs=attrs)
        @test response == Vectors.payload(Vectors.HANDSHAKE_RESPONSE_566_ATTRS)
    end

    @testset "HandshakeResponse41 variants" begin
        caps = P.DEFAULT_CLIENT_CAPABILITIES | P.CLIENT_CONNECT_WITH_DB
        r = P.build_handshake_response(caps, 16777216, 0x2D, "u", zeros(UInt8, 300), "caching_sha2_password"; db="db")
        c = P.PacketCursor(r)
        @test P.read_u32!(c) == caps & 0xFFFFFFFF
        @test P.read_u32!(c) == 16777216
        @test P.read_u8!(c) == 0x2D
        P.skip!(c, 23)
        @test P.read_nul_string!(c) == "u"
        @test length(P.read_lenenc_bytes!(c)) == 300
        @test P.read_nul_string!(c) == "db"
        @test P.read_nul_string!(c) == "caching_sha2_password"
        @test P.read_lenenc!(c) == 0   # empty attrs block
        @test P.atend(c)
        # without LENENC_CLIENT_DATA the auth response is limited to 255 bytes
        @test_throws ArgumentError P.build_handshake_response(caps & ~P.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA, 1, 0x2D, "u", zeros(UInt8, 256), "p")
        # MariaDB layout: 19 filler bytes + extended capabilities
        r = P.build_handshake_response((caps & ~P.CLIENT_MYSQL) | P.MARIADB_CLIENT_CACHE_METADATA, 16777216, 0x2D, "u", UInt8[], "p"; mariadb=true)
        c = P.PacketCursor(r)
        P.skip!(c, 9)
        P.skip!(c, 19)
        @test P.read_u32!(c) == UInt32(P.MARIADB_CLIENT_CACHE_METADATA >> 32)
        @test P.read_nul_string!(c) == "u"
        @test_throws ArgumentError P.build_handshake_response(caps, 1, 0x2D, "a\0b", UInt8[], "p")
    end

    @testset "capability names" begin
        @test P.capability_names(P.CLIENT_SSL | P.CLIENT_DEPRECATE_EOF) == "CLIENT_SSL|CLIENT_DEPRECATE_EOF"
        @test P.capability_names(P.MARIADB_CLIENT_PROGRESS) == "MARIADB_CLIENT_PROGRESS"
        @test P.capability_names(UInt64(1) << 40) == "bit40"
    end
end
