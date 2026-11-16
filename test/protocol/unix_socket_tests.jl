# Connections over a Unix socket against the fake peer, served by `Sockets.listen(path)`.
using Sockets: Sockets

function with_unix_server(f::Function, handler::Function)
    path = joinpath(mktempdir(), "mysql.sock")
    server = Sockets.listen(path)
    err = Ref{Any}(nothing)
    task = Threads.@spawn try
        conn = Sockets.accept(server)
        try
            handler(conn)
        finally
            close(conn)
        end
    catch e
        err[] = e
    end
    try
        return f(path)
    finally
        close(server)
        wait(task)
        err[] === nothing || throw(err[])
    end
end

# caching_sha2_password full authentication: over a secure transport the client sends the
# password in clear text instead of asking for the server's RSA key.
function socket_peer_connect!(conn)
    send_packet(conn, 0, greeting(; scramble=collect(UInt8, 101:120)))
    seq, response = read_packet(conn)
    length(response) == 32 && error("unexpected SSLRequest over a Unix socket")
    send_packet(conn, seq + 1, UInt8[0x01, P.CACHING_SHA2_PERFORM_FULL_AUTH])
    seq, reply = read_packet(conn)
    reply == vcat(Vector{UInt8}(codeunits("pw")), 0x00) || error("expected the cleartext password over the socket")
    send_packet(conn, seq + 1, ok_payload(; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_SESSION_STATE_CHANGED, state=utf8mb4_state(), track=true))
    stall_until_eof(conn)
    return nothing
end

Sys.iswindows() || @testset "Unix socket transport" begin
    for kw in ((;), (; protocol=:socket))
        with_unix_server(socket_peer_connect!) do path
            h = N.connect("localhost", "root", "pw"; unix_socket=path, connect_timeout=10, kw...)
            @test h.session.transport isa Reseau.Unix.Conn
            @test !P.is_secure_transport(h.session) && :full_auth_cleartext in h.auth_trace
            N.close!(h)
        end
    end
    missing_path = joinpath(mktempdir(), "missing.sock")
    @test_throws SystemError N.connect("localhost", "root", "pw"; unix_socket=missing_path, connect_timeout=10)
end

@testset "a Unix socket is secure for caching_sha2_password only" begin
    # The server accepts a cleartext password over a socket for caching_sha2_password, but
    # sha256_password requires TLS, so it still asks for the server's RSA key.
    pw = Vector{UInt8}(codeunits("pw"))
    nonce = collect(UInt8, 1:20)
    socket = P.AuthPolicy(; local_socket=true, get_server_public_key=true)
    @test P.step!(P.AuthState(P.CachingSha2Password(), nonce), UInt8[P.CACHING_SHA2_PERFORM_FULL_AUTH], pw, socket) == vcat(pw, 0x00)
    @test P.initial_response(P.Sha256Password(), pw, nonce, socket) == [P.SHA256_REQUEST_PUBLIC_KEY]
end
