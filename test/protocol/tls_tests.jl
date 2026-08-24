# STARTTLS and the ssl_mode matrix against a TLS-capable fake peer, plus the
# connection-establishment deadline and the Native.connect orchestration.
const TLS = Reseau.TLS
const N = MySQL

server_config(; cert="server.crt", key="server.key", kw...) = TLS.Config(; cert_file=certfile(cert), key_file=certfile(key), kw...)

# Server side: greeting, SSLRequest, TLS handshake, HandshakeResponse over TLS, auth OK with
# session tracking reporting utf8mb4 (so no SET NAMES round trip unless `track=false`).
function tls_peer_connect!(conn; cfg=server_config(), caps=MYSQL8_SERVER_CAPS, track_utf8mb4::Bool=true, after=nothing, stall_handshake::Bool=false, stall_auth::Bool=false)
    send_packet(conn, 0, greeting(; caps=caps))
    seq, sslreq = read_packet(conn)
    length(sslreq) == 32 || error("expected SSLRequest, got $(length(sslreq)) bytes")
    stall_handshake && return stall_until_eof(conn)
    tls = TLS.server(conn, cfg)
    TLS.handshake!(tls)
    seq2, response = read_packet(tls)
    stall_auth && return stall_until_eof(tls)
    ok = track_utf8mb4 ? ok_payload(; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_SESSION_STATE_CHANGED, state=utf8mb4_state(), track=true) : ok_payload()
    send_packet(tls, seq2 + 1, ok)
    after === nothing || after(tls)
    close(tls)
    return nothing
end

function utf8mb4_state()
    buf = UInt8[]
    for name in ("character_set_client", "character_set_connection", "character_set_results")
        append!(buf, state_block(P.SESSION_TRACK_SYSTEM_VARIABLES, name, "utf8mb4"))
    end
    return buf
end

# Plaintext peer that answers a non-tracking OK and then serves the SET NAMES bootstrap.
function plain_peer_connect!(conn; caps=MYSQL8_SERVER_CAPS, expect_ssl_request::Bool=false, bootstrap_status=P.SERVER_STATUS_AUTOCOMMIT, after=nothing)
    send_packet(conn, 0, greeting(; caps=caps))
    seq, response = read_packet(conn)
    (length(response) == 32) == expect_ssl_request || error(expect_ssl_request ? "expected an SSLRequest" : "client sent an SSLRequest in plaintext mode")
    send_packet(conn, seq + 1, ok_payload())
    seq, cmd, sql = read_command(conn)
    (cmd == P.COM_QUERY && String(sql) == "SET NAMES utf8mb4") || error("expected SET NAMES utf8mb4, got $(cmd) $(String(sql))")
    send_packet(conn, 1, ok_payload(; status=bootstrap_status))
    after === nothing || after(conn)
    return nothing
end

# A stalled peer: consumes whatever the client sends without answering, until the client
# closes. (Returning with unread bytes in the socket would turn the close into an RST.)
function stall_until_eof(conn)
    try
        while true
            read_exact(conn, 1)
        end
    catch
    end
    return nothing
end

# Runs `handler` as a server and `f(port)` as the client (the client dials itself).
function with_server(f::Function, handler::Function)
    peer = FakePeer.serve(handler)
    result = nothing
    try
        result = f(peer.port)
    finally
        close(peer)
    end
    peer.error[] === nothing || throw(peer.error[])
    return result
end

# Every test dial carries a deadline so a misbehaving peer fails the test instead of hanging it.
function native_connect(port; host="127.0.0.1", connect_timeout=10, kw...)
    return N.connect(host, "root", "pw"; port=port, get_server_public_key=true, connect_timeout=connect_timeout, kw...)
end

function abandon_tls_handle(port)
    h = native_connect(port; ssl_mode=:required)
    return WeakRef(h), WeakRef(h.session.transport), h.entry
end

@testset "STARTTLS and ssl_mode matrix" begin
    @testset "preferred: TLS when offered, plaintext when not" begin
        with_server(conn -> tls_peer_connect!(conn)) do port
            h = native_connect(port)
            @test P.is_secure_transport(h.session) && isopen(h)
            @test h.session.phase == P.READY && !h.bootstrapped
            @test h.auth_trace[end] == :ok
            N.close!(h)
            @test !isopen(h)
        end
        with_server(conn -> plain_peer_connect!(conn; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL)) do port
            h = native_connect(port)
            @test !P.is_secure_transport(h.session) && h.bootstrapped
            N.close!(h)
        end
    end

    @testset "disabled never sends SSLRequest; required refuses a TLS-less server" begin
        with_server(conn -> plain_peer_connect!(conn)) do port
            h = native_connect(port; ssl_mode=:disabled)
            @test !P.is_secure_transport(h.session)
            N.close!(h)
        end
        for mode in (:required, :verify_ca, :verify_identity)
            with_server(conn -> (send_packet(conn, 0, greeting(; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL)); await_eof(conn))) do port
                err = try; native_connect(port; ssl_mode=mode, ssl_ca=certfile("ca.crt")); nothing; catch e; e; end
                @test err isa P.TLSNegotiationError
            end
        end
    end

    @testset "verify_ca and verify_identity" begin
        with_server(conn -> tls_peer_connect!(conn)) do port
            h = native_connect(port; ssl_mode=:verify_ca, ssl_ca=certfile("ca.crt"))
            @test P.is_secure_transport(h.session)
            N.close!(h)
        end
        # self-signed server certificate: chain verification fails, no plaintext fallback
        # explicit :verify_ca, and ssl_ca alone (which escalates the default to :verify_ca); a failed handshake never falls back
        for kw in ((; ssl_mode=:verify_ca, ssl_ca=certfile("ca.crt")), (; ssl_ca=certfile("ca.crt")))
            with_server(conn -> (try; tls_peer_connect!(conn; cfg=server_config(; cert="selfsigned.crt", key="selfsigned.key")); catch; end)) do port
                err = try; native_connect(port; kw...); nothing; catch e; e; end
                @test err isa P.TLSNegotiationError
            end
        end
        # an explicit :preferred keeps its meaning even with ssl_ca (libmysqlclient semantics): encrypted, unverified
        with_server(conn -> tls_peer_connect!(conn; cfg=server_config(; cert="selfsigned.crt", key="selfsigned.key"))) do port
            h = native_connect(port; ssl_mode=:preferred, ssl_ca=certfile("ca.crt"))
            @test P.is_secure_transport(h.session)
            N.close!(h)
        end
        # ssl_verify_server_cert=true ⇒ :verify_identity
        with_server(conn -> tls_peer_connect!(conn)) do port
            h = native_connect(port; host="localhost", protocol=:tcp, ssl_verify_server_cert=true, ssl_ca=certfile("ca.crt"))
            @test P.is_secure_transport(h.session)
            N.close!(h)
        end
        # IP SAN present → identity verification passes when dialing the IP
        with_server(conn -> tls_peer_connect!(conn)) do port
            h = native_connect(port; ssl_mode=:verify_identity, ssl_ca=certfile("ca.crt"))
            @test P.is_secure_transport(h.session)
            N.close!(h)
        end
        # DNS-only certificate: dialing the IP fails identity verification ...
        with_server(conn -> (try; tls_peer_connect!(conn; cfg=server_config(; cert="server-dnsonly.crt", key="server-dnsonly.key")); catch; end)) do port
            err = try; native_connect(port; ssl_mode=:verify_identity, ssl_ca=certfile("ca.crt")); nothing; catch e; e; end
            @test err isa P.TLSNegotiationError
        end
        # ... unless the verification name is overridden (SNI-routed deployments)
        with_server(conn -> tls_peer_connect!(conn; cfg=server_config(; cert="server-dnsonly.crt", key="server-dnsonly.key"))) do port
            h = native_connect(port; ssl_mode=:verify_identity, ssl_ca=certfile("ca.crt"), ssl_server_name="localhost")
            @test P.is_secure_transport(h.session)
            N.close!(h)
        end
        # verify_ca does not bind the name: a DNS-only cert still passes when dialing the IP
        with_server(conn -> tls_peer_connect!(conn; cfg=server_config(; cert="server-dnsonly.crt", key="server-dnsonly.key"))) do port
            h = native_connect(port; ssl_mode=:verify_ca, ssl_ca=certfile("ca.crt"))
            @test P.is_secure_transport(h.session)
            N.close!(h)
        end
    end

    @testset "mutual TLS on 1.2, 1.3, and the auto path" begin
        # Pinned clients exercise Reseau's exact-version drivers; the unpinned "auto" client
        # exercises the mixed-version driver (Reseau ≥ 1.4.0 loads the client identity there).
        for (label, client_kw, server_kw) in (
            ("TLS 1.2", (; tls_version="TLSv1.2"), (; min_version=TLS.TLS1_2_VERSION, max_version=TLS.TLS1_2_VERSION)),
            ("TLS 1.3", (; tls_version="TLSv1.3"), (; min_version=TLS.TLS1_3_VERSION, max_version=TLS.TLS1_3_VERSION)),
            ("auto", (;), (;)))
            cfg = server_config(; client_auth=TLS.ClientAuthMode.RequireAndVerifyClientCert, client_ca_file=certfile("ca.crt"), server_kw...)
            with_server(conn -> (try; tls_peer_connect!(conn; cfg=cfg); catch; end)) do port
                result = try; native_connect(port; ssl_mode=:verify_ca, ssl_ca=certfile("ca.crt"), ssl_cert=certfile("client.crt"), ssl_key=certfile("client.key"), client_kw...); catch e; e; end
                if result isa N.Handle
                    @test P.is_secure_transport(result.session)
                    @test TLS.connection_state(result.session.transport).handshake_complete
                    @test TLS.connection_state(result.session.transport).version == (label == "TLS 1.2" ? "TLSv1.2" : "TLSv1.3")
                    N.close!(result)
                else
                    @error "mTLS $label failed" result cause=(result isa P.TLSNegotiationError ? result.cause : nothing)
                    @test result isa N.Handle
                end
            end
            # without a client certificate the server refuses the handshake
            with_server(conn -> (try; tls_peer_connect!(conn; cfg=cfg); catch; end)) do port
                err = try; native_connect(port; ssl_mode=:verify_ca, ssl_ca=certfile("ca.crt"), client_kw...); nothing; catch e; e; end
                @test err isa P.TLSNegotiationError
            end
        end
        @test_throws ArgumentError N.ConnectOptions("h", "u"; ssl_cert=certfile("client.crt"))
    end

    @testset "an abandoned TLS handle is reclaimed by the reaper" begin
        with_server(conn -> tls_peer_connect!(conn; after=stall_until_eof)) do port
            handle_ref, transport_ref, entry = abandon_tls_handle(port)
            for _ in 1:20
                GC.gc()
                N.reap_now!()
                (@atomic entry.state) == :closed && break
                yield()
            end
            @test handle_ref.value === nothing
            @test (@atomic entry.state) == :closed
            @test entry.transport === nothing
            GC.gc()
            GC.gc()
            @test transport_ref.value === nothing
        end
    end

    @testset "a peer that coalesces bytes after the greeting is rejected before TLS" begin
        with_server(conn -> (send_raw(conn, vcat(FakePeer.hexbytes(""), let g = greeting(); vcat(UInt8[length(g) & 0xFF, (length(g) >> 8) & 0xFF, 0x00, 0x00], g) end, codeunits("GARBAGE"))); try; read_packet(conn); catch; end; await_eof(conn))) do port
            err = try; native_connect(port; ssl_mode=:required); nothing; catch e; e; end
            @test err isa P.ProtocolError && occursin("before STARTTLS", err.msg)
        end
    end

    @testset "connection-establishment deadline covers every stage" begin
        # dial succeeds, greeting never comes
        with_server(conn -> await_eof(conn)) do port
            t0 = time()
            err = try; native_connect(port; connect_timeout=1); nothing; catch e; e; end
            elapsed = time() - t0
            (err isa P.TimeoutError && elapsed < 5) || @error "greeting stall deadline case" err elapsed
            @test err isa P.TimeoutError && elapsed < 5
        end
        # stall during the TLS handshake (SSLRequest read, then silence)
        with_server(conn -> tls_peer_connect!(conn; stall_handshake=true)) do port
            t0 = time()
            err = try; native_connect(port; connect_timeout=1, ssl_mode=:required); nothing; catch e; e; end
            elapsed = time() - t0
            (err isa P.TimeoutError && elapsed < 5) || @error "handshake stall deadline case" err elapsed cause=(err isa P.TLSNegotiationError ? err.cause : nothing) cause2=(err isa P.TLSNegotiationError && err.cause isa Reseau.TLS.TLSError ? err.cause.cause : nothing)
            @test err isa P.TimeoutError && elapsed < 5
        end
        # stall after the handshake response (auth never answered)
        with_server(conn -> tls_peer_connect!(conn; stall_auth=true)) do port
            t0 = time()
            err = try; native_connect(port; connect_timeout=1, ssl_mode=:required); nothing; catch e; e; end
            elapsed = time() - t0
            (err isa P.TimeoutError && elapsed < 5) || @error "stall_auth deadline case" err elapsed
            @test err isa P.TimeoutError && elapsed < 5
        end
        # after READY the establishment deadline is cleared: a later slow command is fine
        with_server(conn -> tls_peer_connect!(conn; after=tls -> begin
            read_command(tls)
            sleep(1.5)
            send_packet(tls, 1, ok_payload())
        end)) do port
            h = native_connect(port; connect_timeout=1)
            P.ping!(h.session)
            @test P.read_command_response!(h.session; kind=P.CMD_SIMPLE) isa P.OKPacket
            N.close!(h)
        end
        @test_throws ArgumentError N.ConnectOptions("h", "u"; connect_timeout=0)
    end

    @testset "SSLRequest and HandshakeResponse carry identical capability flags" begin
        words = Vector{UInt8}[]
        with_server(conn -> begin
            send_packet(conn, 0, greeting())
            seq, sslreq = read_packet(conn)
            push!(words, sslreq[1:4])
            tls = TLS.server(conn, server_config())
            TLS.handshake!(tls)
            seq2, response = read_packet(tls)
            push!(words, response[1:4])
            c = P.PacketCursor(response)
            P.skip!(c, 32)
            P.read_nul_string!(c)
            P.read_lenenc_bytes!(c)
            push!(words, Vector{UInt8}(codeunits(P.read_nul_string!(c))))   # the database
            send_packet(tls, seq2 + 1, ok_payload())
            read_command(tls)                                               # SET NAMES
            send_packet(tls, 1, ok_payload())
            stall_until_eof(tls)
        end) do port
            h = N.connect("127.0.0.1", "root", "pw"; port=port, db="manifest", ssl_mode=:required, connect_timeout=10)
            N.close!(h)
        end
        @test words[1] == words[2]
        caps = UInt32(words[2][1]) | UInt32(words[2][2]) << 8 | UInt32(words[2][3]) << 16 | UInt32(words[2][4]) << 24
        @test caps & P.CLIENT_CONNECT_WITH_DB != 0 && String(words[3]) == "manifest"
    end

    @testset "init_command runs after the bootstrap, under read_timeout" begin
        seen = String[]
        with_server(conn -> plain_peer_connect!(conn; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, after=c -> begin
            seq, cmd, sql = read_command(c)
            push!(seen, String(sql))
            send_packet(c, 1, ok_payload())
            read_command(c)   # COM_QUIT
        end)) do port
            h = native_connect(port; init_command="SET time_zone = '+00:00'", read_timeout=5)
            @test h.bootstrapped
            N.close!(h)
        end
        @test seen == ["SET time_zone = '+00:00'"]

        uploaded = Vector{UInt8}[]
        requested = String[]
        with_server(conn -> plain_peer_connect!(conn; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, after=c -> begin
            read_command(c)
            send_packet(c, 1, ok_payload(; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_MORE_RESULTS_EXISTS))
            send_packet(c, 2, vcat(UInt8[0xFB], codeunits("init.csv")))
            upload_seq = UInt8(0)
            while true
                upload_seq, data = read_packet(c)
                isempty(data) && break
                push!(uploaded, data)
            end
            send_packet(c, upload_seq + 1, ok_payload())
            read_command(c)
        end)) do port
            handler = name -> (push!(requested, name); IOBuffer("init payload"))
            h = native_connect(port; init_command="SET @x=1; LOAD DATA LOCAL INFILE 'init.csv'", multi_statements=true, local_files=true, local_infile_handler=handler)
            N.close!(h)
        end
        @test requested == ["init.csv"]
        @test uploaded == [Vector{UInt8}(codeunits("init payload"))]

        with_server(conn -> plain_peer_connect!(conn; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, after=c -> begin
            read_command(c)
            send_packet(c, 1, ok_payload(; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_MORE_RESULTS_EXISTS))
            send_packet(c, 2, vcat(UInt8[0xFF, 0x28, 0x04], codeunits("#42000late init error")))
            await_eof(c)
        end)) do port
            err = try
                native_connect(port; init_command="SELECT 1; INVALID", multi_statements=true)
                nothing
            catch ex
                ex
            end
            @test err isa P.Error
            @test err isa P.Error && err.errno == 1064 && err.msg == "late init error"
        end

        with_server(conn -> plain_peer_connect!(conn; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, after=c -> begin
            read_command(c)
            await_eof(c)
        end)) do port
            t0 = time()
            err = try
                native_connect(port; init_command="DO SLEEP(10)", read_timeout=1)
                nothing
            catch ex
                ex
            end
            elapsed = time() - t0
            @test err isa P.TimeoutError
            @test elapsed < 5
        end
    end

    @testset "charset bootstrap requires one final OK" begin
        status = P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_MORE_RESULTS_EXISTS
        with_server(conn -> plain_peer_connect!(conn; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, bootstrap_status=status)) do port
            err = try
                native_connect(port; ssl_mode=:disabled)
                nothing
            catch ex
                ex
            end
            @test err isa P.ProtocolError
            @test err isa P.ProtocolError && occursin("one final OK", err.msg)
        end

        malformed_state = state_block(P.SESSION_TRACK_SYSTEM_VARIABLES, "name-without-value")
        with_peer(conn -> begin
            send_packet(conn, 0, greeting(; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL))
            seq, _ = read_packet(conn)
            status = P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_SESSION_STATE_CHANGED
            send_packet(conn, seq + 1, ok_payload(; status=status, state=malformed_state, track=true))
            await_eof(conn)
        end) do client
            s = P.Session(client)
            P.read_greeting!(s)
            @test_throws P.ProtocolError P.authenticate!(s, "root", "pw", P.AuthPolicy())
            @test s.phase == P.BROKEN && !isopen(s)
        end
    end
end
