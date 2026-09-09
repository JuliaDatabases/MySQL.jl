# Live lanes: the native backend against real servers in Harbor containers. Runs only when
# Docker is available; images are configurable via MYSQL_NATIVE_IMAGES (comma separated).
using Harbor
include(joinpath(@__DIR__, "..", "behavior_manifest.jl"))
using .BehaviorManifest
include(joinpath(@__DIR__, "leak_soak.jl"))
include(joinpath(@__DIR__, "..", "user_workflow.jl"))

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

function run_live_lane(ref::String; soak::Bool=false, manifest::Bool=false)
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
                exec!(root, "ALTER USER 'expired'@'%' PASSWORD EXPIRE")
                # without the flag the server refuses the login outright
                err = try; N.connect("127.0.0.1", "expired", "expiredpw"; port=port, ssl_mode=:required, connect_timeout=10); nothing; catch e; e; end
                @test err isa P.Error && err.errno == 1862 # ER_MUST_CHANGE_PASSWORD_LOGIN; 1820 is the sandbox query error
                # with it the connection is in sandbox mode: only a password reset is allowed,
                # after which the session is a normal one
                h = N.connect("127.0.0.1", "expired", "expiredpw"; port=port, ssl_mode=:required, can_handle_expired_passwords=true, connect_timeout=10)
                @test !h.bootstrapped && h.auth_trace[end] == :ok && isopen(h)
                err = try; exec!(h, "SELECT 1"); nothing; catch e; e; end
                @test err isa P.Error && err.errno == P.ER_MUST_CHANGE_PASSWORD && isopen(h)
                exec!(h, "ALTER USER USER() IDENTIFIED BY 'expiredpw2'")
                @test select_strings(h, "SELECT 1, @@character_set_connection")[1] == ["1", "utf8mb4"]
                N.close!(h)
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
            conn = DBInterface.connect(MySQL.Connection, "127.0.0.1", "root", ROOT_PW; port=port)
            try
                run_user_workflow(conn)
            finally
                DBInterface.close!(conn)
            end
            @test !isopen(conn)
            # an idle connection reaped by wait_timeout: MySQL 8.0.24+ announces it (4031),
            # MariaDB just closes (2006); either way the next command reconnects
            conn = DBInterface.connect(MySQL.Connection, "127.0.0.1", "root", ROOT_PW; port=port, reconnect=true)
            stmt = nothing
            try
                stmt = DBInterface.prepare(conn, "SELECT HEX(?) AS data")
                DBInterface.execute(conn, "SET SESSION wait_timeout = 1")
                N.send_long_data!(stmt, 0, UInt8[0x00])
                N.send_long_data!(stmt, 0, UInt8[0xff])
                sleep(2.5)
                err = try; DBInterface.execute(conn, "SELECT 1"); nothing; catch e; e; end
                @test err isa MySQL.Error && err.errno in (4031, P.CR_SERVER_GONE_ERROR)
                @test !isopen(conn)
                # The next execute re-prepares on the new session and replays copied
                # long-data chunks. No statement execute was attempted on the dead one.
                @test only(Tables.columntable(DBInterface.execute(stmt, (UInt8[],))).data) == "00FF"
                @test isempty(stmt.long_data) && stmt.generation == (@atomic conn.generation)
                @test Tables.columntable(DBInterface.execute(conn, "SELECT 1 AS v")).v == [1]
                @test isopen(conn)
            finally
                stmt === nothing || DBInterface.close!(stmt)
                DBInterface.close!(conn)
            end
            # the executable behavior manifest: golden values on the primary lane only
            # (goldens are captured against mysql:8.4; server wording differs on MariaDB)
            manifest && BehaviorManifest.run!(
                live_factory(MySQL.Connection, port);
                password=ROOT_PW,
                port=port)
            soak && run_leak_soak(port)
        end
    end
    return nothing
end

function live_factory(T::Type, server_port::Integer)
    return function (; host="127.0.0.1", user="root", passwd=ROOT_PW, db="", port=server_port, kw...)
        options = (; kw...)
        db === nothing || (options = merge((; db=db), options))
        port === nothing || (options = merge((; port=port), options))
        return DBInterface.connect(T, host, user, passwd; options...)
    end
end

if docker_available()
    @testset "live lanes" begin
        for (i, ref) in enumerate(LIVE_IMAGES)
            # the §8.10 leak/lifecycle soak and the golden manifest run on the first (primary) lane only
            run_live_lane(String(strip(ref)); soak=i == 1, manifest=i == 1)
        end
    end
else
    @info "Docker not available; skipping native live lanes"
end
