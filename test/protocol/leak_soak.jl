# Leak/lifecycle soak against a live server (plan §8.10): abandon statements, cursors and
# connections in bulk under multi-threaded GC pressure and assert that nothing leaks —
# finalizers only park (no transport I/O), the next command reaps, server-side
# `Prepared_stmt_count`/`Threads_connected` return to baseline, the reaper queue and the
# statement reap queues drain to empty, weak references clear, fds and RSS stay stable, a
# late statement finalizer never disturbs the active cursor, and a read deadline closes the
# connection deterministically.

mutable struct SoakFlag
    @atomic stop::Bool
end

function soak_connect(port; kw...)
    return DBInterface.connect(N.Connection, "127.0.0.1", "root", ROOT_PW; port=port, connect_timeout=10, kw...)
end

function global_status(conn, name)
    tbl = Tables.columntable(DBInterface.execute(conn, "SHOW GLOBAL STATUS LIKE '$name'"))
    return parse(Int, String(tbl.Value[1]))
end

current_rss_kb() = parse(Int, strip(read(`ps -o rss= -p $(getpid())`, String)))

fd_count() = Sys.iswindows() ? 0 : length(readdir("/dev/fd"))

# Waits (bounded) for `f()` to become true across GC/finalizer/reaper/server delays.
function soak_wait(f::Function; attempts::Int=60)
    for _ in 1:attempts
        f() && return true
        GC.gc()
        N.reap_now!()
        sleep(0.25)
    end
    return f()
end

# Function boundaries so abandoned wrappers are not kept alive by stack slots.
@noinline function abandon_statements!(conn, n::Int)
    for i in 1:n
        DBInterface.prepare(conn, "SELECT $i")
    end
    return nothing
end

@noinline function abandon_buffered_cursors!(conn, n::Int)
    refs = WeakRef[]
    sizehint!(refs, n)
    for _ in 1:n
        cursor = DBInterface.execute(conn, "SELECT 1")
        push!(refs, WeakRef(cursor))
    end
    return refs
end

@noinline function abandon_streaming_cursors!(conn, n::Int)
    refs = WeakRef[]
    sizehint!(refs, n)
    for _ in 1:n
        cursor = DBInterface.execute(conn, "SELECT 1 UNION ALL SELECT 2"; mysql_store_result=false)
        iterate(cursor)   # abandon mid-result; the next command drains
        push!(refs, WeakRef(cursor))
    end
    return refs
end

@noinline function abandon_connections!(port, n::Int)
    refs = WeakRef[]
    for _ in 1:n
        h = soak_connect(port)
        push!(refs, WeakRef(h.handle))
        DBInterface.execute(h, "SELECT 1")
    end
    return refs
end

function has_parked_statement(conn)
    lock(conn.reaplock)
    try
        return conn.stmts_to_close !== nothing
    finally
        unlock(conn.reaplock)
    end
end

@noinline function abandon_statement_during_stream!(conn)
    stmt = DBInterface.prepare(conn, "SELECT 99")
    ref = WeakRef(stmt)
    cursor = nothing
    first_value = 0
    GC.@preserve stmt begin
        cursor = DBInterface.execute(conn, "SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3"; mysql_store_result=false)
        item = iterate(cursor)
        item === nothing && error("stream ended before its first row")
        row, _ = item
        first_value = row[1]
    end
    return cursor, first_value, ref
end

function run_leak_soak(port)
    @testset "leak/lifecycle soak (§8.10)" begin
        monitor = soak_connect(port)
        try
            GC.gc(); GC.gc()
            N.reap_now!()
            rss_baseline = current_rss_kb()
            fd_baseline = fd_count()
            stmt_baseline = global_status(monitor, "Prepared_stmt_count")
            # -- deterministic: finalizers only park; one command reaps --
            conn = soak_connect(port)
            stmts = [DBInterface.prepare(conn, "SELECT $i") for i in 1:1000]
            count_full = global_status(monitor, "Prepared_stmt_count")
            @test count_full >= stmt_baseline + 1000
            empty!(stmts)
            stmts = nothing
            GC.gc(); GC.gc()
            # the finalizers may only have parked the ids: without a command on `conn` the
            # server-side count cannot move (no COM_STMT_CLOSE from GC)
            @test global_status(monitor, "Prepared_stmt_count") == count_full
            @test soak_wait() do
                DBInterface.execute(conn, "SELECT 1")
                global_status(monitor, "Prepared_stmt_count") == stmt_baseline
            end
            DBInterface.close!(conn)
            # -- 10k statements abandoned across tasks under multi-threaded GC thrash --
            gc_flag = SoakFlag(false)
            gc_task = errormonitor(Threads.@spawn while !(@atomic gc_flag.stop)
                GC.gc(false)
                yield()
            end)
            conns = [soak_connect(port) for _ in 1:4]
            try
                @sync for c in conns
                    errormonitor(Threads.@spawn abandon_statements!(c, 2500))
                end
                @test soak_wait() do
                    foreach(c -> DBInterface.execute(c, "SELECT 1"), conns)
                    all(c -> c.stmts_to_close === nothing, conns) &&
                        global_status(monitor, "Prepared_stmt_count") == stmt_baseline
                end
                # -- 10k cursors abandoned (buffered, and streaming abandoned mid-result) --
                cursor_refs = Vector{Vector{WeakRef}}(undef, length(conns))
                @sync for (i, c) in enumerate(conns)
                    errormonitor(Threads.@spawn begin
                        cursor_refs[i] = isodd(i) ?
                            abandon_buffered_cursors!(c, 2500) :
                            abandon_streaming_cursors!(c, 2500)
                        return nothing
                    end)
                end
                for c in conns
                    @test Tables.columntable(DBInterface.execute(c, "SELECT 42 AS x")).x == [42]
                end
                @test soak_wait(() -> all(r -> r.value === nothing, Iterators.flatten(cursor_refs)))
                foreach(DBInterface.close!, conns)
            finally
                @atomic gc_flag.stop = true
                wait(gc_task)
            end
            # -- abandoned connections: reaped exactly once, server count returns --
            threads_baseline = global_status(monitor, "Threads_connected")
            refs = abandon_connections!(port, 100)
            @test soak_wait(() -> global_status(monitor, "Threads_connected") <= threads_baseline)
            @test N.pending_reaps() == 0
            GC.gc(); GC.gc()
            @test soak_wait(() -> all(r -> r.value === nothing, refs))
            # -- a late statement finalizer must not disturb the active streaming cursor --
            conn = soak_connect(port)
            late_baseline = global_status(monitor, "Prepared_stmt_count")
            cursor, first_value, stmt_ref = abandon_statement_during_stream!(conn)
            @test global_status(monitor, "Prepared_stmt_count") == late_baseline + 1
            # The helper preserves the statement through the first row. It becomes
            # unreachable only after the streaming cursor is active.
            @test soak_wait(() -> stmt_ref.value === nothing && has_parked_statement(conn))
            # The finalizer parked the id. It did not send COM_STMT_CLOSE under the cursor.
            @test global_status(monitor, "Prepared_stmt_count") == late_baseline + 1
            rows = Int[first_value]
            for row in cursor
                GC.gc()
                push!(rows, row[1])
            end
            @test rows == [1, 2, 3]
            @test soak_wait() do
                DBInterface.execute(conn, "SELECT 1")
                global_status(monitor, "Prepared_stmt_count") == late_baseline
            end
            DBInterface.close!(conn)
            # -- a read deadline closes the connection deterministically --
            conn = soak_connect(port; read_timeout=1)
            started = time_ns()
            @test_throws P.TimeoutError DBInterface.execute(conn, "SELECT SLEEP(5)")
            @test time_ns() - started < 4_000_000_000
            @test !isopen(conn)
            err = try; DBInterface.execute(conn, "SELECT 1"); nothing; catch e; e; end
            @test err isa P.Error && err.errno == P.CR_SERVER_GONE_ERROR
            DBInterface.close!(conn)
            # -- stability: reaper drained, no fd growth, RSS bounded --
            GC.gc(); GC.gc()
            N.reap_now!()
            @test N.pending_reaps() == 0
            Sys.iswindows() || @test fd_count() <= fd_baseline + 8
            @test current_rss_kb() - rss_baseline < 256 * 1024   # < 256 MiB growth over the whole soak
        finally
            DBInterface.close!(monitor)
        end
    end
    return nothing
end
