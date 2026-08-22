@testset "Native options truth table" begin
    @test_throws ArgumentError N.ConnectOptions("h", "u"; bogus=1)
    err = try; N.ConnectOptions("h", "u"; ssl_cipher="AES"); nothing; catch e; e; end
    @test err isa ArgumentError && occursin("removed", err.msg)
    @test_throws ArgumentError N.ConnectOptions("h", "u"; plugin_dir="/x")
    @test_throws ArgumentError N.ConnectOptions("h", "u"; compress=true)
    @test N.ConnectOptions("h", "u"; compress=false) isa N.ConnectOptions
    @test_logs (:warn, r"deprecated") N.ConnectOptions("h", "u"; data_truncation=true)
    @test_throws ArgumentError N.ConnectOptions("h", "u"; unix_socket="/tmp/mysql.sock")
    @test_throws ArgumentError N.ConnectOptions("h", "u"; named_pipe=true)
    @test_throws ArgumentError N.ConnectOptions("h", "u"; protocol=:socket)
    @test N.ConnectOptions("h", "u"; protocol=:tcp).port == 3306
    @test N.ConnectOptions("h", "u"; protocol=MySQL.API.MYSQL_PROTOCOL_TCP).port == 3306
    @test_throws ArgumentError N.ConnectOptions("h", "u"; protocol=MySQL.API.MYSQL_PROTOCOL_SOCKET)
    @test_throws ArgumentError N.ConnectOptions("h", "u"; charset_name="latin1")
    @test N.ConnectOptions("h", "u"; charset_name="UTF8MB4").port == 3306
    @test_throws ArgumentError N.ConnectOptions("h", "u"; ssl_ca="a", ssl_capath="b")
    @test N.ConnectOptions("h", "u"; ssl_capath="/etc/ssl/certs").tls.ca_file == "/etc/ssl/certs"
    @test_throws ArgumentError N.ConnectOptions("h", "u"; local_files=true)
    @test N.ConnectOptions("h", "u"; local_files=true, local_infile_handler=identity).client_flags & P.CLIENT_LOCAL_FILES != 0
    @test N.ConnectOptions("h", "u"; port=0).port == 3306
    @test_throws ArgumentError N.ConnectOptions("h", "u"; port=70000)
    @test N.ConnectOptions("h", "u").client_flags & P.CLIENT_MULTI_STATEMENTS == 0
    @test N.ConnectOptions("h", "u"; db="app").client_flags & P.CLIENT_CONNECT_WITH_DB != 0
    @test N.ConnectOptions("h", "u").client_flags & P.CLIENT_CONNECT_WITH_DB == 0
    @test N.ConnectOptions("h", "u"; multi_statements=true, found_rows=true, ignore_space=true).client_flags & (P.CLIENT_MULTI_STATEMENTS | P.CLIENT_FOUND_ROWS | P.CLIENT_IGNORE_SPACE) == (P.CLIENT_MULTI_STATEMENTS | P.CLIENT_FOUND_ROWS | P.CLIENT_IGNORE_SPACE)
    @test_throws P.UnsupportedAuthError N.ConnectOptions("h", "u"; default_auth="client_ed25519")
    @test N.ConnectOptions("h", "u"; default_auth="mysql_clear_password").auth.enable_cleartext_plugin
    @test N.ConnectOptions("h", "u"; server_public_key=certfile("rsa2048.pub")).auth.server_public_key == pem("rsa2048.pub")
    @test_throws ArgumentError N.ConnectOptions("h", "u"; server_public_key="missing-public-key.pem")
    @test_throws ArgumentError N.ConnectOptions("h", "u"; max_local_infile_bytes=0)
    @test N.ConnectOptions("h", "u"; max_allowed_packet=1024 * 1024).limits.max_packet == 1024 * 1024
    @test N.ConnectOptions("h", "u"; max_response_bytes=nothing).limits.max_response_bytes === nothing
    @test N.ConnectOptions("h", "u"; can_handle_expired_passwords=true).client_flags & P.CLIENT_CAN_HANDLE_EXPIRED_PASSWORDS != 0
    @test N.ConnectOptions("h", "u"; attrs=["program_name" => "x"]).attrs == ["program_name" => "x"]
    @test any(p -> p.first == "_client_name", N.ConnectOptions("h", "u").attrs)
    @test N.ConnectOptions("::1", "u").host == "::1" && N.hostport("::1", 3306) == "[::1]:3306" && N.hostport("db.example", 1) == "db.example:1"
end

@testset "ssl conflict table" begin
    R = N.resolve_ssl_mode
    @test R() == P.SSL_PREFERRED
    @test R(; has_ca=true) == P.SSL_VERIFY_CA
    @test R(; ssl_enforce=true) == P.SSL_REQUIRED
    @test R(; ssl_verify_server_cert=true) == P.SSL_VERIFY_IDENTITY
    @test R(; ssl_verify_server_cert=true, ssl_enforce=true, has_ca=true) == P.SSL_VERIFY_IDENTITY
    @test R(; ssl_mode=:required, has_ca=true) == P.SSL_REQUIRED              # explicit mode wins
    @test R(; ssl_mode="VERIFY_CA") == P.SSL_VERIFY_CA
    @test R(; ssl_mode=MySQL.API.SSL_MODE_VERIFY_IDENTITY) == P.SSL_VERIFY_IDENTITY
    @test R(; ssl_mode=:disabled, ssl_enforce=false, ssl_verify_server_cert=false) == P.SSL_DISABLED   # explicit false never lowers/raises
    @test_throws ArgumentError R(; ssl_mode=:disabled, ssl_enforce=true)
    @test_throws ArgumentError R(; ssl_mode=:required, ssl_verify_server_cert=true)
    @test_throws ArgumentError R(; ssl_mode=:bogus)
    @test N.ConnectOptions("h", "u"; ssl_mode=MySQL.API.SSL_MODE_REQUIRED).tls.mode == P.SSL_REQUIRED
    @test N.ConnectOptions("h", "u"; ssl_enforce=true).tls.mode == P.SSL_REQUIRED
    @test N.ConnectOptions("h", "u"; ssl_verify_server_cert=false).tls.mode == P.SSL_PREFERRED
    @test P.tls_server_name(P.TLSOptions(; mode=:preferred), "127.0.0.1") === nothing
    @test P.tls_server_name(P.TLSOptions(; mode=:verify_identity), "127.0.0.1") == "127.0.0.1"
    @test P.tls_server_name(P.TLSOptions(; mode=:preferred), "db.example.com") == "db.example.com"
    @test P.tls_server_name(P.TLSOptions(; mode=:preferred, server_name="sni.example"), "10.0.0.1") == "sni.example"
    @test P.tls_server_name(P.TLSOptions(; mode=:verify_identity), "[::1]") == "::1"
    @test P.tls_server_name(P.TLSOptions(; mode=:preferred), "[::1]") === nothing
    # tls_version pins the protocol versions (libmysqlclient spelling)
    @test N.ConnectOptions("h", "u").tls.min_version === nothing
    o = N.ConnectOptions("h", "u"; tls_version="TLSv1.3")
    @test o.tls.min_version == Reseau.TLS.TLS1_3_VERSION && o.tls.max_version == Reseau.TLS.TLS1_3_VERSION
    o = N.ConnectOptions("h", "u"; tls_version="TLSv1.3, tlsv1.2")
    @test o.tls.min_version == Reseau.TLS.TLS1_2_VERSION && o.tls.max_version == Reseau.TLS.TLS1_3_VERSION
    @test_throws ArgumentError N.ConnectOptions("h", "u"; tls_version="TLSv1.1")
    @test_throws ArgumentError N.ConnectOptions("h", "u"; tls_version="")
end

@testset "option files and environment" begin
    mktempdir() do dir
        path = joinpath(dir, "my.cnf")
        write(path, """
        # comment
        [mysqld]
        port=9999
        [client]
        host = db.example
        user = "alice"
        password = 's3cret'
        port=3307
        database=app
        ssl-ca=/etc/ca.pem
        tls-version=TLSv1.3
        connect_timeout = 7
        unknown-key=ignored
        [extra]
        port=3308
        """)
        o = N.ConnectOptions("", ""; option_file=path)
        @test o.host == "db.example" && o.user == "alice" && o.password == "s3cret"
        @test o.port == 3307 && o.db == "app" && o.connect_timeout == 7
        @test o.tls.ca_file == "/etc/ca.pem" && o.tls.mode == P.SSL_VERIFY_CA
        @test o.tls.min_version == Reseau.TLS.TLS1_3_VERSION == o.tls.max_version
        # explicit keywords beat the file; a requested group overrides [client]
        @test N.ConnectOptions("h", "u"; option_file=path, port=1).port == 1
        @test N.ConnectOptions("h", "u"; option_file=path, option_group="extra").port == 3308
        @test N.ConnectOptions("h", "u"; option_file=path, ssl_mode=:disabled).tls.mode == P.SSL_DISABLED
        @test N.read_option_file(path)[:host] == "db.example"
        reversed = joinpath(dir, "reversed.cnf")
        write(reversed, "[extra]\nport=3308\n[client]\nport=3307\n")
        @test N.ConnectOptions("h", "u"; option_file=reversed, option_group="extra").port == 3308
        inc = joinpath(dir, "inc.cnf")
        write(inc, "!include /etc/other.cnf\n")
        @test_throws ArgumentError N.ConnectOptions("h", "u"; option_file=inc)
        bad = joinpath(dir, "bad.cnf")
        write(bad, "[client\nhost=x\n")
        @test_throws ArgumentError N.ConnectOptions("h", "u"; option_file=bad)
        # missing file is skipped; .mylogin.cnf is skipped with a warning
        @test N.ConnectOptions("h", "u"; option_file=joinpath(dir, "missing.cnf")).host == "h"
        login = joinpath(dir, ".mylogin.cnf")
        write(login, "binary")
        @test_logs (:warn, r"mylogin") N.ConnectOptions("h", "u"; option_file=login)
        if !Sys.iswindows()
            ww = joinpath(dir, "ww.cnf")
            write(ww, "[client]\nport=4444\n")
            chmod(ww, 0o666)
            @test (@test_logs (:warn, r"world-writable") N.ConnectOptions("h", "u"; option_file=ww)).port == 3306
        end
    end
    withenv("MYSQL_TCP_PORT" => "3399", "MYSQL_PWD" => "leak") do
        @test N.ConnectOptions("h", "u").port == 3306
        o = N.ConnectOptions("h", "u"; read_env=true)
        @test o.port == 3399 && o.password === nothing
        @test N.ConnectOptions("h", "u"; read_env=true, port=5).port == 5
    end
    @test N.default_option_files() isa Vector{String}
    @test any(path -> basename(path) == ".mylogin.cnf", N.default_option_files())
end

# A loopback server that accepts any number of connections and completes a plaintext
# handshake on each (used by the reaper and fd tests).
function multi_accept_server(f::Function)
    listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0))
    port = Int(Reseau.TCP.addr(listener).port)
    conns = Reseau.TCP.Conn[]
    lock = ReentrantLock()
    Threads.@spawn begin
        while true
            conn = try
                Reseau.TCP.accept(listener)
            catch
                break   # listener closed
            end
            @lock lock push!(conns, conn)
            Threads.@spawn begin
                try
                    plain_peer_connect!(conn; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, after=c -> await_eof(c))
                catch
                finally
                    close(conn)
                end
            end
        end
    end
    try
        return f(port)
    finally
        close(listener)
        @lock lock foreach(c -> (try; close(c); catch; end), conns)
    end
end

# Allocated in a function so no top-level binding keeps the handles reachable.
function abandon_handles(port, n)
    refs = WeakRef[]
    entries = N.ReapEntry[]
    for _ in 1:n
        h = native_connect(port; ssl_mode=:disabled)
        push!(refs, WeakRef(h))
        push!(entries, h.entry)
    end
    return refs, entries
end

@testset "outbound bind address" begin
    multi_accept_server() do port
        h = native_connect(port; ssl_mode=:disabled, bind="127.0.0.1")
        try
            local_addr = Reseau.TCP.local_addr(h.session.transport)
            @test local_addr.ip == (0x7F, 0x00, 0x00, 0x01)
        finally
            N.close!(h)
        end
    end
end

@testset "reaper: exactly-once, finalizer-free reclamation" begin
    N.reap_now!()
    @test N.pending_reaps() == 0
    multi_accept_server() do port
        # abandoned handles are reclaimed by the reaper, never by finalizer I/O
        refs, entries = abandon_handles(port, 6)
        closed = 0
        for _ in 1:10
            GC.gc()
            closed += N.reap_now!()
            closed == 6 && break
        end
        @test closed == 6
        @test all(e -> (@atomic e.state) == :closed, entries)
        @test all(e -> e.transport === nothing, entries)
        @test N.pending_reaps() == 0
        # explicitly closed handles are never enqueued again
        entries2 = N.ReapEntry[]
        for _ in 1:6
            h = native_connect(port; ssl_mode=:disabled)
            push!(entries2, h.entry)
            N.close!(h)
            @test (@atomic h.entry.state) == :closed
            N.close!(h)   # idempotent
        end
        GC.gc(); GC.gc()
        @test N.reap_now!() == 0
        @test all(e -> (@atomic e.state) == :closed, entries2)
        GC.gc(); GC.gc()
        @test all(r -> r.value === nothing, refs)
    end
    # the timer-driven reaper runs on its own
    @test N.REAPER_TIMER[] isa Timer
end

@testset "no descriptor growth across connect/close cycles" begin
    Sys.iswindows() && return
    multi_accept_server() do port
        for _ in 1:5
            h = native_connect(port; ssl_mode=:disabled)
            N.close!(h)
        end
        GC.gc()
        before = length(readdir("/dev/fd"))
        for _ in 1:30
            h = native_connect(port; ssl_mode=:disabled)
            N.close!(h)
        end
        GC.gc()
        sleep(0.2)
        @test length(readdir("/dev/fd")) <= before + 2
    end
end
