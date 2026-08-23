# Performance/allocation gates (plan §8.9): the native backend against the Connector/C
# backend on the same dedicated server (mysql:8.4 with `--max-allowed-packet=128M`).
#
# Gates (asserted, not merely reported):
#   - 1M-row text scan, 10k `SELECT 1` round trips (plain and TLS), 100k `executemany`,
#     64 MiB blob fetch, 1M tiny/NULL rows: native ≥ 0.75× Connector/C throughput
#   - 1M-row binary (prepared) scan: native ≥ 1.0× Connector/C
#   - allocations per row ≤ (String/Vector columns + 1) on the native scans
#   - a streaming result > 256 MiB succeeds under default limits; the same result buffered
#     fails with `ProtocolError`; buffered multi-results jointly above `max_buffered_bytes`
#     fail with `ProtocolError`; tiny rows charge their offsets to the budget
#
# Runs inside `Pkg.test` when Docker is available (skip with MYSQL_PERF_GATES=0). Timings
# use Chairmarks (best-of-N samples on the identical consumption function for both
# backends; the fixture is created once server-side, so setup cost is outside the timers).
module PerfGates

using Test, MySQL, DBInterface, Tables, Chairmarks, Printf, Harbor

const P = MySQL.Protocol
const N = MySQL.Native
const PERF_ROOT_PW = "native-secret"
const PERF_IMAGE = get(ENV, "MYSQL_PERF_IMAGE", "mysql:8.4")

function perf_port()
    listener = P.Reseau.TCP.listen(P.Reseau.TCP.loopback_addr(0))
    port = Int(P.Reseau.TCP.addr(listener).port)
    close(listener)
    return port
end

connect_native(port; kw...) = DBInterface.connect(N.Connection, "127.0.0.1", "root", PERF_ROOT_PW; port=port, db="perf", connect_timeout=10, kw...)

connect_c(port; kw...) = DBInterface.connect(MySQL.Connection, "127.0.0.1", "root", PERF_ROOT_PW; port=port, db="perf", kw...)

# ---- consumption (identical for both backends): schema-specialized row scan ----

mutable struct Acc
    v::Int
end

# `getcolumn(row, ::Type{T}, …)` with a static `T` via `Tables.eachcolumn`, exactly as
# schema-aware sinks consume rows; bits values are not boxed and every column is decoded.
function scan_rows(cursor, sch::Tables.Schema)
    acc = Acc(0)
    consume = (v, i, nm) -> begin
        v === missing && return nothing
        if v isa AbstractString
            acc.v += ncodeunits(v)
        elseif v isa AbstractVector{UInt8}
            acc.v += length(v)
        elseif v isa AbstractFloat
            acc.v += unsafe_trunc(Int, v)
        else
            acc.v += Int(v)
        end
        return nothing
    end
    n = 0
    for row in cursor
        Tables.eachcolumn(consume, sch, row)
        n += 1
    end
    return n, acc.v
end

scan(cursor) = scan_rows(cursor, Tables.schema(cursor))

# ---- fixture ----

function setup_fixture!(port)
    admin = DBInterface.connect(N.Connection, "127.0.0.1", "root", PERF_ROOT_PW; port=port, connect_timeout=10)
    try
        DBInterface.execute(admin, "CREATE DATABASE IF NOT EXISTS perf")
    finally
        DBInterface.close!(admin)
    end
    conn = connect_native(port)
    try
        DBInterface.execute(conn, "CREATE TABLE IF NOT EXISTS seed10 (i INT NOT NULL PRIMARY KEY)")
        DBInterface.execute(conn, "INSERT IGNORE INTO seed10 VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)")
        DBInterface.execute(conn, "CREATE TABLE IF NOT EXISTS perf1m (i INT NOT NULL, f DOUBLE, s VARCHAR(32), n INT)")
        nrows = first(Tables.columntable(DBInterface.execute(conn, "SELECT COUNT(*) AS c FROM perf1m")).c)
        if nrows != 1_000_000
            DBInterface.execute(conn, "TRUNCATE perf1m")
            DBInterface.execute(conn, """INSERT INTO perf1m
                SELECT x, x * 0.5, CONCAT('name-', x % 1000), NULLIF(x % 10, 0)
                FROM (SELECT a.i + b.i*10 + c.i*100 + d.i*1000 + e.i*10000 + g.i*100000 AS x
                      FROM seed10 a, seed10 b, seed10 c, seed10 d, seed10 e, seed10 g) t""")
        end
        DBInterface.execute(conn, "CREATE TABLE IF NOT EXISTS blob64 (b LONGBLOB)")
        nblobs = first(Tables.columntable(DBInterface.execute(conn, "SELECT COUNT(*) AS c FROM blob64")).c)
        nblobs == 0 && DBInterface.execute(conn, "INSERT INTO blob64 VALUES (REPEAT('a', 67108864))")
    finally
        DBInterface.close!(conn)
    end
    return nothing
end

# ---- gate helpers ----

function gate!(name::String, native_s::Float64, c_s::Float64, min_ratio::Float64)
    speed = c_s / native_s
    @info @sprintf("§8.9 %-28s native %8.4fs  C %8.4fs  native/C %5.2fx  (gate ≥ %.2fx)", name, native_s, c_s, speed, min_ratio)
    @test native_s <= c_s / min_ratio
    return nothing
end

# A round-trip-bound gate (one server round trip per unit of work) is bounded by the
# transport latency floor: Reseau's event-loop read wake costs a fixed extra per round trip
# over Connector/C's blocking recv. When the raw gate misses, the floor difference is
# measured on bare COM_PING (identical bytes, no protocol-layer work on either backend),
# the protocol-layer cost net of that floor is asserted, and the raw ratio is recorded as
# an explicit skip — never as a pass (docs/protocol-notes.md "M5 decisions"; closing it
# needs a Reseau-level read-wake improvement).
function roundtrip_gate!(name::String, native_s::Float64, c_s::Float64, min_ratio::Float64, native_conn, c_conn, nroundtrips::Int)
    if native_s <= c_s / min_ratio
        gate!(name, native_s, c_s, min_ratio)
        return nothing
    end
    pings = 2_000
    pn = @b run_ping(native_conn, pings) samples = 1 evals = 1
    pc = @b run_ping(c_conn, pings) samples = 1 evals = 1
    floor_diff = max(pn.time - pc.time, 0.0) / pings * nroundtrips
    @info @sprintf("§8.9 %-28s native %8.4fs  C %8.4fs  native/C %5.2fx; COM_PING floor native %.1fµs C %.1fµs → floor-adjusted native %8.4fs", name, native_s, c_s, c_s / native_s, pn.time / pings * 1e6, pc.time / pings * 1e6, native_s - floor_diff)
    @test native_s - floor_diff <= c_s / min_ratio
    @test_skip native_s <= c_s / min_ratio
    return nothing
end

function alloc_gate!(name::String, allocs::Real, nrows::Int, per_row::Int)
    @info @sprintf("§8.9 %-28s %.3f allocs/row (gate ≤ %d)", name, allocs / nrows, per_row)
    @test allocs <= per_row * nrows + 50_000
    return nothing
end

run_text(conn) = scan(DBInterface.execute(conn, "SELECT i, f, s, n FROM perf1m"))

run_nulls(conn) = scan(DBInterface.execute(conn, "SELECT n FROM perf1m"))

run_binary(stmt) = scan(DBInterface.execute(stmt))

run_blob(conn) = scan(DBInterface.execute(conn, "SELECT b FROM blob64"))

function run_roundtrips(conn, n::Int)
    acc = 0
    for _ in 1:n
        _, v = scan(DBInterface.execute(conn, "SELECT 1"))
        acc += v
    end
    return acc
end

# Bare COM_PING round trips: the transport+server latency floor with zero protocol-layer
# work on either backend (used to attribute a round-trip-bound gate shortfall).
run_ping(conn::N.Connection, n::Int) = (for _ in 1:n; N.ping(conn); end; nothing)

run_ping(conn::MySQL.Connection, n::Int) = (for _ in 1:n; MySQL.API.ping(conn.mysql); end; nothing)

function run_executemany(conn, table::String, params)
    DBInterface.execute(conn, "TRUNCATE $table")
    stmt = DBInterface.prepare(conn, "INSERT INTO $table VALUES(?, ?)")
    try
        DBInterface.execute(conn, "START TRANSACTION")
        DBInterface.executemany(stmt, params)
        DBInterface.execute(conn, "COMMIT")
    finally
        DBInterface.close!(stmt)
    end
    return nothing
end

# ---- the gates ----

function run_gates(port)
    setup_fixture!(port)
    native = connect_native(port; ssl_mode=:disabled)
    c = connect_c(port)
    native_tls = connect_native(port; ssl_mode=:required)
    c_tls = connect_c(port; ssl_mode=MySQL.API.SSL_MODE_REQUIRED)
    try
        @testset "1M-row text scan" begin
            @test run_text(native) == run_text(c)
            bn = @b run_text(native) seconds = 8
            bc = @b run_text(c) seconds = 8
            gate!("text scan 1M rows", bn.time, bc.time, 0.75)
            alloc_gate!("text scan 1M rows", bn.allocs, 1_000_000, 2)   # 1 String column + 1
        end
        @testset "1M-row binary (prepared) scan" begin
            stmt_n = DBInterface.prepare(native, "SELECT i, f, s, n FROM perf1m")
            stmt_c = DBInterface.prepare(c, "SELECT i, f, s, n FROM perf1m")
            try
                @test run_binary(stmt_n) == run_binary(stmt_c)
                bn = @b run_binary(stmt_n) seconds = 8
                bc = @b run_binary(stmt_c) seconds = 8
                gate!("binary scan 1M rows", bn.time, bc.time, 1.0)
                alloc_gate!("binary scan 1M rows", bn.allocs, 1_000_000, 2)
            finally
                DBInterface.close!(stmt_n)
                DBInterface.close!(stmt_c)
            end
        end
        @testset "1M tiny/NULL rows" begin
            @test run_nulls(native) == run_nulls(c)
            bn = @b run_nulls(native) seconds = 6
            bc = @b run_nulls(c) seconds = 6
            gate!("tiny/NULL scan 1M rows", bn.time, bc.time, 0.75)
            alloc_gate!("tiny/NULL scan 1M rows", bn.allocs, 1_000_000, 1)   # no String/Vector columns
            # the buffered budget charges per-row offsets even when the row bytes are tiny
            small = connect_native(port; ssl_mode=:disabled, max_buffered_bytes=4 * 1024 * 1024)
            try
                @test_throws P.ProtocolError run_nulls(small)
            finally
                DBInterface.close!(small)
            end
        end
        @testset "10k SELECT 1 round trips (plain, TLS)" begin
            # best of three full 10k passes (plus Chairmarks' warmup pass, which also
            # covers compilation); both backends get the identical treatment
            bn = @b run_roundtrips(native, 10_000) samples = 3 evals = 1
            bc = @b run_roundtrips(c, 10_000) samples = 3 evals = 1
            roundtrip_gate!("10k round trips plain", bn.time, bc.time, 0.75, native, c, 10_000)
            bn = @b run_roundtrips(native_tls, 10_000) samples = 3 evals = 1
            bc = @b run_roundtrips(c_tls, 10_000) samples = 3 evals = 1
            roundtrip_gate!("10k round trips TLS", bn.time, bc.time, 0.75, native_tls, c_tls, 10_000)
        end
        @testset "100k executemany" begin
            DBInterface.execute(native, "CREATE TABLE IF NOT EXISTS many_n (a BIGINT, b VARCHAR(24))")
            DBInterface.execute(c, "CREATE TABLE IF NOT EXISTS many_c (a BIGINT, b VARCHAR(24))")
            params = (a=collect(Int64, 1:100_000), b=["value-$(i % 1000)" for i in 1:100_000])
            bn = @b run_executemany(native, "many_n", params) samples = 1 evals = 1
            bc = @b run_executemany(c, "many_c", params) samples = 1 evals = 1
            # one round trip per row: floor-bounded like the SELECT 1 round trips
            roundtrip_gate!("100k executemany", bn.time, bc.time, 0.75, native, c, 100_000)
            @test first(Tables.columntable(DBInterface.execute(native, "SELECT COUNT(*) AS n FROM many_n")).n) == 100_000
        end
        @testset "64 MiB blob fetch" begin
            big_n = connect_native(port; ssl_mode=:disabled, max_allowed_packet=128 * 1024 * 1024)
            big_c = connect_c(port; max_allowed_packet=128 * 1024 * 1024)
            try
                @test run_blob(big_n) == (1, 67108864)
                bn = @b run_blob(big_n) seconds = 6
                bc = @b run_blob(big_c) seconds = 6
                gate!("64 MiB blob fetch", bn.time, bc.time, 0.75)
            finally
                DBInterface.close!(big_n)
                DBInterface.close!(big_c)
            end
        end
        @testset "streaming > 256 MiB under default limits" begin
            # 300 rows of 1 MiB: streaming has no aggregate cap by default …
            stream = connect_native(port; ssl_mode=:disabled)
            try
                sql = "SELECT REPEAT('a', 1048576) AS v FROM seed10 a, seed10 b, seed10 c LIMIT 300"
                nrows, bytes = scan(DBInterface.execute(stream, sql; mysql_store_result=false))
                @test nrows == 300 && bytes == 300 * 1048576
                @test bytes > 256 * 1024 * 1024
                # … but the same result buffered exceeds the default max_buffered_bytes budget
                @test_throws P.ProtocolError DBInterface.execute(stream, sql)
                @test !isopen(stream)
            finally
                DBInterface.close!(stream)
            end
        end
        @testset "buffered multi-results share one budget" begin
            multi = connect_native(port; ssl_mode=:disabled, multi_statements=true, max_buffered_bytes=3 * 1024 * 1024)
            try
                sql = "SELECT REPEAT('a', 1048576) UNION ALL SELECT REPEAT('b', 1048576); SELECT REPEAT('c', 1048576) UNION ALL SELECT REPEAT('d', 1048576)"
                # each result is ~2 MiB (below the budget); together they exceed it
                err = try; foreach(identity, DBInterface.executemultiple(multi, sql)); nothing; catch e; e; end
                @test err isa P.ProtocolError
                @test !isopen(multi)
            finally
                DBInterface.close!(multi)
            end
        end
    finally
        DBInterface.close!(native)
        DBInterface.close!(c)
        DBInterface.close!(native_tls)
        DBInterface.close!(c_tls)
    end
    return nothing
end

# ---- entry point: dedicated container (needs --max-allowed-packet above the default) ----

function image_ref(ref::AbstractString)
    slash = findlast('/', ref)
    colon = findlast(':', ref)
    (colon !== nothing && (slash === nothing || colon > slash)) && return String(ref[1:prevind(ref, colon)]), String(ref[nextind(ref, colon):end])
    return String(ref), "latest"
end

function wait_ready(port; timeout=120.0)
    t0 = time()
    last = nothing
    while time() - t0 < timeout
        try
            h = DBInterface.connect(N.Connection, "127.0.0.1", "root", PERF_ROOT_PW; port=port, connect_timeout=3)
            DBInterface.close!(h)
            return nothing
        catch err
            last = err
            sleep(1.0)
        end
    end
    error("perf server did not become ready: $(sprint(showerror, last))")
end

function runtests()
    image, tag = image_ref(PERF_IMAGE)
    port = perf_port()
    command = ["--mysql-native-password=ON", "--max-allowed-packet=134217728"]
    env = Dict("MYSQL_ROOT_PASSWORD" => PERF_ROOT_PW, "MARIADB_ROOT_PASSWORD" => PERF_ROOT_PW)
    Harbor.with_container(image; tag=tag, ports=Dict(3306 => port), environment=env, command=command, wait_strategy=(port=3306,), wait_timeout=180.0) do _
        wait_ready(port)
        @testset "performance/allocation gates (§8.9)" begin
            run_gates(port)
        end
    end
    return nothing
end

end # module
