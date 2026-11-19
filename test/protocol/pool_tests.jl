# Multiple ordinary wire-protocol connections; no pool-specific factory or reset hooks.
function with_pool_peer(f, handler)
    listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0))
    port = Int(Reseau.TCP.addr(listener).port)
    children = Task[]
    accepted = AcceptedCounter(0)
    server = Threads.@spawn begin
        while true
            c = try
                Reseau.TCP.accept(listener)
            catch
                break
            end
            number = increment!(accepted)
            push!(children, Threads.@spawn try
                handler(c, number)
            finally
                close(c)
            end)
        end
    end
    try
        return f(port, accepted)
    finally
        close(listener)
        wait(server)
        foreach(fetch, children)
    end
end

function pool_peer_session(c; fault=:none, selected=false, reset_entered=nothing, reset_continue=nothing,
        statement_closes=UInt32[])
    reset = false
    next_statement = UInt32(77)
    statements = Set{UInt32}()
    plain_peer_connect!(c; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, after=c -> begin
        while true
            _, cmd, data = try
                read_command(c)
            catch err
                err isa EOFError && break
                rethrow()
            end
            cmd == P.COM_QUIT && break
            if cmd == P.COM_RESET_CONNECTION
                reset = true
                empty!(statements)
                next_statement = UInt32(77)
                if reset_entered !== nothing
                    put!(reset_entered, nothing)
                    take!(reset_continue)
                end
                fault === :disconnect && break
                if fault === :reset || fault === :unsupported
                    send_err(c, 1, fault === :unsupported ? 1047 : 1205, "reset failed")
                elseif fault === :malformed
                    send_packet(c, 1, UInt8[0])
                elseif fault === :more
                    send_ok(c, 1; more=true)
                else
                    send_ok(c, 1)
                end
            elseif cmd == P.COM_INIT_DB
                reset && fault === :database ? send_err(c, 1, 1049, "database failed") : send_ok(c, 1)
            elseif cmd == P.COM_PING
                send_ok(c, 1)
            elseif cmd == P.COM_STMT_PREPARE
                push!(statements, next_statement)
                send_prepare_ok(c, 1, next_statement, P.ColumnDef[], P.ColumnDef[])
                next_statement += UInt32(1)
            elseif cmd == P.COM_STMT_CLOSE || cmd == P.COM_STMT_EXECUTE
                id = UInt32(data[1]) | (UInt32(data[2]) << 8) | (UInt32(data[3]) << 16) | (UInt32(data[4]) << 24)
                if cmd == P.COM_STMT_CLOSE
                    push!(statement_closes, id)
                    delete!(statements, id)
                else
                    id in statements ? send_ok(c, 1; affected=1) : send_err(c, 1, 1243, "unknown statement")
                end
            elseif cmd == P.COM_QUERY
                sql = String(data)
                if reset && ((fault === :charset && sql == "SET NAMES utf8mb4") ||
                             (fault === :init && sql == "SET @configured=41"))
                    send_err(c, 1, 1205, "setup failed")
                elseif sql == "SELECT DATABASE()"
                    row = selected ? vcat(UInt8[5], codeunits("other")) : UInt8[0xfb]
                    send_resultset(c, 1, [coldef("db")], [row])
                elseif sql == "SELECT 7"
                    send_resultset(c, 1, [coldef("n"; type=P.MYSQL_TYPE_LONG)], [UInt8[1, 0x37]])
                elseif sql == "SELECT streamed"
                    send_resultset(c, 1, [coldef("n"; type=P.MYSQL_TYPE_LONG)],
                        [UInt8[1, 0x37], UInt8[1, 0x38], UInt8[1, 0x39]])
                elseif sql == "SELECT broken" || sql == "SELECT unread error"
                    send_packet(c, 1, column_count(1))
                    send_packet(c, 2, coldef("n"; type=P.MYSQL_TYPE_LONG))
                    # A wrong sequence is a transport/protocol drain failure. A well-formed
                    # SQL error is discarded by the driver's existing drain semantics.
                    send_err(c, sql == "SELECT broken" ? 6 : 3, 1205, "late row error")
                elseif sql == "multiple"
                    send_ok(c, 1; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_MORE_RESULTS_EXISTS)
                    send_ok(c, 2)
                else
                    send_ok(c, 1)
                end
            else
                error("unexpected pool command $cmd")
            end
        end
    end)
end

test_pool(port; kw...) = MySQL.ConnectionPool("127.0.0.1", "root", "pw";
    port, ssl_mode=:disabled, connect_timeout=5, read_timeout=5, write_timeout=5, kw...)

pool_throw_callback(_, marker) = throw(marker)

# Notify reports how many callers were actually waiting. Normal notifications make
# them recheck capacity; error delivery is observed in the same operation.
function wait_for_pool_waiters(pool, n; value=nothing, error=false)
    @test timedwait(() -> lock(() -> notify(pool.condition, value; all=true, error) >= n, pool.condition),
        5; pollint=0.001) == :ok
end

@testset "Scoped connection pools" begin
    @test_throws ArgumentError MySQL.ConnectionPool("h", "u"; limit=0)
    @test_throws ArgumentError MySQL.ConnectionPool("h", "u"; limit=-1)
    @test_throws ArgumentError MySQL.ConnectionPool("h", "u"; unknown_option=true)
    lazy = MySQL.ConnectionPool("unused.invalid", "u", "not-for-display"; limit=3)
    @test lazy.total == 0 && isempty(lazy.idle) && isopen(lazy)
    @test !occursin("not-for-display", sprint(show, lazy))
    close(lazy)
    close(lazy)
    @test !isopen(lazy)
    @test_throws InvalidStateException MySQL.with_connection(identity, lazy)

    @testset "Reuse, streamed draining, multiple results and owned output" begin
        with_pool_peer((c, _) -> pool_peer_session(c)) do port, accepted
            pool = test_pool(port; db="app", limit=1, multi_statements=true)
            try
                first_conn = Ref{MySQL.Connection}()
                streamed = Ref{MySQL.TextCursor{false}}()
                generation = Ref(0)
                output = MySQL.with_connection(pool) do conn
                    first_conn[] = conn
                    generation[] = @atomic conn.generation
                    @test !islocked(pool.condition)
                    DBInterface.execute(conn, "SELECT 7")
                end
                @test first(first(output)) == 7
                @test (@atomic first_conn[].generation) > generation[]
                @test (@atomic first_conn[].active_token) == 0
                @test MySQL.with_connection(pool) do conn
                    @test conn === first_conn[]
                    streamed[] = DBInterface.execute(conn, "SELECT streamed"; mysql_store_result=false)
                    first(first(streamed[]))
                end == 7
                @test_throws P.ProtocolError iterate(streamed[])
                @test MySQL.with_connection(pool) do conn
                    DBInterface.execute(conn, "multiple")
                    :complete
                end === :complete
                @test (@atomic accepted.value) == 1
                @test pool.total == 1 && length(pool.idle) == 1
            finally
                close(pool)
            end
            @test pool.total == 0
        end
    end

    @testset "Reset and restoration failures retire, without replay" begin
        for fault in (:reset, :malformed, :more, :disconnect, :database, :charset, :init, :unsupported)
            with_pool_peer((c, _) -> pool_peer_session(c; fault)) do port, accepted
                pool = test_pool(port; db="app", limit=1, init_command="SET @configured=41")
                seen = Ref{MySQL.Connection}()
                calls = Ref(0)
                try
                    result = try
                        MySQL.with_connection(pool) do conn
                            calls[] += 1
                            seen[] = conn
                            31
                        end
                    catch err
                        err
                    end
                    @test fault === :unsupported ? result == 31 : result isa Exception
                    @test calls[] == 1 && (@atomic accepted.value) == 1
                    @test !isopen(seen[]) && pool.total == 0 && isempty(pool.idle)
                finally
                    close(pool)
                end
            end
        end
    end

    @testset "Reset invalidates parked and late statement closes" begin
        closes = UInt32[]
        with_pool_peer((c, _) -> pool_peer_session(c; statement_closes=closes)) do port, _
            pool = test_pool(port; db="app", limit=1)
            old = Ref{MySQL.Statement}()
            try
                MySQL.with_connection(pool) do conn
                    old[] = DBInterface.prepare(conn, "UPDATE old")
                    parked = DBInterface.prepare(conn, "UPDATE parked")
                    DBInterface.close!(parked)
                    @test conn.stmts_to_close === parked.reap
                end
                MySQL.with_connection(pool) do conn
                    @test conn.stmts_to_close === nothing
                    current = DBInterface.prepare(conn, "UPDATE current")
                    @test old[].statement_id == current.statement_id == 77
                    @test old[].generation < current.generation
                    DBInterface.close!(old[])
                    @test DBInterface.execute(current).rows_affected == 1
                    @test isempty(closes)
                    DBInterface.close!(current)
                    @test MySQL.ping(conn)
                    @test closes == UInt32[77]
                end
            finally
                isassigned(old) && DBInterface.close!(old[])
                close(pool)
            end
        end
    end

    @testset "Pending protocol faults retire; abandoned SQL errors drain" begin
        with_pool_peer((c, _) -> pool_peer_session(c)) do port, accepted
            pool = test_pool(port; db="app", limit=1)
            calls = Ref(0)
            try
                result = try
                    MySQL.with_connection(pool) do conn
                        calls[] += 1
                        DBInterface.execute(conn, "SELECT broken"; mysql_store_result=false)
                        :finished
                    end
                catch err
                    err
                end
                @test result isa P.ProtocolError
                @test calls[] == 1 && pool.total == 0
                @test MySQL.with_connection(MySQL.ping, pool)
                @test (@atomic accepted.value) == 2
                @test MySQL.with_connection(pool) do conn
                    DBInterface.execute(conn, "SELECT unread error"; mysql_store_result=false)
                    :discarded
                end === :discarded
                @test pool.total == 1 && (@atomic accepted.value) == 2
            finally
                close(pool)
            end
        end
    end

    @testset "Database-less sessions retire only when a database is selected" begin
        for selected in (false, true)
            with_pool_peer((c, _) -> pool_peer_session(c; selected)) do port, accepted
                pool = test_pool(port; limit=1)
                try
                    for _ in 1:2
                        @test MySQL.with_connection(_ -> 11, pool) == 11
                    end
                    @test (@atomic accepted.value) == (selected ? 2 : 1)
                    @test pool.total == (selected ? 0 : 1)
                finally
                    close(pool)
                end
            end
        end
    end

    @testset "Callback errors, explicit connection close and failed creation" begin
        for marker in (ErrorException("callback"), InterruptException())
            with_pool_peer((c, _) -> pool_peer_session(c; fault=:reset)) do port, _
                pool = test_pool(port; db="app", limit=1)
                seen = Ref{MySQL.Connection}()
                backtrace = Ref{Any}()
                result = try
                    MySQL.with_connection(pool) do conn
                        seen[] = conn
                        pool_throw_callback(conn, marker)
                    end
                catch err
                    backtrace[] = catch_backtrace()
                    err
                end
                @test result === marker
                @test any(frame -> frame.func === :pool_throw_callback, stacktrace(backtrace[]))
                @test !isopen(seen[]) && pool.total == 0
                close(pool)
            end
        end
        with_pool_peer((c, n) -> n == 1 ? send_err(c, 0, 1045, "login failed") : pool_peer_session(c)) do port, accepted
            pool = test_pool(port; db="app", limit=1)
            try
                @test_throws P.Error MySQL.with_connection(identity, pool)
                @test pool.total == 0
                @test MySQL.with_connection(pool) do conn
                    close(conn)
                    12
                end == 12
                @test pool.total == 0
                @test MySQL.with_connection(_ -> 13, pool) == 13
                @test (@atomic accepted.value) == 3
            finally
                close(pool)
            end
        end
        with_pool_peer((c, _) -> pool_peer_session(c)) do port, accepted
            pool = test_pool(port; db="app", limit=1)
            conn = MySQL.with_connection(identity, pool)
            # Defensively reject an idle transport already known to be closed.
            close(conn)
            replacement = MySQL.with_connection(identity, pool)
            @test replacement !== conn && pool.total == 1
            @test (@atomic accepted.value) == 2
            @test MySQL.with_connection(pool) do borrowed
                close(pool)
                @test pool.total == 1
                MySQL.ping(borrowed)
            end
            @test pool.total == 0 && !isopen(replacement)
        end
    end

    @testset "Exclusive capacity and shutdown" begin
        with_pool_peer((c, _) -> pool_peer_session(c)) do port, accepted
            pool = test_pool(port; db="app", limit=2)
            entered, leave = Channel{MySQL.Connection}(4), Channel{Nothing}(4)
            tasks = [Threads.@spawn MySQL.with_connection(pool) do conn
                put!(entered, conn)
                take!(leave)
                MySQL.ping(conn)
            end for _ in 1:4]
            try
                a, b = take!(entered), take!(entered)
                @test a !== b
                wait_for_pool_waiters(pool, 2)
                @test pool.total == 2 && (@atomic accepted.value) == 2
                put!(leave, nothing)
                c = take!(entered)
                @test c === a || c === b
                put!(leave, nothing)
                d = take!(entered)
                @test d === a || d === b
                put!(leave, nothing)
                put!(leave, nothing)
                @test all(fetch, tasks)
                @test length(pool.idle) == 2 && pool.total == 2
            finally
                close(pool)
            end
            @test pool.total == 0
        end
        with_pool_peer((c, _) -> pool_peer_session(c)) do port, accepted
            pool = test_pool(port; db="app", limit=1)
            entered, leave = Channel{Nothing}(1), Channel{Nothing}(1)
            holder = Threads.@spawn MySQL.with_connection(pool) do conn
                put!(entered, nothing)
                take!(leave)
                MySQL.ping(conn)
            end
            take!(entered)
            waiter = Threads.@spawn try
                MySQL.with_connection(_ -> error("closed lease entered"), pool)
            catch err
                err
            end
            wait_for_pool_waiters(pool, 1)
            close(pool)
            @test fetch(waiter) isa InvalidStateException
            @test pool.total == 1 && !isopen(pool)
            put!(leave, nothing)
            @test fetch(holder)
            @test pool.total == 0 && (@atomic accepted.value) == 1
        end
    end

    @testset "Close during creation or reset" begin
        for phase in (:creation, :reset)
            entered, proceed = Channel{Nothing}(1), Channel{Nothing}(1)
            handler = (c, _) -> begin
                if phase === :creation
                    put!(entered, nothing)
                    take!(proceed)
                    pool_peer_session(c)
                else
                    pool_peer_session(c; reset_entered=entered, reset_continue=proceed)
                end
            end
            with_pool_peer(handler) do port, _
                pool = test_pool(port; db="app", limit=1)
                called = Ref(false)
                work = Threads.@spawn try
                    MySQL.with_connection(pool) do _
                        called[] = true
                        29
                    end
                catch err
                    err
                end
                take!(entered)
                @test !islocked(pool.condition)
                close(pool)
                @test pool.total == 1
                put!(proceed, nothing)
                result = fetch(work)
                @test phase === :creation ? result isa InvalidStateException : result == 29
                @test called[] == (phase === :reset)
                @test pool.total == 0 && isempty(pool.idle)
            end
        end
    end

    @testset "Cooperative interrupted waiter leaves capacity intact" begin
        with_pool_peer((c, _) -> pool_peer_session(c)) do port, accepted
            pool = test_pool(port; db="app", limit=1)
            entered, leave = Channel{Nothing}(1), Channel{Nothing}(1)
            holder = Threads.@spawn MySQL.with_connection(pool) do conn
                put!(entered, nothing)
                take!(leave)
                MySQL.ping(conn)
            end
            take!(entered)
            called = Ref(false)
            waiter = Threads.@spawn try
                MySQL.with_connection(pool) do _
                    called[] = true
                end
            catch err
                err
            end
            try
                marker = InterruptException()
                wait_for_pool_waiters(pool, 1; value=marker, error=true)
                @test fetch(waiter) === marker
                @test !called[] && pool.total == 1 && isempty(pool.idle)
                put!(leave, nothing)
                @test fetch(holder)
                @test MySQL.with_connection(MySQL.ping, pool)
                @test pool.total == 1 && (@atomic accepted.value) == 1
            finally
                close(pool)
            end
        end
    end

    @testset "Retirement retains capacity and releases the bookkeeping lock" begin
        with_pool_peer((c, _) -> pool_peer_session(c)) do port, _
            pool = test_pool(port; db="app", limit=1)
            conn = MySQL.with_connection(identity, pool)
            locked, release = Channel{Nothing}(1), Channel{Nothing}(1)
            locker = Threads.@spawn lock(conn.lock) do
                put!(locked, nothing)
                take!(release)
            end
            take!(locked)
            closing = Threads.@spawn close(pool)
            @test timedwait(() -> !isopen(pool), 5; pollint=0.001) == :ok
            @test pool.total == 1 && !istaskdone(closing)
            @test !islocked(pool.condition)
            put!(release, nothing)
            fetch(locker)
            fetch(closing)
            @test pool.total == 0 && !isopen(conn)
        end
    end
end
