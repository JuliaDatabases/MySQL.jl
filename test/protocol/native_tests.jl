struct LocalInfileFunctor end
(::LocalInfileFunctor)(::String) = nothing

@testset "Native options truth table" begin
    @test_throws ArgumentError N.ConnectOptions("h", "u"; bogus=1)
    err = try; N.ConnectOptions("h", "u"; ssl_cipher="AES"); nothing; catch e; e; end
    @test err isa ArgumentError && occursin("removed", err.msg)
    @test_throws ArgumentError N.ConnectOptions("h", "u"; plugin_dir="/x")
    @test_throws ArgumentError N.ConnectOptions("h", "u"; compress=true)
    @test N.ConnectOptions("h", "u"; compress=false) isa N.ConnectOptions
    @test_logs (:warn, r"deprecated") N.ConnectOptions("h", "u"; data_truncation=true)
    @test N.ConnectOptions("h", "u"; unix_socket="/tmp/mysql.sock").host == "h"
    @test_throws ArgumentError N.ConnectOptions("h", "u"; named_pipe=true)
    @test N.ConnectOptions("h", "u"; named_pipe=nothing, protocol=:tcp).host == "h"
    @test_throws ArgumentError N.ConnectOptions("h", "u"; protocol=:socket)
    @test N.ConnectOptions("h", "u"; named_pipe=true, protocol=:tcp).host == "h"
    if Sys.iswindows()
        @test_throws ArgumentError N.ConnectOptions(".", "u")
    else
        @test_throws ArgumentError N.ConnectOptions("", "u")
        @test_throws ArgumentError N.ConnectOptions("localhost", "u")
        @test_throws ArgumentError N.ConnectOptions("localhost", "u"; protocol=:default)
        @test_throws ArgumentError N.ConnectOptions("localhost", "u"; protocol=MySQL.API.MYSQL_PROTOCOL_DEFAULT)
        @test N.ConnectOptions("", "u"; protocol=:tcp).host == "localhost"
        @test N.ConnectOptions("localhost", "u"; protocol=:tcp).host == "localhost"
    end
    @test N.ConnectOptions("h", "u"; protocol=:tcp).port == 3306
    @test N.ConnectOptions("h", "u"; protocol=MySQL.API.MYSQL_PROTOCOL_TCP).port == 3306
    @test_throws ArgumentError N.ConnectOptions("h", "u"; protocol=MySQL.API.MYSQL_PROTOCOL_SOCKET)
    @test_throws ArgumentError N.ConnectOptions("h", "u"; charset_name="latin1")
    @test N.ConnectOptions("h", "u"; charset_name="UTF8MB4").port == 3306
    @test_throws ArgumentError N.ConnectOptions("h", "u"; ssl_ca="a", ssl_capath="b")
    @test N.ConnectOptions("h", "u"; ssl_capath="/etc/ssl/certs").tls.ca_file == "/etc/ssl/certs"
    @test_throws ArgumentError N.ConnectOptions("h", "u"; local_files=true)
    @test N.ConnectOptions("h", "u"; local_files=true, local_infile_handler=identity).client_flags & P.CLIENT_LOCAL_FILES != 0
    @test N.ConnectOptions("h", "u"; local_files=true, local_infile_handler=LocalInfileFunctor()).local_infile_handler isa LocalInfileFunctor
    @test_throws ArgumentError N.ConnectOptions("h", "u"; local_infile_handler=1)
    @test N.ConnectOptions("h", "u"; port=0).port == 3306
    @test_throws ArgumentError N.ConnectOptions("h", "u"; port=70000)
    @test_throws ArgumentError N.ConnectOptions("h", "u"; port=big(typemax(Int)) + 1)
    @test_throws ArgumentError N.ConnectOptions("h", "u"; connect_timeout=big(N.MAX_TIMEOUT_SECONDS) + 1)
    @test_throws ArgumentError N.ConnectOptions("h", "u"; max_local_infile_bytes=big(typemax(Int)) + 1)
    @test N.ConnectOptions("h", "u").client_flags & P.CLIENT_MULTI_STATEMENTS == 0
    @test N.ConnectOptions("h", "u"; db="app").client_flags & P.CLIENT_CONNECT_WITH_DB != 0
    @test N.ConnectOptions("h", "u").client_flags & P.CLIENT_CONNECT_WITH_DB == 0
    @test N.ConnectOptions("h", "u"; multi_statements=true, found_rows=true, ignore_space=true).client_flags & (P.CLIENT_MULTI_STATEMENTS | P.CLIENT_FOUND_ROWS | P.CLIENT_IGNORE_SPACE) == (P.CLIENT_MULTI_STATEMENTS | P.CLIENT_FOUND_ROWS | P.CLIENT_IGNORE_SPACE)
    @test_throws P.UnsupportedAuthError N.ConnectOptions("h", "u"; default_auth="client_ed25519")
    @test N.ConnectOptions("h", "u"; default_auth="mysql_clear_password").auth.enable_cleartext_plugin
    @test N.ConnectOptions("h", "u"; server_public_key=certfile("rsa2048.pub")).auth.server_public_key == pem("rsa2048.pub")
    @test_throws ArgumentError N.ConnectOptions("h", "u"; server_public_key="missing-public-key.pem")
    @test_throws ArgumentError N.ConnectOptions("h", "u"; max_local_infile_bytes=0)
    @test !N.ConnectOptions("h", "u"; reconnect=nothing).reconnect
    @test N.ConnectOptions("h", "u"; reconnect=true).reconnect
    @test N.ConnectOptions("h", "u"; max_allowed_packet=nothing).limits.max_packet == P.DEFAULT_MAX_PACKET
    @test N.ConnectOptions("h", "u"; max_allowed_packet=1024 * 1024).limits.max_packet == 1024 * 1024
    @test N.ConnectOptions("h", "u"; max_response_bytes=nothing).limits.max_response_bytes === nothing
    limits = N.ConnectOptions("h", "u"; max_preauth_packet=4096, max_auth_rounds=3, max_auth_bytes=2048, max_session_state_bytes=1024).limits
    @test limits.max_preauth_packet == 4096
    @test limits.max_auth_rounds == 3
    @test limits.max_auth_bytes == 2048
    @test limits.max_session_state_bytes == 1024
    @test_throws ArgumentError N.ConnectOptions("h", "u"; max_auth_rounds=0)
    @test N.ConnectOptions("h", "u"; can_handle_expired_passwords=true).client_flags & P.CLIENT_CAN_HANDLE_EXPIRED_PASSWORDS != 0
    @test N.ConnectOptions("h", "u"; attrs=["program_name" => "x"]).attrs == ["program_name" => "x"]
    @test any(p -> p.first == "_client_name", N.ConnectOptions("h", "u").attrs)
    @test N.ConnectOptions("::1", "u").host == "::1" && N.hostport("::1", 3306) == "[::1]:3306" && N.hostport("db.example", 1) == "db.example:1"
    timeout = Reseau.HostResolvers.DialTimeoutError("db.example:3306")
    wrapped = Reseau.HostResolvers.OpError("connect", "tcp", nothing, nothing, timeout)
    @test P.is_deadline_error(timeout) && P.is_deadline_error(wrapped)
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
    @test_throws ArgumentError R(; ssl_mode=:preferred, ssl_enforce=true)
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
        # an omitted db/port falls back to the file exactly like host/user/password, both
        # when the kwarg is left out and when it is explicitly nothing (the sentinel the
        # public DBInterface.connect method forwards)
        @test N.ConnectOptions("", ""; db=nothing, port=nothing, option_file=path).db == "app"
        @test N.ConnectOptions("", ""; db=nothing, port=nothing, option_file=path).port == 3307
        @test N.ConnectOptions("", ""; db="explicit", option_file=path).db == "explicit"
        @test o.tls.ca_file == "/etc/ca.pem" && o.tls.mode == P.SSL_VERIFY_CA
        @test o.tls.min_version == Reseau.TLS.TLS1_3_VERSION == o.tls.max_version
        # explicit keywords beat the file; a requested group overrides [client]
        @test N.ConnectOptions("h", "u"; option_file=path, port=1).port == 1
        @test N.ConnectOptions("h", "u"; option_file=path, option_group="extra").port == 3308
        @test N.ConnectOptions("h", "u"; option_file=path, ssl_mode=:disabled).tls.mode == P.SSL_DISABLED
        file_tls = joinpath(dir, "tls.cnf")
        write(file_tls, "[client]\nssl-mode=disabled\n")
        @test N.ConnectOptions("h", "u"; option_file=file_tls).tls.mode == P.SSL_DISABLED
        @test N.ConnectOptions("h", "u"; option_file=file_tls, ssl_enforce=true).tls.mode == P.SSL_REQUIRED
        @test N.ConnectOptions("h", "u"; option_file=file_tls, ssl_verify_server_cert=true).tls.mode == P.SSL_VERIFY_IDENTITY
        write(file_tls, "[client]\nssl-mode=verify_identity\n")
        @test N.ConnectOptions("h", "u"; option_file=file_tls, ssl_enforce=true).tls.mode == P.SSL_VERIFY_IDENTITY
        @test N.read_option_file(path)[:host] == "db.example"
        syntax = joinpath(dir, "syntax.cnf")
        write(syntax, raw"""
        [client]
        host = syntax.example # inline comment
        user = domain\Suser
        password = "pound#value\tend" # comment outside the quotes
        ssl-ca = C:\\new\spath
        """)
        parsed = N.read_option_file(syntax)
        @test parsed[:host] == "syntax.example"
        @test parsed[:user] == "domain\\Suser"
        @test parsed[:password] == "pound#value\tend"
        @test parsed[:ssl_ca] == "C:\\new path"
        unicode = joinpath(dir, "unicode.cnf")
        write(unicode, "[clïent]\nuser=\"Zoë\"\npassword='sëcret'\n")
        parsed = N.read_option_file(unicode; group="clïent")
        @test parsed[:user] == "Zoë"
        @test parsed[:password] == "sëcret"
        reversed = joinpath(dir, "reversed.cnf")
        write(reversed, "[extra]\nport=3308\n[client]\nport=3307\n")
        @test N.ConnectOptions("h", "u"; option_file=reversed, option_group="extra").port == 3308
        inc = joinpath(dir, "inc.cnf")
        write(inc, "!include /etc/other.cnf\n")
        @test_throws ArgumentError N.ConnectOptions("h", "u"; option_file=inc)
        write(inc, "?includedir /etc/mysql/conf.d\n")
        @test_throws ArgumentError N.ConnectOptions("h", "u"; option_file=inc)
        bad = joinpath(dir, "bad.cnf")
        write(bad, "[client\nhost=x\n")
        @test_throws ArgumentError N.ConnectOptions("h", "u"; option_file=bad)
        socket_protocol = joinpath(dir, "socket.cnf")
        write(socket_protocol, "[client]\nprotocol=socket\n")
        @test_throws ArgumentError N.ConnectOptions("h", "u"; option_file=socket_protocol)
        @test N.ConnectOptions("h", "u"; option_file=socket_protocol, protocol=:tcp).host == "h"
        socket_path = joinpath(dir, "socket-path.cnf")
        write(socket_path, "[client]\nhost=localhost\nsocket=/tmp/mysql-option.sock\n")
        if Sys.iswindows()
            @test N.ConnectOptions("", "u"; option_file=socket_path).host == "localhost"
        else
            @test_throws ArgumentError N.ConnectOptions("", "u"; option_file=socket_path)
            @test N.ConnectOptions("", "u"; option_file=socket_path, protocol=:tcp).host == "localhost"
        end
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
    peer_tasks = Task[]
    accept_task = errormonitor(Threads.@spawn begin
        while true
            conn = try
                Reseau.TCP.accept(listener)
            catch
                break   # listener closed
            end
            @lock lock push!(conns, conn)
            task = errormonitor(Threads.@spawn begin
                try
                    plain_peer_connect!(conn; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, after=c -> await_eof(c))
                catch
                finally
                    close(conn)
                end
            end)
            @lock lock push!(peer_tasks, task)
        end
    end)
    try
        return f(port)
    finally
        close(listener)
        wait(accept_task)
        @lock lock foreach(c -> (try; close(c); catch; end), conns)
        tasks = @lock lock copy(peer_tasks)
        foreach(wait, tasks)
    end
end

mutable struct CloseCounterIO <: IO
    @atomic closes::Int
end

Base.isopen(io::CloseCounterIO) = (@atomic io.closes) == 0

function Base.close(io::CloseCounterIO)
    @atomic io.closes += 1
    return nothing
end

function synthetic_reap_entries(n::Int)
    entries = N.ReapEntry[]
    counters = CloseCounterIO[]
    refs = WeakRef[]
    for _ in 1:n
        counter = CloseCounterIO(0)
        transport = P.FaultTransport(counter)
        push!(entries, N.ReapEntry(transport))
        push!(counters, counter)
        push!(refs, WeakRef(transport))
    end
    return entries, counters, refs
end

function finalizer_enqueue_allocations(entry::N.ReapEntry)
    return @allocated N.enqueue_from_finalizer!(entry)
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
    release = Channel{Nothing}(1)
    finished = Channel{Nothing}(1)
    called_with = Channel{Tuple{String, String}}(2)
    block_resolver = Ref(false)
    resolver = function (network, address)
        put!(called_with, (network, address))
        if block_resolver[]
            take!(release)
            put!(finished, nothing)
        end
        return [Reseau.TCP.loopback_addr(0)]
    end
    warm_deadline = Int64(time_ns()) + 5_000_000_000
    @test N.resolve_bind("bind.example", warm_deadline, resolver) == [Reseau.TCP.loopback_addr(0)]
    @test take!(called_with) == ("tcp", "bind.example:0")
    block_resolver[] = true
    before = Int64(time_ns())
    err = try
        N.resolve_bind("bind.example", before + 50_000_000, resolver)
        nothing
    catch ex
        ex
    end
    elapsed = Int64(time_ns()) - before
    @test err isa P.TimeoutError
    @test err isa P.TimeoutError && occursin("resolving bind address", err.msg)
    @test elapsed < 500_000_000
    called = isready(called_with) ? take!(called_with) : nothing
    @test called == ("tcp", "bind.example:0")
    if called !== nothing
        put!(release, nothing)
        finished_status = timedwait(() -> isready(finished), 1.0)
        @test finished_status === :ok
        finished_status === :ok && take!(finished)
    end

    multi_accept_server() do port
        # localhost resolves to IPv6 first on dual-stack hosts. The IPv4 endpoint must still
        # be selected when the remote address is IPv4-only.
        h = native_connect(port; ssl_mode=:disabled, bind="localhost")
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

    # The timer task's world age is fixed at its creation (during an earlier test file's
    # first native connect), which predates this file's `Base.close(::CloseCounterIO)`
    # method: without the reaper's `invokelatest` the timer would swallow the MethodError
    # and mark the entry :closed with the transport never closed. Wait on the timer only —
    # no manual `reap_now!` (which would run in the current world and mask the bug).
    let counter = CloseCounterIO(0)
        entry = N.ReapEntry(P.FaultTransport(counter))
        while (@atomic entry.state) == :live
            N.enqueue_from_finalizer!(entry) || yield()
        end
        deadline = time() + 15
        while (@atomic entry.state) != :closed && time() < deadline
            sleep(0.05)
        end
        @test (@atomic entry.state) == :closed
        @test (@atomic counter.closes) == 1
    end

    # A busy queue lock leaves ownership live so an explicit close can still claim it.
    counter = CloseCounterIO(0)
    entry = N.ReapEntry(P.FaultTransport(counter))
    lock(N.REAPER_LOCK)
    try
        @test !N.enqueue_from_finalizer!(entry)
        @test (@atomic entry.state) == :live
        P.transport_close(N.retire!(entry))
    finally
        unlock(N.REAPER_LOCK)
    end
    @test (@atomic counter.closes) == 1

    # Exercise the finalizer enqueue path concurrently without opening 10,000 sockets.
    entries, counters, refs = synthetic_reap_entries(10_000)
    tasks = Task[]
    for range in Iterators.partition(eachindex(entries), cld(length(entries), Threads.nthreads()))
        push!(tasks, errormonitor(Threads.@spawn begin
            for i in range
                while (@atomic entries[i].state) == :live
                    N.enqueue_from_finalizer!(entries[i]) || yield()
                end
            end
        end))
    end
    foreach(wait, tasks)
    while any(entry -> (@atomic entry.state) != :closed, entries)
        N.reap_now!()
        yield()
    end
    # Exactly-once holds by construction (the :live → :pending CAS gates the single push;
    # :pending → :closing gates the single close). This has failed rarely inside the full
    # suite on Julia 1.12 while a 120-round standalone loop stays clean — the same region
    # as the known non-reproducible 1.12 GC flake — so dump the evidence on any recurrence.
    exactly_once = all(counter -> (@atomic counter.closes) == 1, counters)
    if !exactly_once
        bad = findall(counter -> (@atomic counter.closes) != 1, counters)
        @warn "reaper stress anomaly" nbad=length(bad) closes=[(@atomic counters[i].closes) for i in first(bad, 5)] states=[(@atomic entries[i].state) for i in first(bad, 5)]
    end
    @test exactly_once
    @test all(entry -> entry.transport === nothing, entries)
    @test N.pending_reaps() == 0
    warm = N.ReapEntry(P.FaultTransport(CloseCounterIO(0)))
    @test N.enqueue_from_finalizer!(warm)
    N.reap_now!()
    measured = N.ReapEntry(P.FaultTransport(CloseCounterIO(0)))
    @test finalizer_enqueue_allocations(measured) == 0
    N.reap_now!()
    GC.gc(); GC.gc()
    @test all(ref -> ref.value === nothing, refs)
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
