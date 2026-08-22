# Live lanes: the native backend against real servers in Harbor containers. Runs only when
# Docker is available; images are configurable via MYSQL_NATIVE_IMAGES (comma separated).
using Harbor
include(joinpath(@__DIR__, "..", "compat_manifest.jl"))
using .CompatManifest

const LIVE_IMAGES = split(get(ENV, "MYSQL_NATIVE_IMAGES", "mysql:8.4,mariadb:11.4"), ',')
const ROOT_PW = "native-secret"

function image_ref(ref::AbstractString)
    slash = findlast('/', ref)
    colon = findlast(':', ref)
    (colon !== nothing && (slash === nothing || colon > slash)) && return String(ref[1:prevind(ref, colon)]), String(ref[nextind(ref, colon):end])
    return String(ref), "latest"
end

function wait_for_native(port; timeout=120.0)
    t0 = time()
    last = nothing
    while time() - t0 < timeout
        try
            h = N.connect("127.0.0.1", "root", ROOT_PW; port=port, connect_timeout=3)
            return h
        catch err
            last = err
            sleep(1.0)
        end
    end
    error("server did not become ready: $(sprint(showerror, last))")
end

function exec!(h, sql)
    P.query!(h.session, sql)
    r = P.read_command_response!(h.session)
    r isa P.ResultHeader && P.drain!(h.session)
    return r
end

function select_strings(h, sql)
    P.query!(h.session, sql)
    hdr = P.read_command_response!(h.session)
    rows = Vector{Union{Missing, String}}[]
    offsets, lengths = Int[], Int[]
    while true
        r = P.read_row!(h.session)
        r isa P.ResultEnd && break
        P.scan_text_row!(r, length(hdr.columns), offsets, lengths)
        push!(rows, [lengths[i] < 0 ? missing : String(r.buf[offsets[i]:(offsets[i] + lengths[i] - 1)]) for i in 1:length(hdr.columns)])
    end
    return rows
end

function run_live_lane(ref::String)
    image, tag = image_ref(ref)
    mysql = startswith(image, "mysql")
    port = pick_port()
    command = mysql ? ["--mysql-native-password=ON"] : nothing
    env = Dict("MYSQL_ROOT_PASSWORD" => ROOT_PW, "MARIADB_ROOT_PASSWORD" => ROOT_PW)
    Harbor.with_container(image; tag=tag, ports=Dict(3306 => port), environment=env, command=command, wait_strategy=(port=3306,), wait_timeout=180.0) do _
        @testset "$ref" begin
            root = wait_for_native(port)
            @test root.session.server.kind == (mysql ? :mysql : :mariadb)
            # both images auto-generate a self-signed server certificate, so :preferred lands on TLS
            @test P.is_secure_transport(root.session)
            @test root.auth_trace[end] == :ok
            # the auto-generated certificate is not signed by our CA: chain verification refuses it, with no fallback
            err = try; N.connect("127.0.0.1", "root", ROOT_PW; port=port, ssl_mode=:verify_ca, ssl_ca=certfile("ca.crt"), connect_timeout=10); nothing; catch e; e; end
            @test err isa P.TLSNegotiationError
            h = N.connect("127.0.0.1", "root", ROOT_PW; port=port, ssl_mode=:disabled, connect_timeout=10)
            @test !P.is_secure_transport(h.session) && h.auth_trace[end] == :ok
            N.close!(h)
            rows = select_strings(root, "SELECT @@character_set_client, @@character_set_connection, @@character_set_results, @@version")
            @test rows[1][1:3] == ["utf8mb4", "utf8mb4", "utf8mb4"]
            @test select_strings(root, "SELECT 'héllo wörld 🐘'")[1][1] == "héllo wörld 🐘"
            exec!(root, "CREATE DATABASE IF NOT EXISTS nativetest")
            P.init_db!(root.session, "nativetest")
            @test P.read_command_response!(root.session; kind=P.CMD_SIMPLE) isa P.OKPacket
            # wrong password
            err = try; N.connect("127.0.0.1", "root", "nope"; port=port, connect_timeout=10); nothing; catch e; e; end
            @test err isa P.Error && err.errno == P.ER_ACCESS_DENIED_ERROR
            if mysql
                exec!(root, "CREATE USER IF NOT EXISTS 'plain'@'%' IDENTIFIED WITH caching_sha2_password BY 'plainpw'")
                exec!(root, "CREATE USER IF NOT EXISTS 'nat'@'%' IDENTIFIED WITH mysql_native_password BY 'natpw'")
                exec!(root, "CREATE USER IF NOT EXISTS 'sha'@'%' IDENTIFIED WITH sha256_password BY 'shapw'")
                exec!(root, "CREATE USER IF NOT EXISTS 'expired'@'%' IDENTIFIED WITH caching_sha2_password BY 'expiredpw' PASSWORD EXPIRE")
                err = try; N.connect("127.0.0.1", "expired", "expiredpw"; port=port, ssl_mode=:required, can_handle_expired_passwords=true, connect_timeout=10); nothing; catch e; e; end
                @test err isa P.Error && err.errno == P.ER_MUST_CHANGE_PASSWORD
                # full auth over plaintext is refused by default, then succeeds with RSA, then the cache makes it fast
                err = try; N.connect("127.0.0.1", "plain", "plainpw"; port=port, ssl_mode=:disabled, connect_timeout=10); nothing; catch e; e; end
                @test err isa P.AuthError
                h = N.connect("127.0.0.1", "plain", "plainpw"; port=port, ssl_mode=:disabled, get_server_public_key=true, connect_timeout=10)
                @test h.auth_trace == [:initial_caching_sha2_password, :rsa_request, :rsa_response, :ok]
                N.close!(h)
                h = N.connect("127.0.0.1", "plain", "plainpw"; port=port, ssl_mode=:disabled, connect_timeout=10)
                @test h.auth_trace == [:initial_caching_sha2_password, :fast_auth, :ok]
                N.close!(h)
                # full auth over TLS is cleartext inside the tunnel
                exec!(root, "ALTER USER 'plain'@'%' IDENTIFIED WITH caching_sha2_password BY 'plainpw2'")
                h = N.connect("127.0.0.1", "plain", "plainpw2"; port=port, ssl_mode=:required, connect_timeout=10)
                @test h.auth_trace == [:initial_caching_sha2_password, :full_auth_cleartext, :ok] && P.is_secure_transport(h.session)
                N.close!(h)
                # auth switch from the announced caching_sha2 to the account's native plugin
                h = N.connect("127.0.0.1", "nat", "natpw"; port=port, ssl_mode=:disabled, connect_timeout=10)
                @test h.auth_trace == [:initial_caching_sha2_password, :switch_mysql_native_password, :ok]
                N.close!(h)
                # sha256_password over TLS (cleartext) and over plaintext (RSA)
                h = N.connect("127.0.0.1", "sha", "shapw"; port=port, ssl_mode=:required, connect_timeout=10)
                @test h.auth_trace[end] == :ok
                N.close!(h)
                h = N.connect("127.0.0.1", "sha", "shapw"; port=port, ssl_mode=:disabled, get_server_public_key=true, connect_timeout=10)
                @test :rsa_response in h.auth_trace
                N.close!(h)
            else
                # MariaDB: root is mysql_native_password (no switch)
                @test root.auth_trace == [:initial_mysql_native_password, :ok]
                exec!(root, "CREATE USER IF NOT EXISTS 'nat'@'%' IDENTIFIED BY 'natpw'")
                h = N.connect("127.0.0.1", "nat", "natpw"; port=port, connect_timeout=10)
                @test h.auth_trace == [:initial_mysql_native_password, :ok]
                N.close!(h)
            end
            P.ping!(root.session)
            @test P.read_command_response!(root.session; kind=P.CMD_SIMPLE) isa P.OKPacket
            P.set_option!(root.session, P.MYSQL_OPTION_MULTI_STATEMENTS_ON)
            @test P.read_command_response!(root.session) isa Union{P.OKPacket, P.EOFPacket}
            P.set_option!(root.session, P.MYSQL_OPTION_MULTI_STATEMENTS_OFF)
            @test P.read_command_response!(root.session) isa Union{P.OKPacket, P.EOFPacket}
            N.close!(root)
            @test !isopen(root)
            # the executable compatibility manifest: Connector/C backend vs native, same server
            CompatManifest.run!(
                (; db) -> DBInterface.connect(MySQL.Connection, "127.0.0.1", "root", ROOT_PW; port=port, db=db),
                (; db) -> DBInterface.connect(N.Connection, "127.0.0.1", "root", ROOT_PW; port=port, db=db, connect_timeout=10))
        end
    end
    return nothing
end

if docker_available()
    @testset "live lanes" begin
        for ref in LIVE_IMAGES
            run_live_lane(String(strip(ref)))
        end
    end
else
    @info "Docker not available; skipping native live lanes"
end
