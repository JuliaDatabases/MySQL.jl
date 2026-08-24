# Performance/allocation gates (plan §8.9) on dedicated mysql:8.4 servers with
# `--max-allowed-packet=128M` (a plain server with `--tls-version=` so plaintext transport
# is testable, and a TLS-capable one).
#
# Gates (asserted, not merely reported):
#   - 1M-row scans decode identically on the text, binary (prepared), and streaming paths,
#     and match a Julia-side reimplementation of the fixture formula
#   - allocations per row ≤ (String/Vector columns + 1) on the native scans
#   - a streaming result > 256 MiB succeeds under default limits; the same result buffered
#     fails with `ProtocolError`; buffered multi-results jointly above `max_buffered_bytes`
#     fail with `ProtocolError`; tiny rows charge their offsets to the budget
#
# Correctness, limit, and allocation gates run inside `Pkg.test` when Docker is available.
# `MYSQL_PERF_GATES=1` additionally runs the timing report (wall-clock throughput printed
# for the record; ratio gates against Connector/C retired with the C backend at 2.0 — use
# `bench/` to compare against MySQL.jl 1.x or other drivers).
module PerfGates

using Test, MySQL, DBInterface, Tables, Chairmarks, Printf, Harbor

const P = MySQL.Protocol
const PERF_ROOT_PW = "native-secret"
const PERF_IMAGE = get(ENV, "MYSQL_PERF_IMAGE", "mysql:8.4")

function perf_port()
    listener = P.Reseau.TCP.listen(P.Reseau.TCP.loopback_addr(0))
    port = Int(P.Reseau.TCP.addr(listener).port)
    close(listener)
    return port
end

# The plain fixture uses caching_sha2_password. Connection setup is outside every timer;
# explicitly request its RSA public-key path when TLS is unavailable.
connect_native(port; kw...) = DBInterface.connect(MySQL.Connection, "127.0.0.1", "root", PERF_ROOT_PW; port=port, db="perf", connect_timeout=10, get_server_public_key=true, kw...)

# ---- consumption: schema-specialized row scan ----

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

function setup_database!(port; ssl_mode::Symbol)
    admin = DBInterface.connect(MySQL.Connection, "127.0.0.1", "root", PERF_ROOT_PW; port=port, connect_timeout=10, ssl_mode=ssl_mode, get_server_public_key=true)
    try
        DBInterface.execute(admin, "CREATE DATABASE IF NOT EXISTS perf")
    finally
        DBInterface.close!(admin)
    end
    return nothing
end

function setup_fixture!(port)
    setup_database!(port; ssl_mode=:disabled)
    conn = connect_native(port; ssl_mode=:disabled)
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

# The `scan` accumulator value of `SELECT i, f, s, n FROM perf1m`, computed Julia-side: any
# decode drift on any of the three read paths diverges from this closed form.
function expected_perf1m()
    acc = 0
    for x in 0:999_999
        acc += x                                    # i
        acc += unsafe_trunc(Int, x * 0.5)           # f
        acc += ncodeunits("name-") + ndigits(x % 1000)  # s
        acc += x % 10                               # n (NULLIF: x%10==0 is missing, adds 0)
    end
    return (1_000_000, acc)
end

function ssl_cipher(conn)
    cols = Tables.columntable(DBInterface.execute(conn, "SHOW SESSION STATUS LIKE 'Ssl_cipher'"))
    name = propertynames(cols)[2]
    return String(first(getproperty(cols, name)))
end

# ---- gate helpers ----

function report!(name::String, native_s::Float64)
    @info @sprintf("§8.9 %-28s native %8.4fs", name, native_s)
    return nothing
end

function alloc_gate!(name::String, allocs::Real, nrows::Int, per_row::Int)
    @info @sprintf("§8.9 %-28s %.3f allocs/row (gate ≤ %d)", name, allocs / nrows, per_row)
    @test allocs <= per_row * nrows + 50_000
    return nothing
end

run_text(conn) = scan(DBInterface.execute(conn, "SELECT i, f, s, n FROM perf1m"))

run_text_streaming(conn) = scan(DBInterface.execute(conn, "SELECT i, f, s, n FROM perf1m"; mysql_store_result=false))

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

run_ping(conn::MySQL.Connection, n::Int) = (for _ in 1:n; MySQL.ping(conn); end; nothing)

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

many_params() = (a=collect(Int64, 1:100_000), b=["value-$(i % 1000)" for i in 1:100_000])

function table_count(conn, table::String)
    return first(Tables.columntable(DBInterface.execute(conn, "SELECT COUNT(*) AS n FROM $table")).n)
end

# These checks run in the Pkg.test process, including under its forced bounds checking.
function run_correctness_gates(plain_port, tls_port)
    native = connect_native(plain_port; ssl_mode=:disabled)
    native_tls = connect_native(tls_port; ssl_mode=:required)
    try
        @testset "transport modes" begin
            @test isempty(ssl_cipher(native))
            @test !isempty(ssl_cipher(native_tls))
        end
        @testset "1M-row scan correctness and allocations" begin
            expected = expected_perf1m()
            @test run_text(native) == expected
            @test run_text_streaming(native) == expected
            bn = @b run_text(native) samples = 1 evals = 1
            alloc_gate!("text scan 1M rows", bn.allocs, 1_000_000, 2)
            stmt_n = DBInterface.prepare(native, "SELECT i, f, s, n FROM perf1m")
            try
                @test run_binary(stmt_n) == expected
                bn = @b run_binary(stmt_n) samples = 1 evals = 1
                alloc_gate!("binary scan 1M rows", bn.allocs, 1_000_000, 2)
            finally
                DBInterface.close!(stmt_n)
            end
            @test run_nulls(native) == (1_000_000, 4_500_000)
            bn = @b run_nulls(native) samples = 1 evals = 1
            alloc_gate!("tiny/NULL scan 1M rows", bn.allocs, 1_000_000, 1)
        end
        @testset "round-trip correctness (plain, TLS)" begin
            @test run_roundtrips(native, 10) == 10
            @test run_roundtrips(native_tls, 10) == 10
        end
        @testset "100k executemany correctness" begin
            DBInterface.execute(native, "CREATE TABLE IF NOT EXISTS many_check_n (a BIGINT, b VARCHAR(24))")
            run_executemany(native, "many_check_n", many_params())
            @test table_count(native, "many_check_n") == 100_000
        end
        @testset "64 MiB blob correctness" begin
            big_n = connect_native(plain_port; ssl_mode=:disabled, max_allowed_packet=128 * 1024 * 1024)
            try
                @test run_blob(big_n) == (1, 67108864)
            finally
                DBInterface.close!(big_n)
            end
        end
        @testset "buffer limits" begin
            small = connect_native(plain_port; ssl_mode=:disabled, max_buffered_bytes=4 * 1024 * 1024)
            try
                # Buffered budgets charge per-row offsets even when row bytes are tiny.
                @test_throws P.ProtocolError run_nulls(small)
            finally
                DBInterface.close!(small)
            end
            # 300 rows of 1 MiB: streaming has no aggregate cap by default.
            stream = connect_native(plain_port; ssl_mode=:disabled)
            try
                sql = "SELECT REPEAT('a', 1048576) AS v FROM seed10 a, seed10 b, seed10 c LIMIT 300"
                nrows, bytes = scan(DBInterface.execute(stream, sql; mysql_store_result=false))
                @test nrows == 300 && bytes == 300 * 1048576
                @test bytes > 256 * 1024 * 1024
                # The same result buffered exceeds the default aggregate budget.
                @test_throws P.ProtocolError DBInterface.execute(stream, sql)
                @test !isopen(stream)
            finally
                DBInterface.close!(stream)
            end
            multi = connect_native(plain_port; ssl_mode=:disabled, multi_statements=true, max_buffered_bytes=3 * 1024 * 1024)
            try
                sql = "SELECT REPEAT('a', 1048576) UNION ALL SELECT REPEAT('b', 1048576); SELECT REPEAT('c', 1048576) UNION ALL SELECT REPEAT('d', 1048576)"
                # Each result is about 2 MiB; together they exceed the shared budget.
                err = try; foreach(identity, DBInterface.executemultiple(multi, sql)); nothing; catch e; e; end
                @test err isa P.ProtocolError
                @test !isopen(multi)
            finally
                DBInterface.close!(multi)
            end
        end
    finally
        DBInterface.close!(native)
        DBInterface.close!(native_tls)
    end
    return nothing
end

# Wall-clock throughput, printed for the record (no ratio asserts since 2.0; see bench/).
function run_timing_gates(plain_port, tls_port)
    native = connect_native(plain_port; ssl_mode=:disabled)
    native_tls = connect_native(tls_port; ssl_mode=:required)
    try
        @testset "timing report" begin
            @test isempty(ssl_cipher(native))
            @test !isempty(ssl_cipher(native_tls))
            bn = @b run_text(native) seconds = 8
            report!("text scan 1M rows", bn.time)
            stmt_n = DBInterface.prepare(native, "SELECT i, f, s, n FROM perf1m")
            try
                bn = @b run_binary(stmt_n) seconds = 8
                report!("binary scan 1M rows", bn.time)
            finally
                DBInterface.close!(stmt_n)
            end
            bn = @b run_nulls(native) seconds = 6
            report!("tiny/NULL scan 1M rows", bn.time)
            bn = @b run_roundtrips(native, 10_000) samples = 3 evals = 1
            report!("10k round trips plain", bn.time)
            bn = @b run_roundtrips(native_tls, 10_000) samples = 3 evals = 1
            report!("10k round trips TLS", bn.time)
            pings = 2_000
            pn = @b run_ping(native, pings) samples = 5 evals = 1
            @info @sprintf("§8.9 %-28s %.1fµs/ping", "COM_PING floor", pn.time / pings * 1e6)
            DBInterface.execute(native, "CREATE TABLE IF NOT EXISTS many_n (a BIGINT, b VARCHAR(24))")
            bn = @b run_executemany(native, "many_n", many_params()) samples = 1 evals = 1
            report!("100k executemany", bn.time)
            @test table_count(native, "many_n") == 100_000
            big_n = connect_native(plain_port; ssl_mode=:disabled, max_allowed_packet=128 * 1024 * 1024)
            try
                bn = @b run_blob(big_n) seconds = 6
                report!("64 MiB blob fetch", bn.time)
            finally
                DBInterface.close!(big_n)
            end
        end
    finally
        DBInterface.close!(native)
        DBInterface.close!(native_tls)
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

function wait_ready(port; ssl_mode::Symbol, timeout=120.0)
    t0 = time()
    last = nothing
    while time() - t0 < timeout
        try
            h = DBInterface.connect(MySQL.Connection, "127.0.0.1", "root", PERF_ROOT_PW; port=port, connect_timeout=3, ssl_mode=ssl_mode, get_server_public_key=true)
            DBInterface.close!(h)
            return nothing
        catch err
            last = err
            sleep(1.0)
        end
    end
    error("perf server did not become ready: $(sprint(showerror, last))")
end

function with_perf_server(f::F, port::Int; tls::Bool) where {F}
    image, tag = image_ref(PERF_IMAGE)
    command = ["--mysql-native-password=ON", "--max-allowed-packet=134217728"]
    tls || push!(command, "--tls-version=")
    env = Dict("MYSQL_ROOT_PASSWORD" => PERF_ROOT_PW, "MARIADB_ROOT_PASSWORD" => PERF_ROOT_PW)
    return Harbor.with_container(image; tag=tag, ports=Dict(3306 => port), environment=env, command=command, wait_strategy=(port=3306,), wait_timeout=180.0) do _
        wait_ready(port; ssl_mode=tls ? :required : :disabled)
        return f()
    end
end

function with_perf_servers(f::F) where {F}
    plain_port = perf_port()
    return with_perf_server(plain_port; tls=false) do
        tls_port = perf_port()
        return with_perf_server(tls_port; tls=true) do
            setup_fixture!(plain_port)
            setup_database!(tls_port; ssl_mode=:required)
            return f(plain_port, tls_port)
        end
    end
end

function runtests()
    with_perf_servers() do plain_port, tls_port
        @testset "performance/allocation gates (§8.9)" begin
            run_correctness_gates(plain_port, tls_port)
            run_timing_gates(plain_port, tls_port)
        end
    end
    return nothing
end

end # module
