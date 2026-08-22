# Server-side verification of the scrambles (the documented check the server performs).
function native_verify(stage2_hash::Vector{UInt8}, nonce::Vector{UInt8}, response::Vector{UInt8})
    mixed = SHA.sha1(vcat(nonce, stage2_hash))
    stage1 = [response[i] ⊻ mixed[i] for i in 1:20]
    return SHA.sha1(stage1) == stage2_hash
end

function caching_sha2_verify(stage2_hash::Vector{UInt8}, nonce::Vector{UInt8}, response::Vector{UInt8})
    mixed = SHA.sha256(vcat(stage2_hash, nonce))
    stage1 = [response[i] ⊻ mixed[i] for i in 1:32]
    return SHA.sha256(stage1) == stage2_hash
end

const PW = Vector{UInt8}(codeunits("pässwörd"))
const NONCE = Vector{UInt8}(codeunits("0123456789abcdefghij"))
const POLICY_PLAIN = P.AuthPolicy()
const POLICY_TLS = P.AuthPolicy(; secure_transport=true)
const POLICY_TLS_VERIFIED = P.AuthPolicy(; secure_transport=true, identity_verified=true)

@testset "auth plugins" begin
    @testset "scrambles verify with the server-side formula" begin
        r = P.native_scramble(PW, NONCE)
        @test length(r) == 20
        @test native_verify(SHA.sha1(SHA.sha1(PW)), NONCE, r)
        @test !native_verify(SHA.sha1(SHA.sha1(Vector{UInt8}(codeunits("other")))), NONCE, r)
        @test P.native_scramble(UInt8[], NONCE) == UInt8[]
        @test_throws P.AuthError P.native_scramble(PW, NONCE[1:8])
        r = P.caching_sha2_scramble(PW, NONCE)
        @test length(r) == 32
        @test caching_sha2_verify(SHA.sha256(SHA.sha256(PW)), NONCE, r)
        @test !caching_sha2_verify(SHA.sha256(SHA.sha256(PW)), reverse(NONCE), r)
        @test P.caching_sha2_scramble(UInt8[], NONCE) == UInt8[]
        @test P.nonce_masked_password(UInt8[0x41], UInt8[0x01, 0x02]) == UInt8[0x40, 0x02]
        @test P.cleartext_password(PW) == vcat(PW, 0x00)
        @test P.strip_nonce(vcat(NONCE, 0x00)) == NONCE && P.strip_nonce(NONCE) == NONCE
    end

    @testset "plugin registry and selection" begin
        @test P.plugin_for("mysql_native_password") isa P.NativePassword
        @test P.plugin_for("caching_sha2_password") isa P.CachingSha2Password
        @test_throws P.UnsupportedAuthError P.plugin_for("client_ed25519")
        @test_throws P.UnsupportedAuthError P.plugin_for("authentication_webauthn_client")
        info = P.parse_handshake_v10(pview(greeting(; plugin="mysql_native_password")))
        @test P.select_plugin(info, nothing) isa P.NativePassword
        @test P.select_plugin(info, "caching_sha2_password") isa P.CachingSha2Password
        info = P.parse_handshake_v10(pview(greeting(; plugin="client_ed25519")))
        @test P.select_plugin(info, nothing) isa P.CachingSha2Password    # unsupported default: announce ours, expect a switch
        @test_throws P.UnsupportedAuthError P.select_plugin(info, "parsec")
    end

    @testset "initial responses and policy gates" begin
        @test P.initial_response(P.NativePassword(), PW, NONCE, POLICY_PLAIN) == P.native_scramble(PW, NONCE)
        @test P.initial_response(P.CachingSha2Password(), PW, NONCE, POLICY_PLAIN) == P.caching_sha2_scramble(PW, NONCE)
        # sha256_password: cleartext on TLS, RSA with a key, key request when allowed, refusal otherwise
        @test P.initial_response(P.Sha256Password(), PW, NONCE, POLICY_TLS) == vcat(PW, 0x00)
        @test P.initial_response(P.Sha256Password(), UInt8[], NONCE, POLICY_PLAIN) == UInt8[]
        ct = P.initial_response(P.Sha256Password(), PW, NONCE, P.AuthPolicy(; server_public_key=pem("rsa2048.pub")))
        @test length(ct) == 256
        @test P.initial_response(P.Sha256Password(), PW, NONCE, P.AuthPolicy(; get_server_public_key=true)) == [P.SHA256_REQUEST_PUBLIC_KEY]
        err = try; P.initial_response(P.Sha256Password(), PW, NONCE, POLICY_PLAIN); nothing; catch e; e; end
        @test err isa P.AuthError && occursin("get_server_public_key", err.msg)
        # cleartext: enablement and identity verification
        @test_throws P.AuthError P.initial_response(P.ClearPassword(), PW, NONCE, POLICY_TLS_VERIFIED)   # not enabled
        @test_throws P.AuthError P.initial_response(P.ClearPassword(), PW, NONCE, P.AuthPolicy(; enable_cleartext_plugin=true, secure_transport=true))  # TLS but not verified
        @test P.initial_response(P.ClearPassword(), PW, NONCE, P.AuthPolicy(; enable_cleartext_plugin=true, secure_transport=true, identity_verified=true)) == vcat(PW, 0x00)
        @test P.initial_response(P.ClearPassword(), PW, NONCE, P.AuthPolicy(; enable_cleartext_plugin=true, insecure_cleartext_auth=true)) == vcat(PW, 0x00)
    end

    @testset "caching_sha2 continuation state machine" begin
        st = P.AuthState(P.CachingSha2Password(), NONCE)
        @test P.step!(st, UInt8[0x03], PW, POLICY_PLAIN) === nothing
        @test P.step!(P.AuthState(P.CachingSha2Password(), NONCE), UInt8[0x04], PW, POLICY_TLS) == vcat(PW, 0x00)
        ct = P.step!(P.AuthState(P.CachingSha2Password(), NONCE), UInt8[0x04], PW, P.AuthPolicy(; server_public_key=pem("rsa2048.pub")))
        @test length(ct) == 256
        st = P.AuthState(P.CachingSha2Password(), NONCE)
        @test P.step!(st, UInt8[0x04], PW, P.AuthPolicy(; get_server_public_key=true)) == [P.CACHING_SHA2_REQUEST_PUBLIC_KEY]
        @test st.awaiting_public_key
        ct = P.step!(st, pem("rsa2048.pub"), PW, P.AuthPolicy(; get_server_public_key=true))
        @test length(ct) == 256 && !st.awaiting_public_key
        @test rsa_oaep_decrypt(pem("rsa2048.key"), ct) == P.nonce_masked_password(PW, NONCE)
        st = P.AuthState(P.CachingSha2Password(), NONCE)
        P.step!(st, UInt8[0x04], PW, P.AuthPolicy(; get_server_public_key=true))
        @test_throws P.ProtocolError P.step!(st, UInt8[0x41], PW, P.AuthPolicy(; get_server_public_key=true))   # not a PEM
        @test_throws P.AuthError P.step!(P.AuthState(P.CachingSha2Password(), NONCE), UInt8[0x04], PW, POLICY_PLAIN)
        @test_throws P.ProtocolError P.step!(P.AuthState(P.CachingSha2Password(), NONCE), UInt8[0x07], PW, POLICY_PLAIN)
        @test_throws P.ProtocolError P.step!(P.AuthState(P.CachingSha2Password(), NONCE), UInt8[], PW, POLICY_PLAIN)
        @test_throws P.ProtocolError P.step!(P.AuthState(P.NativePassword(), NONCE), UInt8[0x04], PW, POLICY_PLAIN)
        @test_throws P.ProtocolError P.step!(P.AuthState(P.Sha256Password(), NONCE), UInt8[0x04], PW, POLICY_PLAIN)
        @test length(P.step!(P.AuthState(P.Sha256Password(), NONCE), pem("rsa3072.pub"), PW, POLICY_PLAIN)) == 384
    end
end

# ---- full exchanges against the fake peer ----

# Server-side handler pieces. `account` is (plugin_name, password); the peer verifies the
# client's scramble with the server formula and drives fast/full/RSA flows.
function peer_auth_caching_sha2!(conn, password::String; announce="caching_sha2_password", mode::Symbol=:fast, rsa_key=("rsa2048.pub", "rsa2048.key"), seen=nothing)
    nonce = collect(UInt8, 101:120)
    send_packet(conn, 0, greeting(; plugin=announce, scramble=nonce))
    seq, response = read_packet(conn)
    seen === nothing || push!(seen, response)
    pw = Vector{UInt8}(codeunits(password))
    stage2 = SHA.sha256(SHA.sha256(pw))
    c = P.PacketCursor(response)
    P.skip!(c, 32)
    P.read_nul_string!(c)
    scramble = P.read_lenenc_bytes!(c)
    if isempty(pw)
        isempty(scramble) || error("expected empty scramble for empty password")
        send_packet(conn, seq + 1, ok_payload())
        return
    end
    caching_sha2_verify(stage2, nonce, scramble) || error("client scramble does not verify")
    if mode == :fast
        send_packet(conn, seq + 1, UInt8[0x01, P.CACHING_SHA2_FAST_AUTH_SUCCESS])
        send_packet(conn, seq + 2, ok_payload())
        return
    end
    send_packet(conn, seq + 1, UInt8[0x01, P.CACHING_SHA2_PERFORM_FULL_AUTH])
    seq, reply = read_packet(conn)
    seen === nothing || push!(seen, reply)
    if mode == :full_tls
        reply == vcat(pw, 0x00) || error("expected cleartext password over TLS")
        send_packet(conn, seq + 1, ok_payload())
        return
    end
    if reply == [P.CACHING_SHA2_REQUEST_PUBLIC_KEY]
        send_packet(conn, seq + 1, vcat(UInt8[0x01], pem(rsa_key[1])))
        seq, reply = read_packet(conn)
        seen === nothing || push!(seen, reply)
    end
    masked = rsa_oaep_decrypt(pem(rsa_key[2]), reply)
    unmasked = [masked[i] ⊻ nonce[mod1(i, 20)] for i in eachindex(masked)]
    unmasked == vcat(pw, 0x00) || error("RSA password exchange did not decrypt to the password")
    send_packet(conn, seq + 1, ok_payload())
    return
end

@testset "authentication exchanges" begin
    @testset "caching_sha2: fast path" begin
        trace = Symbol[]
        with_peer(conn -> peer_auth_caching_sha2!(conn, "pw"; mode=:fast)) do client
            s = P.Session(client)
            P.read_greeting!(s)
            ok = P.authenticate!(s, "root", "pw", POLICY_PLAIN; trace=trace)
            @test ok isa P.OKPacket && s.phase == P.READY && s.authenticated
        end
        @test trace == [:initial_caching_sha2_password, :fast_auth, :ok]
        with_peer(conn -> peer_auth_caching_sha2!(conn, "")) do client
            s = P.Session(client)
            P.read_greeting!(s)
            @test P.authenticate!(s, "root", nothing, POLICY_PLAIN) isa P.OKPacket
        end
    end

    @testset "caching_sha2: full auth refused over plain TCP by default" begin
        with_peer(conn -> (try; peer_auth_caching_sha2!(conn, "pw"; mode=:rsa); catch; end)) do client
            s = P.Session(client)
            P.read_greeting!(s)
            err = try; P.authenticate!(s, "root", "pw", POLICY_PLAIN); nothing; catch e; e; end
            @test err isa P.AuthError && occursin("server_public_key", err.msg)
            @test s.phase == P.CLOSED
        end
    end

    @testset "caching_sha2: full auth over TLS sends the cleartext password" begin
        with_peer(conn -> peer_auth_caching_sha2!(conn, "pw"; mode=:full_tls)) do client
            s = P.Session(client)
            P.read_greeting!(s)
            trace = Symbol[]
            @test P.authenticate!(s, "root", "pw", POLICY_TLS; trace=trace) isa P.OKPacket
            @test trace[end - 1] != :fast_auth && :ok in trace
        end
    end

    @testset "caching_sha2: RSA exchange with key retrieval and with a local key" begin
        seen = Vector{UInt8}[]
        with_peer(conn -> peer_auth_caching_sha2!(conn, "pw"; mode=:rsa, seen=seen)) do client
            s = P.Session(client)
            P.read_greeting!(s)
            trace = Symbol[]
            @test P.authenticate!(s, "root", "pw", P.AuthPolicy(; get_server_public_key=true); trace=trace) isa P.OKPacket
            @test trace == [:initial_caching_sha2_password, :rsa_request, :rsa_response, :ok]
        end
        @test seen[2] == [0x02] && length(seen[3]) == 256
        with_peer(conn -> peer_auth_caching_sha2!(conn, "pw"; mode=:rsa, rsa_key=("rsa4096.pub", "rsa4096.key"))) do client
            s = P.Session(client)
            P.read_greeting!(s)
            @test P.authenticate!(s, "root", "pw", P.AuthPolicy(; server_public_key=pem("rsa4096.pub"))) isa P.OKPacket
        end
        # a wrong local key yields garbage the server rejects
        with_peer(conn -> (try; peer_auth_caching_sha2!(conn, "pw"; mode=:rsa); catch; end; try; send_packet(conn, 6, vcat(UInt8[0xFF, 0x15, 0x04], codeunits("#28000Access denied"))); catch; end)) do client
            s = P.Session(client)
            P.read_greeting!(s)
            err = try; P.authenticate!(s, "root", "pw", P.AuthPolicy(; server_public_key=pem("rsa3072.pub"))); nothing; catch e; e; end
            @test err isa P.MySQLError
            @test !isopen(s)
        end
    end

    @testset "auth switch to mysql_native_password" begin
        replies = Vector{UInt8}[]
        with_peer(conn -> begin
            send_packet(conn, 0, greeting(; plugin="caching_sha2_password"))
            read_packet(conn)
            nonce = collect(UInt8, 51:70)
            send_packet(conn, 2, vcat(UInt8[0xFE], codeunits("mysql_native_password"), UInt8[0x00], nonce, UInt8[0x00]))
            seq, reply = read_packet(conn)
            push!(replies, reply)
            native_verify(SHA.sha1(SHA.sha1(Vector{UInt8}(codeunits("pw")))), nonce, reply) || error("native scramble does not verify")
            send_packet(conn, seq + 1, ok_payload())
        end) do client
            s = P.Session(client)
            P.read_greeting!(s)
            trace = Symbol[]
            @test P.authenticate!(s, "root", "pw", POLICY_PLAIN; trace=trace) isa P.OKPacket
            @test trace == [:initial_caching_sha2_password, :switch_mysql_native_password, :ok]
        end
        @test length(replies[1]) == 20
        # switch to an unsupported plugin
        with_peer(conn -> (send_packet(conn, 0, greeting()); read_packet(conn); send_packet(conn, 2, vcat(UInt8[0xFE], codeunits("client_ed25519"), UInt8[0x00], zeros(UInt8, 32))); await_eof(conn))) do client
            s = P.Session(client)
            P.read_greeting!(s)
            err = try; P.authenticate!(s, "root", "pw", POLICY_PLAIN); nothing; catch e; e; end
            @test err isa P.UnsupportedAuthError && err.plugin == "client_ed25519"
            @test s.phase == P.CLOSED
        end
    end

    @testset "MariaDB native password (announced plugin), wrong password" begin
        with_peer(conn -> begin
            nonce = collect(UInt8, 1:20)
            send_packet(conn, 0, greeting(; version="11.4.2-MariaDB", caps=MARIADB_SERVER_CAPS, plugin="mysql_native_password", scramble=nonce))
            seq, response = read_packet(conn)
            c = P.PacketCursor(response)
            P.skip!(c, 32)
            P.read_nul_string!(c)
            scramble = P.read_lenenc_bytes!(c)
            if native_verify(SHA.sha1(SHA.sha1(Vector{UInt8}(codeunits("pw")))), nonce, scramble)
                send_packet(conn, seq + 1, ok_payload())
            else
                send_packet(conn, seq + 1, vcat(UInt8[0xFF, 0x15, 0x04], codeunits("#28000Access denied for user")))
            end
        end) do client
            s = P.Session(client)
            P.read_greeting!(s)
            trace = Symbol[]
            @test P.authenticate!(s, "root", "pw", POLICY_PLAIN; trace=trace) isa P.OKPacket
            @test trace == [:initial_mysql_native_password, :ok]
        end
        with_peer(conn -> begin
            send_packet(conn, 0, greeting(; version="11.4.2-MariaDB", caps=MARIADB_SERVER_CAPS, plugin="mysql_native_password"))
            seq, _ = read_packet(conn)
            send_packet(conn, seq + 1, vcat(UInt8[0xFF, 0x15, 0x04], codeunits("#28000Access denied for user")))
            await_eof(conn)
        end) do client
            s = P.Session(client)
            P.read_greeting!(s)
            err = try; P.authenticate!(s, "root", "wrong", POLICY_PLAIN); nothing; catch e; e; end
            @test err isa P.Error && err.errno == P.ER_ACCESS_DENIED_ERROR
            @test s.phase == P.CLOSED
        end
    end

    @testset "sha256_password over plain TCP with key retrieval" begin
        with_peer(conn -> begin
            nonce = collect(UInt8, 21:40)
            send_packet(conn, 0, greeting(; plugin="sha256_password", scramble=nonce))
            seq, response = read_packet(conn)
            c = P.PacketCursor(response)
            P.skip!(c, 32)
            P.read_nul_string!(c)
            P.read_lenenc_bytes!(c) == [P.SHA256_REQUEST_PUBLIC_KEY] || error("expected a public key request")
            send_packet(conn, seq + 1, vcat(UInt8[0x01], pem("rsa2048.pub")))
            seq, reply = read_packet(conn)
            masked = rsa_oaep_decrypt(pem("rsa2048.key"), reply)
            [masked[i] ⊻ nonce[mod1(i, 20)] for i in eachindex(masked)] == vcat(codeunits("pw"), 0x00) || error("bad sha256 RSA reply")
            send_packet(conn, seq + 1, ok_payload())
        end) do client
            s = P.Session(client)
            P.read_greeting!(s)
            trace = Symbol[]
            @test P.authenticate!(s, "root", "pw", P.AuthPolicy(; get_server_public_key=true); trace=trace) isa P.OKPacket
            @test trace == [:initial_sha256_password, :rsa_response, :ok]
        end
    end

    @testset "mysql_clear_password gating" begin
        with_peer(conn -> (send_packet(conn, 0, greeting(; plugin="mysql_clear_password")); await_eof(conn))) do client
            s = P.Session(client)
            P.read_greeting!(s)
            @test_throws P.AuthError P.authenticate!(s, "root", "pw", POLICY_PLAIN)
            @test s.phase == P.CLOSED
        end
        seen = Vector{UInt8}[]
        with_peer(conn -> begin
            send_packet(conn, 0, greeting(; plugin="mysql_clear_password"))
            seq, r = read_packet(conn)
            push!(seen, r)
            send_packet(conn, seq + 1, ok_payload())
        end) do client
            s = P.Session(client)
            P.read_greeting!(s)
            @test P.authenticate!(s, "root", "pw", P.AuthPolicy(; enable_cleartext_plugin=true, insecure_cleartext_auth=true)) isa P.OKPacket
        end
        c = P.PacketCursor(seen[1])
        P.skip!(c, 32)
        P.read_nul_string!(c)
        @test P.read_lenenc_bytes!(c) == vcat(codeunits("pw"), 0x00)
        @test P.read_nul_string!(c) == "mysql_clear_password"
    end
end
