# Scenario tests: a Protocol.Session talks to the scripted FakePeer over loopback TCP.
# Handlers run on another task, so they never call @test; they record what they saw and the
# client side asserts after the exchange.
using .FakePeer: send_packet, send_raw, read_packet, read_command, read_chunk, read_exact, with_peer

const CAPS_NO_DEPRECATE_EOF = P.DEFAULT_CLIENT_CAPABILITIES & ~P.CLIENT_DEPRECATE_EOF
const CAPS_WITH_LOCAL_FILES = P.DEFAULT_CLIENT_CAPABILITIES | P.CLIENT_LOCAL_FILES

# Sends a logical packet the way a server does, splitting at 0xFFFFFF. Returns the next seq.
function send_logical(conn, seq::Integer, payload::Vector{UInt8})
    offset = 0
    while true
        n = min(P.MAX_CHUNK, length(payload) - offset)
        send_packet(conn, seq, payload[(offset + 1):(offset + n)])
        seq = (seq + 1) & 0xFF
        offset += n
        n < P.MAX_CHUNK && break
    end
    return seq
end

# Server side of a successful connection phase; returns the sequence id of the OK it sent.
function server_handshake!(conn; record=nothing, ok=ok_payload(), kw...)
    send_packet(conn, 0, greeting(; kw...))
    seq, response = read_packet(conn)
    record === nothing || push!(record, response)
    send_packet(conn, seq + 1, ok)
    return seq + 1
end

function client_handshake!(s; user="root", plugin="caching_sha2_password")
    P.read_greeting!(s)
    P.send_handshake_response!(s, user, zeros(UInt8, 32), plugin)
    pkt = P.read_auth_packet!(s, 1, 0)
    kind, ok = pkt.kind, pkt.ok
    return ok
end

# Waits for the client to hang up (used after the server deliberately breaks the protocol).
function await_eof(conn)
    try
        read_exact(conn, 1)
    catch
    end
    return nothing
end

text_row(values...) = begin
    buf = UInt8[]
    for v in values
        v === nothing ? push!(buf, P.NULL_VALUE) : P.write_lenenc_string!(buf, v)
    end
    buf
end

column_count(n) = begin
    buf = UInt8[]
    P.write_lenenc!(buf, n)
    buf
end

function declared_column_allocation(n::Int)
    s = P.Session(P.FaultTransport(IOBuffer(framed(0x00, column_count(n)))); limits=P.Limits(; max_columns=n, max_metadata_bytes=1))
    s.authenticated = true
    s.phase = P.CMD_SENT
    try
        P.read_command_response!(s)
    catch
    end
    return nothing
end

function declared_prepare_allocation(n::Int)
    payload = UInt8[P.OK_HEADER]
    P.write_u32!(payload, 1)
    P.write_u16!(payload, n)
    P.write_u16!(payload, 0)
    P.write_u8!(payload, 0)
    P.write_u16!(payload, 0)
    s = P.Session(P.FaultTransport(IOBuffer(framed(0x00, payload))); limits=P.Limits(; max_columns=n, max_metadata_bytes=1))
    s.authenticated = true
    s.phase = P.CMD_SENT
    s.command_kind = P.CMD_STMT_PREPARE
    try
        P.read_prepare_response!(s)
    catch
    end
    return nothing
end

const COL1 = Vectors.payload(Vectors.COLUMN_DEF_COL1)

mutable struct FailingUpload <: IO
    source::IOBuffer
    reads::Int
end

Base.eof(io::FailingUpload) = eof(io.source)

function Base.readbytes!(io::FailingUpload, buffer::AbstractVector{UInt8}, n::Integer=length(buffer))
    io.reads += 1
    io.reads == 2 && error("injected upload source failure")
    return readbytes!(io.source, buffer, n)
end

@testset "session scenarios" begin
    @testset "greeting, handshake response, auth OK" begin
        seen = Vector{UInt8}[]
        with_peer(conn -> server_handshake!(conn; record=seen)) do client
            s = P.Session(client; capabilities=P.DEFAULT_CLIENT_CAPABILITIES | P.CLIENT_CONNECT_WITH_DB, log_transitions=true)
            @test s.phase == P.CONNECTING
            info = P.read_greeting!(s)
            @test s.phase == P.HANDSHAKE
            @test info.kind == :mysql && info.version == v"8.4.3"
            @test P.has_capability(s, P.CLIENT_DEPRECATE_EOF) && P.has_capability(s, P.CLIENT_SESSION_TRACK)
            @test !P.has_capability(s, P.CLIENT_QUERY_ATTRIBUTES)
            P.send_handshake_response!(s, "root", zeros(UInt8, 32), "caching_sha2_password"; db="test", attrs=["_client_name" => "MySQL.jl"])
            @test s.phase == P.AUTH
            @test P.has_capability(s, P.CLIENT_CONNECT_WITH_DB)
            pkt = P.read_auth_packet!(s, 1, 0)
    kind, ok = pkt.kind, pkt.ok
            @test kind == :ok && ok isa P.OKPacket
            @test s.phase == P.READY && s.authenticated && isopen(s)
            @test s.transition_log == [(P.CONNECTING, :greeting, P.HANDSHAKE), (P.HANDSHAKE, :handshake_response, P.AUTH), (P.AUTH, :auth_ok, P.READY)]
        end
        @test length(seen) == 1
        c = P.PacketCursor(seen[1])
        caps = P.read_u32!(c)
        @test caps & P.CLIENT_CONNECT_WITH_DB != 0 && caps & P.CLIENT_DEPRECATE_EOF != 0
        @test P.read_u32!(c) == P.DEFAULT_MAX_PACKET
        @test P.read_u8!(c) == P.CHARSET_UTF8MB4_GENERAL_CI
        P.skip!(c, 23)
        @test P.read_nul_string!(c) == "root"
        @test length(P.read_lenenc_bytes!(c)) == 32
        @test P.read_nul_string!(c) == "test"
        @test P.read_nul_string!(c) == "caching_sha2_password"
    end

    @testset "database capability must be negotiated" begin
        caps = MYSQL8_SERVER_CAPS & ~P.CLIENT_CONNECT_WITH_DB
        with_peer(conn -> (send_packet(conn, 0, greeting(; caps=caps)); await_eof(conn))) do client
            s = P.Session(client; capabilities=P.DEFAULT_CLIENT_CAPABILITIES | P.CLIENT_CONNECT_WITH_DB)
            P.read_greeting!(s)
            @test !P.has_capability(s, P.CLIENT_CONNECT_WITH_DB)
            @test_throws P.ProtocolError P.send_handshake_response!(s, "root", UInt8[], "caching_sha2_password"; db="app")
            @test s.phase == P.HANDSHAKE
        end
    end

    @testset "pre-capability initial ERR" begin
        with_peer(conn -> (send_packet(conn, 0, vcat(UInt8[0xFF, 0x10, 0x04], codeunits("Too many connections"))); await_eof(conn))) do client
            s = P.Session(client)
            err = try; P.read_greeting!(s); nothing; catch e; e; end
            @test err isa P.Error && err.errno == 1040 && err.sqlstate == "" && err.msg == "Too many connections"
            @test s.phase == P.CLOSED && !isopen(s)
        end
    end

    @testset "auth switch and AuthMoreData envelope (MySQL)" begin
        replies = Vector{UInt8}[]
        with_peer(conn -> begin
            send_packet(conn, 0, greeting(; plugin="mysql_native_password"))
            read_packet(conn)
            send_packet(conn, 2, vcat(UInt8[0xFE], codeunits("caching_sha2_password"), UInt8[0x00], collect(UInt8, 21:40)))
            seq, reply = read_packet(conn)
            push!(replies, reply)
            send_packet(conn, seq + 1, UInt8[0x01, 0x03])
            send_packet(conn, seq + 2, ok_payload())
        end) do client
            s = P.Session(client)
            P.read_greeting!(s)
            P.send_handshake_response!(s, "root", zeros(UInt8, 20), "mysql_native_password")
            pkt = P.read_auth_packet!(s, 1, 0)
            kind, req = pkt.kind, pkt
            @test kind == :auth_switch && req.switch_plugin == "caching_sha2_password" && req.data == collect(UInt8, 21:40)
            P.send_auth_data!(s, fill(0xAA, 32))
            pkt = P.read_auth_packet!(s, 2, length(req.data))
            kind, more = pkt.kind, pkt
            @test kind == :auth_more && more.data == [P.CACHING_SHA2_FAST_AUTH_SUCCESS]
            pkt = P.read_auth_packet!(s, 3, 0)
            kind, ok = pkt.kind, pkt.ok
            @test kind == :ok && s.phase == P.READY
        end
        @test replies == [fill(0xAA, 32)]
    end

    @testset "MariaDB plugin data with and without the 0x01 prefix" begin
        with_peer(conn -> begin
            send_packet(conn, 0, greeting(; version="11.4.2-MariaDB", caps=MARIADB_SERVER_CAPS, plugin="mysql_native_password"))
            read_packet(conn)
            send_packet(conn, 2, UInt8[0x41, 0x42])
            send_packet(conn, 3, UInt8[0x01, 0x43])
            send_packet(conn, 4, UInt8[0x02, 0x44])
            send_packet(conn, 5, ok_payload())
        end) do client
            s = P.Session(client)
            info = P.read_greeting!(s)
            @test info.kind == :mariadb && !P.has_capability(s, P.CLIENT_MYSQL)
            P.send_handshake_response!(s, "root", zeros(UInt8, 20), "mysql_native_password")
            pkt = P.read_auth_packet!(s, 1, 0); @test (pkt.kind, pkt.data) == (:plugin_data, UInt8[0x41, 0x42])
            pkt = P.read_auth_packet!(s, 2, 2); @test (pkt.kind, pkt.data) == (:plugin_data, UInt8[0x43])
            pkt = P.read_auth_packet!(s, 3, 4); @test (pkt.kind, pkt.data) == (:plugin_data, UInt8[0x02, 0x44])   # 0x02 is plugin data for MariaDB; only a leading 0x01 is stripped
            @test P.read_auth_packet!(s, 4, 6).kind == :ok
        end
    end

    @testset "unsupported authentication requests" begin
        with_peer(conn -> (send_packet(conn, 0, greeting()); await_eof(conn))) do client
            s = P.Session(client)
            P.read_greeting!(s)
            @test_throws ArgumentError P.authenticate!(s, "bad\0user", "pw", P.AuthPolicy())
            @test s.phase == P.CLOSED && !isopen(s)
        end
        # an unknown server default: the client answers with its own default plugin and the
        # server switches to the account's plugin — unsupported here, so the switch is refused
        announced = Vector{UInt8}[]
        with_peer(conn -> begin
            send_packet(conn, 0, greeting(; plugin="client_ed25519"))
            seq, response = read_packet(conn)
            push!(announced, response)
            send_packet(conn, seq + 1, vcat(UInt8[0xFE], codeunits("client_ed25519"), UInt8[0x00], zeros(UInt8, 32)))
            await_eof(conn)
        end) do client
            s = P.Session(client)
            P.read_greeting!(s)
            err = try; P.authenticate!(s, "root", "pw", P.AuthPolicy()); nothing; catch e; e; end
            @test err isa P.UnsupportedAuthError && err.plugin == "client_ed25519"
            @test s.phase == P.CLOSED
        end
        @test occursin("caching_sha2_password", String(copy(announced[1])))
        # ... and an account on a supported plugin behind such a server still connects
        with_peer(conn -> begin
            send_packet(conn, 0, greeting(; plugin="client_ed25519"))
            seq, _ = read_packet(conn)
            send_packet(conn, seq + 1, vcat(UInt8[0xFE], codeunits("mysql_native_password"), UInt8[0x00], collect(UInt8, 1:20), UInt8[0x00]))
            seq, _ = read_packet(conn)
            send_packet(conn, seq + 1, ok_payload())
        end) do client
            s = P.Session(client)
            P.read_greeting!(s)
            @test P.authenticate!(s, "root", "pw", P.AuthPolicy()) isa P.OKPacket
            @test s.phase == P.READY
        end
        with_peer(conn -> (send_packet(conn, 0, greeting()); read_packet(conn); send_packet(conn, 2, vcat(UInt8[0x02], codeunits("authentication_webauthn_client"), UInt8[0x00])); await_eof(conn))) do client
            s = P.Session(client)
            P.read_greeting!(s)
            P.send_handshake_response!(s, "root", UInt8[], "caching_sha2_password")
            @test_throws P.UnsupportedAuthError P.read_auth_packet!(s, 1, 0)
            @test s.phase == P.CLOSED
        end
        with_peer(conn -> (send_packet(conn, 0, greeting()); read_packet(conn); send_packet(conn, 2, UInt8[0xFE]); await_eof(conn))) do client
            s = P.Session(client)
            P.read_greeting!(s)
            P.send_handshake_response!(s, "root", UInt8[], "caching_sha2_password")
            err = try; P.read_auth_packet!(s, 1, 0); nothing; catch e; e; end
            @test err isa P.UnsupportedAuthError && err.plugin == "mysql_old_password"
            @test s.phase == P.CLOSED
        end
    end

    @testset "auth ERR closes the session" begin
        with_peer(conn -> (send_packet(conn, 0, greeting()); read_packet(conn); send_packet(conn, 2, vcat(UInt8[0xFF, 0x15, 0x04], codeunits("#28000Access denied"))); await_eof(conn))) do client
            s = P.Session(client)
            P.read_greeting!(s)
            P.send_handshake_response!(s, "root", UInt8[], "caching_sha2_password")
            err = try; P.read_auth_packet!(s, 1, 0); nothing; catch e; e; end
            @test err isa P.Error && err.errno == P.ER_ACCESS_DENIED_ERROR && err.sqlstate == "28000"
            @test s.phase == P.CLOSED
        end
    end

    @testset "authentication round and byte limits" begin
        with_peer(conn -> (send_packet(conn, 0, greeting()); read_packet(conn); for i in 2:4; send_packet(conn, i, UInt8[0x01, 0x04]); end; await_eof(conn))) do client
            s = P.Session(client; limits=P.Limits(; max_auth_rounds=2))
            P.read_greeting!(s)
            P.send_handshake_response!(s, "root", UInt8[], "caching_sha2_password")
            @test P.read_auth_packet!(s, 1, 0).kind == :auth_more
            @test P.read_auth_packet!(s, 2, 2).kind == :auth_more
            @test_throws P.ProtocolError P.read_auth_packet!(s, 3, 4)
            @test s.phase == P.BROKEN && !isopen(s)
        end
        with_peer(conn -> (send_packet(conn, 0, greeting()); read_packet(conn); send_packet(conn, 2, vcat(UInt8[0x01], zeros(UInt8, 32))); await_eof(conn))) do client
            s = P.Session(client; limits=P.Limits(; max_auth_bytes=16))
            P.read_greeting!(s)
            P.send_handshake_response!(s, "root", UInt8[], "caching_sha2_password")
            @test_throws P.ProtocolError P.read_auth_packet!(s, 1, 0)
            @test s.phase == P.BROKEN
        end
        # The auth-byte bound is applied to the declared packet length before its body arrives.
        with_peer(conn -> begin
            send_packet(conn, 0, greeting())
            read_packet(conn)
            send_raw(conn, UInt8[0x20, 0x00, 0x00, 0x02])
            await_eof(conn)
        end) do client
            s = P.Session(client; limits=P.Limits(; max_auth_bytes=16))
            P.read_greeting!(s)
            P.send_handshake_response!(s, "root", UInt8[], "caching_sha2_password")
            @test_throws P.ProtocolError P.read_auth_packet!(s, 1, 0)
            @test s.phase == P.BROKEN && !isopen(s)
        end
        with_peer(conn -> begin
            send_packet(conn, 0, greeting())
            read_packet(conn)
            send_packet(conn, 2, UInt8[0x01, 0x03])
            send_packet(conn, 3, UInt8[0x01, 0x03])
            await_eof(conn)
        end) do client
            s = P.Session(client; limits=P.Limits(; max_auth_bytes=3))
            P.read_greeting!(s)
            @test_throws P.ProtocolError P.authenticate!(s, "root", "pw", P.AuthPolicy())
            @test s.phase == P.BROKEN
        end
    end

    @testset "STARTTLS framing: SSLRequest then response on the new transport" begin
        seen = Vector{UInt8}[]
        with_peer(conn -> begin
            send_packet(conn, 0, greeting())
            seq, sslreq = read_packet(conn)
            push!(seen, sslreq)
            seq2, response = read_packet(conn)
            push!(seen, response)
            send_packet(conn, seq2 + 1, ok_payload())
        end) do client
            s = P.Session(client)
            P.read_greeting!(s)
            P.send_ssl_request!(s)
            @test s.phase == P.TLS_UPGRADE && P.has_capability(s, P.CLIENT_SSL)
            P.replace_transport!(s, client)   # stands in for the TLS.Conn (M2)
            @test s.phase == P.HANDSHAKE
            P.send_handshake_response!(s, "root", zeros(UInt8, 32), "caching_sha2_password")
            @test P.read_auth_packet!(s, 1, 0).kind == :ok
        end
        @test length(seen[1]) == 32 && P.read_u32!(P.PacketCursor(seen[1])) & P.CLIENT_SSL != 0
        @test P.read_u32!(P.PacketCursor(seen[2])) & P.CLIENT_SSL != 0
        with_peer(conn -> (send_packet(conn, 0, greeting(; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL)); await_eof(conn))) do client
            s = P.Session(client)
            P.read_greeting!(s)
            @test_throws P.AuthError P.send_ssl_request!(s)
            @test s.phase == P.HANDSHAKE
        end
    end

    @testset "COM_QUERY → OK, COM_PING, sequence reset per command" begin
        commands = Tuple{UInt8, UInt8, Vector{UInt8}}[]
        with_peer(conn -> begin
            server_handshake!(conn)
            push!(commands, read_command(conn))
            send_packet(conn, 1, ok_payload(; affected=2, insert_id=9, info="Rows matched: 2", track=true))
            push!(commands, read_command(conn))
            send_packet(conn, 1, ok_payload())
        end) do client
            s = P.Session(client)
            client_handshake!(s)
            P.query!(s, "UPDATE t SET a = 1")
            @test s.phase == P.CMD_SENT
            ok = P.read_command_response!(s)
            @test ok.affected_rows == 2 && ok.last_insert_id == 9 && ok.info == "Rows matched: 2"
            @test s.phase == P.READY
            P.ping!(s)
            @test P.read_command_response!(s; kind=P.CMD_SIMPLE) isa P.OKPacket
        end
        @test commands[1][1] == 0 && commands[1][2] == P.COM_QUERY && String(commands[1][3]) == "UPDATE t SET a = 1"
        @test commands[2][1] == 0 && commands[2][2] == P.COM_PING && isempty(commands[2][3])
    end

    @testset "OK with MORE_RESULTS_EXISTS, then next_result!" begin
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, ok_payload(; affected=1, status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_MORE_RESULTS_EXISTS))
            send_packet(conn, 2, ok_payload(; affected=2))
        end) do client
            s = P.Session(client)
            client_handshake!(s)
            P.query!(s, "DO 1; DO 2")
            ok = P.read_command_response!(s)
            @test P.more_results(ok) && s.phase == P.RESULT_END
            ok2 = P.next_result!(s)
            @test ok2.affected_rows == 2 && s.phase == P.READY && s.result_sets == 2
        end
    end

    @testset "COM_SET_OPTION vendor responses" begin
        seen = Tuple{UInt8, Vector{UInt8}}[]
        cases = (
            (P.MYSQL_OPTION_MULTI_STATEMENTS_ON, UInt8[0xFE, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00], P.DEFAULT_CLIENT_CAPABILITIES, true),
            (P.MYSQL_OPTION_MULTI_STATEMENTS_OFF, UInt8[0xFE, 0x00, 0x00, 0x02, 0x00], CAPS_NO_DEPRECATE_EOF, false),
            (P.MYSQL_OPTION_MULTI_STATEMENTS_ON, UInt8[0xFE], P.DEFAULT_CLIENT_CAPABILITIES, false),
        )
        for (option, reply, caps, expect_ok) in cases
            with_peer(conn -> begin
                server_handshake!(conn)
                _, command, data = read_command(conn)
                push!(seen, (command, data))
                send_packet(conn, 1, reply)
            end) do client
                s = P.Session(client; capabilities=caps)
                client_handshake!(s)
                P.set_option!(s, option)
                @test s.command_kind == P.CMD_SET_OPTION
                response = P.read_command_response!(s)
                @test (response isa P.OKPacket) == expect_ok
                if response isa P.OKPacket
                    @test response.is_eof
                end
                @test response.status == P.SERVER_STATUS_AUTOCOMMIT
                @test s.phase == P.READY && s.result_sets == 1
            end
        end
        @test seen == [(P.COM_SET_OPTION, UInt8[0x00, 0x00]), (P.COM_SET_OPTION, UInt8[0x01, 0x00]), (P.COM_SET_OPTION, UInt8[0x00, 0x00])]
    end

    @testset "server ERR keeps the connection usable" begin
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, vcat(UInt8[0xFF, 0x28, 0x04], codeunits("#42000You have an error in your SQL syntax")))
            read_command(conn)
            send_packet(conn, 1, ok_payload())
        end) do client
            s = P.Session(client)
            client_handshake!(s)
            P.query!(s, "SELEC 1")
            err = try; P.read_command_response!(s); nothing; catch e; e; end
            @test err isa P.Error && err.errno == 1064 && err.sqlstate == "42000"
            @test s.phase == P.READY && isopen(s)
            P.ping!(s)
            @test P.read_command_response!(s; kind=P.CMD_SIMPLE) isa P.OKPacket
        end
    end

    @testset "text result set without DEPRECATE_EOF (vendor transcript)" begin
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_raw(conn, Vectors.TEXT_RESULTSET_REPEAT_A))) do client
            s = P.Session(client; capabilities=CAPS_NO_DEPRECATE_EOF)
            client_handshake!(s)
            @test !P.deprecate_eof(s)
            P.query!(s, "SELECT repeat(\"a\", 50)")
            hdr = P.read_command_response!(s)
            @test hdr isa P.ResultHeader && !hdr.binary && length(hdr.columns) == 1
            col = hdr.columns[1]
            @test col.name == "repeat(\"a\", 50)" && col.charset == 8 && col.length == 50 && col.type == P.MYSQL_TYPE_VAR_STRING
            @test P.is_not_null(col) && col.decimals == 0x1F
            @test s.phase == P.ROWS
            row = P.read_row!(s)
            @test row isa P.PacketView
            offsets, lengths = Int[], Int[]
            P.scan_text_row!(row, 1, offsets, lengths)
            @test lengths == [50] && all(==(UInt8('a')), row.buf[offsets[1]:(offsets[1] + 49)])
            fin = P.read_row!(s)
            @test fin isa P.ResultEnd && fin.ok === nothing && fin.status == P.SERVER_STATUS_AUTOCOMMIT && !fin.more_results
            @test s.phase == P.READY && s.result_sets == 1
        end
    end

    @testset "binary result set (vendor transcript)" begin
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_raw(conn, Vectors.BINARY_RESULTSET_FOOBAR))) do client
            s = P.Session(client; capabilities=CAPS_NO_DEPRECATE_EOF)
            client_handshake!(s)
            P.send_command!(s, P.COM_STMT_EXECUTE, zeros(UInt8, 9))
            hdr = P.read_command_response!(s; kind=P.CMD_STMT_EXECUTE)
            @test hdr.binary && hdr.columns[1].name == "col1"
            row = P.read_row!(s; binary=true)
            @test P.payload(row) == vcat(UInt8[0x00, 0x00, 0x06], codeunits("foobar"))
            @test P.read_row!(s; binary=true) isa P.ResultEnd
            @test s.phase == P.READY
        end
    end

    @testset "CALL multi-resultset (vendor transcript)" begin
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_raw(conn, Vectors.CALL_MULTI_RESULTSET))) do client
            s = P.Session(client; capabilities=CAPS_NO_DEPRECATE_EOF)
            client_handshake!(s)
            P.query!(s, "CALL multi()")
            hdr = P.read_command_response!(s)
            @test hdr.columns[1].name == "1" && hdr.columns[1].type == P.MYSQL_TYPE_LONGLONG
            @test P.read_row!(s) isa P.PacketView
            fin = P.read_row!(s)
            @test fin.more_results && s.phase == P.RESULT_END
            @test P.in_transaction(fin.status) == false
            hdr2 = P.next_result!(s)
            @test hdr2 isa P.ResultHeader && s.phase == P.ROWS
            @test P.read_row!(s) isa P.PacketView
            @test P.read_row!(s).more_results && s.phase == P.RESULT_END
            ok = P.next_result!(s)
            @test ok isa P.OKPacket && ok.affected_rows == 1 && s.phase == P.READY
            @test s.result_sets == 3
        end
    end

    @testset "text result set with DEPRECATE_EOF: NULL, empty, OK terminator with session state" begin
        state = state_block(P.SESSION_TRACK_SCHEMA, "newdb")
        terminator = ok_payload(; header=0xFE, status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_SESSION_STATE_CHANGED, warnings=1, info="", state=state, track=true)
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, column_count(2))
            send_packet(conn, 2, COL1)
            send_packet(conn, 3, COL1)
            send_packet(conn, 4, text_row("foo", nothing))
            send_packet(conn, 5, text_row("", "x"))
            send_packet(conn, 6, terminator)
        end) do client
            s = P.Session(client)
            client_handshake!(s)
            P.query!(s, "SELECT a, b FROM t")
            hdr = P.read_command_response!(s)
            @test length(hdr.columns) == 2 && s.phase == P.ROWS
            offsets, lengths = Int[], Int[]
            P.scan_text_row!(P.read_row!(s), 2, offsets, lengths)
            @test lengths == [3, -1]
            P.scan_text_row!(P.read_row!(s), 2, offsets, lengths)
            @test lengths == [0, 1]
            fin = P.read_row!(s)
            @test fin isa P.ResultEnd && fin.ok !== nothing && fin.ok.is_eof && fin.warnings == 1
            @test P.schema_change(fin.ok) == "newdb"
            @test s.phase == P.READY && s.status & P.SERVER_SESSION_STATE_CHANGED != 0
        end
    end

    @testset "ERR in row state ends the result and keeps the connection" begin
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, column_count(1))
            send_packet(conn, 2, COL1)
            send_packet(conn, 3, text_row("1"))
            send_packet(conn, 4, vcat(UInt8[0xFF, 0x25, 0x05], codeunits("#70100Query execution was interrupted")))
            read_command(conn)
            send_packet(conn, 1, ok_payload())
        end) do client
            s = P.Session(client)
            client_handshake!(s)
            P.query!(s, "SELECT * FROM big")
            P.read_command_response!(s)
            @test P.read_row!(s) isa P.PacketView
            err = try; P.read_row!(s); nothing; catch e; e; end
            @test err isa P.Error && err.errno == P.ER_QUERY_INTERRUPTED
            @test s.phase == P.READY
            P.ping!(s)
            @test P.read_command_response!(s; kind=P.CMD_SIMPLE) isa P.OKPacket
        end
    end

    @testset "a 0xFE-headed row of 2^24 bytes is a row, not a terminator" begin
        huge = UInt8[]
        P.write_lenenc!(huge, 1 << 24)
        append!(huge, fill(UInt8('a'), 1 << 24))
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, column_count(1))
            send_packet(conn, 2, COL1)
            seq = send_logical(conn, 3, huge)
            send_packet(conn, seq, ok_payload(; header=0xFE, track=true))
        end) do client
            s = P.Session(client; limits=P.Limits(; max_packet=32 * 1024 * 1024))
            client_handshake!(s)
            P.query!(s, "SELECT huge FROM t")
            P.read_command_response!(s)
            row = P.read_row!(s)
            @test row isa P.PacketView && row.nchunks == 2 && row.first_chunk_len == P.MAX_CHUNK
            @test P.first_byte(row) == 0xFE && P.payload_length(row) == (1 << 24) + 9
            offsets, lengths = Int[], Int[]
            P.scan_text_row!(row, 1, offsets, lengths)
            @test lengths == [1 << 24]
            @test P.read_row!(s) isa P.ResultEnd && s.phase == P.READY
        end
    end

    @testset "LOCAL INFILE: upload, refusal, size limit, unsolicited" begin
        uploaded = UInt8[]
        packets = Int[]
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, vcat(UInt8[0xFB], codeunits("/tmp/data.csv")))
            seq = 1
            while true
                seq, chunk = read_chunk(conn)
                push!(packets, length(chunk))
                isempty(chunk) && break
                append!(uploaded, chunk)
            end
            send_packet(conn, seq + 1, ok_payload(; affected=2))
        end) do client
            s = P.Session(client; capabilities=CAPS_WITH_LOCAL_FILES)
            client_handshake!(s)
            @test P.has_capability(s, P.CLIENT_LOCAL_FILES)
            P.query!(s, "LOAD DATA LOCAL INFILE '/tmp/data.csv' INTO TABLE t")
            req = P.read_command_response!(s)
            @test req isa P.LocalInfileRequest && String(req.filename) == "/tmp/data.csv"
            @test s.phase == P.LOCAL_INFILE
            @test P.send_local_infile!(s, IOBuffer("a,b\n1,2\n"); chunk_size=4) == 8
            @test s.phase == P.CMD_SENT
            ok = P.read_command_response!(s; kind=P.CMD_SIMPLE)
            @test ok.affected_rows == 2 && s.phase == P.READY
        end
        @test String(uploaded) == "a,b\n1,2\n" && packets == [4, 4, 0]
        # refusal: only the empty terminator is sent
        empty!(packets)
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, vcat(UInt8[0xFB], codeunits("/etc/passwd")))
            seq, chunk = read_chunk(conn)
            push!(packets, length(chunk))
            send_packet(conn, seq + 1, ok_payload())
        end) do client
            s = P.Session(client; capabilities=CAPS_WITH_LOCAL_FILES)
            client_handshake!(s)
            P.query!(s, "LOAD DATA LOCAL INFILE '/etc/passwd' INTO TABLE t")
            @test P.read_command_response!(s) isa P.LocalInfileRequest
            @test P.send_local_infile!(s, nothing) == 0
            @test P.read_command_response!(s; kind=P.CMD_SIMPLE) isa P.OKPacket
        end
        @test packets == [0]
        # size limit: faults before the oversize chunk is written
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, vcat(UInt8[0xFB], codeunits("f"))); await_eof(conn))) do client
            s = P.Session(client; capabilities=CAPS_WITH_LOCAL_FILES)
            client_handshake!(s)
            P.query!(s, "LOAD DATA LOCAL INFILE 'f' INTO TABLE t")
            P.read_command_response!(s)
            @test_throws P.ProtocolError P.send_local_infile!(s, IOBuffer("12345678"); max_bytes=4, chunk_size=4)
            @test s.phase == P.BROKEN
        end
        # A local source failure after a data packet makes the wire position unusable.
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, vcat(UInt8[0xFB], codeunits("f")))
            read_chunk(conn)
            await_eof(conn)
        end) do client
            s = P.Session(client; capabilities=CAPS_WITH_LOCAL_FILES)
            client_handshake!(s)
            P.query!(s, "LOAD DATA LOCAL INFILE 'f' INTO TABLE t")
            P.read_command_response!(s)
            source = FailingUpload(IOBuffer("12345678"), 0)
            @test_throws ErrorException P.send_local_infile!(s, source; chunk_size=4)
            @test s.phase == P.BROKEN && !isopen(s)
        end
        # Invalid buffer sizes fail before allocation or protocol I/O.
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, vcat(UInt8[0xFB], codeunits("f"))); await_eof(conn))) do client
            s = P.Session(client; capabilities=CAPS_WITH_LOCAL_FILES, limits=P.Limits(; max_packet=1024))
            client_handshake!(s)
            P.query!(s, "LOAD DATA LOCAL INFILE 'f' INTO TABLE t")
            P.read_command_response!(s)
            @test_throws ArgumentError P.send_local_infile!(s, IOBuffer("x"); chunk_size=1025)
            @test s.phase == P.LOCAL_INFILE
        end
        # unsolicited 0xFB without CLIENT_LOCAL_FILES
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, vcat(UInt8[0xFB], codeunits("/etc/passwd"))); await_eof(conn))) do client
            s = P.Session(client)
            client_handshake!(s)
            @test !P.has_capability(s, P.CLIENT_LOCAL_FILES)
            P.query!(s, "SELECT 1")
            @test_throws P.ProtocolError P.read_command_response!(s)
            @test s.phase == P.BROKEN && !isopen(s)
        end
    end

    @testset "limits fault the session before allocation" begin
        # pre-auth packet larger than max_preauth_packet: only the header is sent
        with_peer(conn -> (send_raw(conn, UInt8[0x00, 0x00, 0x20, 0x00]); await_eof(conn))) do client
            s = P.Session(client)
            err = try; P.read_greeting!(s); nothing; catch e; e; end
            @test err isa P.ProtocolError && occursin("exceeds limit", err.msg)
            @test s.phase == P.BROKEN
        end
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, column_count(3)); await_eof(conn))) do client
            s = P.Session(client; limits=P.Limits(; max_columns=2))
            client_handshake!(s)
            P.query!(s, "SELECT 1, 2, 3")
            @test_throws P.ProtocolError P.read_command_response!(s)
            @test s.phase == P.BROKEN
        end
        # A hostile but user-permitted count must not allocate its full definition vector
        # before the first metadata packet is read and charged to max_metadata_bytes.
        declared_column_allocation(1)
        small = @allocated declared_column_allocation(1)
        large = @allocated declared_column_allocation(100_000)
        @test large <= small + 65_536
        declared_prepare_allocation(1)
        small = @allocated declared_prepare_allocation(1)
        large = @allocated declared_prepare_allocation(60_000)
        @test large <= small + 65_536
        with_peer(conn -> (server_handshake!(conn); await_eof(conn))) do client
            s = P.Session(client; limits=P.Limits(; max_packet=128))
            client_handshake!(s)
            @test_throws P.ProtocolError P.query!(s, "x"^128)
            @test s.phase == P.BROKEN && !isopen(s)
        end
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, vcat(UInt8[0xFE], fill(0xFF, 8))); await_eof(conn))) do client
            s = P.Session(client)
            client_handshake!(s)
            P.query!(s, "SELECT impossible_column_count")
            @test_throws P.ProtocolError P.read_command_response!(s)
            @test s.phase == P.BROKEN
        end
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, column_count(1)); send_packet(conn, 2, COL1); await_eof(conn))) do client
            s = P.Session(client; limits=P.Limits(; max_metadata_bytes=20))
            client_handshake!(s)
            P.query!(s, "SELECT col1")
            @test_throws P.ProtocolError P.read_command_response!(s)
            @test s.phase == P.BROKEN
        end
        # The remaining metadata budget bounds a declared packet before its body is read.
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, column_count(1))
            send_raw(conn, UInt8[0x20, 0x00, 0x00, 0x02])
            await_eof(conn)
        end) do client
            s = P.Session(client; limits=P.Limits(; max_metadata_bytes=16))
            client_handshake!(s)
            P.query!(s, "SELECT col1")
            @test_throws P.ProtocolError P.read_command_response!(s)
            @test s.phase == P.BROKEN && !isopen(s)
        end
        more = ok_payload(; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_MORE_RESULTS_EXISTS)
        with_peer(conn -> (server_handshake!(conn); read_command(conn); for i in 1:3; send_packet(conn, i, more); end; await_eof(conn))) do client
            s = P.Session(client; limits=P.Limits(; max_result_sets=2))
            client_handshake!(s)
            P.query!(s, "DO 1; DO 2; DO 3")
            @test P.read_command_response!(s) isa P.OKPacket
            @test P.next_result!(s) isa P.OKPacket
            @test_throws P.ProtocolError P.next_result!(s)
            @test s.phase == P.BROKEN
            @test s.io.seq == 0x03
        end
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, column_count(1))
            send_packet(conn, 2, COL1)
            for i in 3:6
                send_packet(conn, i, text_row("x"^20))
            end
            await_eof(conn)
        end) do client
            s = P.Session(client; limits=P.Limits(; max_response_bytes=60))
            client_handshake!(s)
            P.query!(s, "SELECT x")
            P.read_command_response!(s)
            @test P.read_row!(s) isa P.PacketView
            @test_throws P.ProtocolError P.read_row!(s)
            @test s.phase == P.BROKEN
        end
    end

    @testset "malformed packets fault the session" begin
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 5, ok_payload()); await_eof(conn))) do client
            s = P.Session(client)
            client_handshake!(s)
            P.ping!(s)
            err = try; P.read_command_response!(s; kind=P.CMD_SIMPLE); nothing; catch e; e; end
            @test err isa P.ProtocolError && occursin("sequence id mismatch", err.msg)
            @test s.phase == P.BROKEN
        end
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, column_count(1)); send_packet(conn, 2, COL1[1:10]); await_eof(conn))) do client
            s = P.Session(client)
            client_handshake!(s)
            P.query!(s, "SELECT col1")
            @test_throws P.ProtocolError P.read_command_response!(s)
            @test s.phase == P.BROKEN
        end
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, UInt8[0x01, 0x02]); await_eof(conn))) do client
            s = P.Session(client)
            client_handshake!(s)
            P.ping!(s)
            @test_throws P.ProtocolError P.read_command_response!(s; kind=P.CMD_SIMPLE)
            @test s.phase == P.BROKEN
        end
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, UInt8[]); await_eof(conn))) do client
            s = P.Session(client)
            client_handshake!(s)
            P.query!(s, "SELECT 1")
            @test_throws P.ProtocolError P.read_command_response!(s)
            @test s.phase == P.BROKEN
        end
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, column_count(1)); send_packet(conn, 2, COL1); send_packet(conn, 3, UInt8[0x05, 0x00]); await_eof(conn))) do client
            s = P.Session(client)
            client_handshake!(s)
            P.send_command!(s, P.COM_STMT_EXECUTE, zeros(UInt8, 9))
            P.read_command_response!(s; kind=P.CMD_STMT_EXECUTE)
            @test_throws P.ProtocolError P.read_row!(s; binary=true)   # 0x05 is not a binary row header
            @test s.phase == P.BROKEN
        end
        # missing metadata EOF when DEPRECATE_EOF is off
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_packet(conn, 1, column_count(1)); send_packet(conn, 2, COL1); send_packet(conn, 3, text_row("1")); await_eof(conn))) do client
            s = P.Session(client; capabilities=CAPS_NO_DEPRECATE_EOF)
            client_handshake!(s)
            P.query!(s, "SELECT col1")
            @test_throws P.ProtocolError P.read_command_response!(s)
            @test s.phase == P.BROKEN
        end
        # peer closes mid-packet
        with_peer(conn -> (server_handshake!(conn); read_command(conn); send_raw(conn, UInt8[0x10, 0x00, 0x00, 0x01, 0x00]))) do client
            s = P.Session(client)
            client_handshake!(s)
            P.ping!(s)
            err = try; P.read_command_response!(s; kind=P.CMD_SIMPLE); nothing; catch e; e; end
            @test err isa P.ProtocolError && occursin("closed", err.msg)
            @test s.phase == P.BROKEN
        end
    end

    @testset "FaultTransport interruption points" begin
        for (fail_at, label) in ((0, "before the first byte"), (2, "inside the header"), (4, "after the header"), (10, "mid-payload"))
            with_peer(conn -> (send_packet(conn, 0, greeting()); try; read_packet(conn); catch; end)) do client
                ft = P.FaultTransport(client; fail_write_at=fail_at, write_error=InterruptException())
                s = P.Session(ft)
                P.read_greeting!(s)
                @test_throws InterruptException P.send_handshake_response!(s, "root", zeros(UInt8, 32), "caching_sha2_password")
                @test s.phase == P.BROKEN && !isopen(s)
                @test ft.write_bytes == fail_at
            end
        end
        # fully written, then interrupted before the state advanced: still Broken
        with_peer(conn -> (send_packet(conn, 0, greeting()); read_packet(conn); try; send_packet(conn, 2, ok_payload()); catch; end)) do client
            ft = P.FaultTransport(client; after_write_error=InterruptException())
            s = P.Session(ft)
            P.read_greeting!(s)
            @test_throws InterruptException P.send_handshake_response!(s, "root", zeros(UInt8, 32), "caching_sha2_password")
            @test s.phase == P.BROKEN
        end
        for (fail_at, label) in ((2, "inside the header"), (4, "after the header"), (20, "mid-payload"))
            with_peer(conn -> (send_packet(conn, 0, greeting()); await_eof(conn))) do client
                ft = P.FaultTransport(client; fail_read_at=fail_at, read_error=EOFError())
                s = P.Session(ft)
                @test_throws P.ProtocolError P.read_greeting!(s)
                @test s.phase == P.BROKEN && !isopen(s)
            end
        end
        # interruption during a read in the command phase
        with_peer(conn -> begin
            send_packet(conn, 0, greeting())
            read_packet(conn)
            send_packet(conn, 2, ok_payload())
            read_command(conn)
            send_packet(conn, 1, ok_payload())
            await_eof(conn)
        end) do client
            ft = P.FaultTransport(client; read_error=InterruptException())
            s = P.Session(ft)
            client_handshake!(s)
            ft.fail_read_at = ft.read_bytes + 2
            P.ping!(s)
            @test_throws InterruptException P.read_command_response!(s; kind=P.CMD_SIMPLE)
            @test s.phase == P.BROKEN
        end
    end

    @testset "read deadline → TimeoutError" begin
        with_peer(conn -> await_eof(conn)) do client
            s = P.Session(client)
            P.set_read_deadline!(client, time_ns() + 100_000_000)
            err = try; P.read_greeting!(s); nothing; catch e; e; end
            @test err isa P.TimeoutError
            @test s.phase == P.BROKEN && !isopen(s)
        end
        # the same through a FaultTransport wrapper
        with_peer(conn -> await_eof(conn)) do client
            ft = P.FaultTransport(client)
            s = P.Session(ft)
            P.set_read_deadline!(ft, time_ns() + 100_000_000)
            @test_throws P.TimeoutError P.read_greeting!(s)
        end
        # A deadline in an active result stream makes the connection unusable.
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)
            send_packet(conn, 1, column_count(1))
            send_packet(conn, 2, COL1)
            await_eof(conn)
        end) do client
            s = P.Session(client)
            client_handshake!(s)
            P.query!(s, "SELECT 1")
            @test P.read_command_response!(s) isa P.ResultHeader
            P.set_read_deadline!(client, time_ns() + 100_000_000)
            err = try
                P.read_row!(s)
                nothing
            catch caught
                caught
            end
            @test err isa P.TimeoutError
            @test occursin("phase ROWS", err.msg)
            @test s.phase == P.BROKEN && !isopen(s)
        end
    end

    @testset "quit!, no-response commands, drain!, sequence wrap" begin
        commands = Tuple{UInt8, UInt8, Vector{UInt8}}[]
        with_peer(conn -> begin
            server_handshake!(conn)
            push!(commands, read_command(conn))     # COM_STMT_CLOSE, never answered
            push!(commands, read_command(conn))     # COM_PING
            send_packet(conn, 1, ok_payload())
            push!(commands, read_command(conn))     # COM_QUERY with 300 rows
            send_packet(conn, 1, column_count(1))
            send_packet(conn, 2, COL1)
            seq = 3
            for i in 1:300
                send_packet(conn, seq & 0xFF, text_row(string(i)))
                seq += 1
            end
            send_packet(conn, seq & 0xFF, ok_payload(; header=0xFE, status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_MORE_RESULTS_EXISTS, track=true))
            send_packet(conn, (seq + 1) & 0xFF, ok_payload(; track=true))
            push!(commands, read_command(conn))     # COM_QUIT
            await_eof(conn)
        end) do client
            s = P.Session(client)
            client_handshake!(s)
            P.stmt_close!(s, 5)
            @test s.phase == P.READY
            P.ping!(s)
            @test P.read_command_response!(s; kind=P.CMD_SIMPLE) isa P.OKPacket
            P.query!(s, "SELECT n FROM three_hundred")
            P.read_command_response!(s)
            rows = 0
            offsets, lengths = Int[], Int[]
            while rows < 10
                row = P.read_row!(s)
                P.scan_text_row!(row, 1, offsets, lengths)
                @test String(row.buf[offsets[1]:(offsets[1] + lengths[1] - 1)]) == string(rows + 1)
                rows += 1
            end
            P.drain!(s)   # the remaining 290 rows (sequence ids wrap past 255) and the trailing OK
            @test s.phase == P.READY && s.result_sets == 2
            P.quit!(s)
            @test s.phase == P.CLOSED && !isopen(s)
        end
        @test commands[1][2] == P.COM_STMT_CLOSE && commands[1][3] == UInt8[5, 0, 0, 0]
        @test commands[2][2] == P.COM_PING
        @test commands[4][2] == P.COM_QUIT && commands[4][1] == 0
    end

    @testset "drain! reads and closes an un-read COM_STMT_PREPARE answer" begin
        # If a caller is interrupted between stmt_prepare! and read_prepare_response!, the
        # session is in CMD_SENT with command_kind == CMD_STMT_PREPARE; the next drain must
        # read the PREPARE_OK, close its server-side id, and keep the connection usable.
        with_peer(conn -> begin
            server_handshake!(conn)
            read_command(conn)                       # COM_STMT_PREPARE, deliberately unread by the client
            hdr = UInt8[0x00]; P.write_u32!(hdr, 7); P.write_u16!(hdr, 0); P.write_u16!(hdr, 0); P.write_u8!(hdr, 0); P.write_u16!(hdr, 0)
            send_packet(conn, 1, hdr)                 # PREPARE_OK: 0 columns, 0 params
            seq, command, data = read_command(conn)   # COM_STMT_CLOSE has no response
            @test seq == 0 && command == P.COM_STMT_CLOSE && data == UInt8[7, 0, 0, 0]
            seq, command, data = read_command(conn)   # COM_PING
            @test seq == 0 && command == P.COM_PING && isempty(data)
            send_packet(conn, 1, ok_payload())
            await_eof(conn)
        end) do client
            s = P.Session(client)
            client_handshake!(s)
            P.stmt_prepare!(s, "SELECT 1")
            @test s.phase == P.CMD_SENT && s.command_kind == P.CMD_STMT_PREPARE
            P.drain!(s)                               # must consume PREPARE_OK and close its id
            @test s.phase == P.READY && isopen(s)
            P.ping!(s)
            @test P.read_command_response!(s; kind=P.CMD_SIMPLE) isa P.OKPacket
        end
    end

    @testset "client-side packet splitting at 0xFFFFFF" begin
        received = Int[]
        with_peer(conn -> begin
            server_handshake!(conn)
            for _ in 1:2
                seq, payload = read_packet(conn)
                push!(received, length(payload))
            end
        end) do client
            s = P.Session(client; limits=P.Limits(; max_packet=32 * 1024 * 1024))
            client_handshake!(s)
            P.sendpacket!(s, zeros(UInt8, P.MAX_CHUNK))        # exact multiple: data chunk + empty chunk
            P.sendpacket!(s, zeros(UInt8, P.MAX_CHUNK + 7))    # two chunks
        end
        @test received == [P.MAX_CHUNK, P.MAX_CHUNK + 7]
    end

    @testset "COM_SET_OPTION, COM_INIT_DB, COM_RESET_CONNECTION encode the right bytes" begin
        commands = Tuple{UInt8, UInt8, Vector{UInt8}}[]
        with_peer(conn -> begin
            server_handshake!(conn)
            for _ in 1:3
                push!(commands, read_command(conn))
                send_packet(conn, 1, ok_payload())
            end
        end) do client
            s = P.Session(client)
            client_handshake!(s)
            P.set_option!(s, P.MYSQL_OPTION_MULTI_STATEMENTS_OFF)
            P.read_command_response!(s; kind=P.CMD_SIMPLE)
            P.init_db!(s, "other")
            P.read_command_response!(s; kind=P.CMD_SIMPLE)
            P.reset_connection!(s)
            P.read_command_response!(s; kind=P.CMD_SIMPLE)
        end
        @test commands[1][2] == 0x1B && commands[1][3] == UInt8[0x01, 0x00]
        @test commands[2][2] == 0x02 && String(commands[2][3]) == "other"
        @test commands[3][2] == 0x1F && isempty(commands[3][3])
    end
end
