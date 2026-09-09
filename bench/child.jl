# One benchmark pass against an already-running perf fixture (see bench/run.jl), using
# whatever MySQL.jl version is in the active project — the 2.0 native client or a 1.x
# Connector/C client. Prints `name<TAB>seconds` lines for the parent to collect.
#
# usage: julia --project=<env> bench/child.jl <plain-port> <label>

using MySQL, DBInterface, Tables, Chairmarks, Printf

const NATIVE = isdefined(MySQL, :Protocol)
const PORT = parse(Int, ARGS[1])
const LABEL = ARGS[2]
const PW = "native-secret"

function connect_bench(; kw...)
    if NATIVE
        return DBInterface.connect(MySQL.Connection, "127.0.0.1", "root", PW; port=PORT, db="perf", connect_timeout=10, ssl_mode=:disabled, get_server_public_key=true, kw...)
    end
    return DBInterface.connect(MySQL.Connection, "127.0.0.1", "root", PW; port=PORT, db="perf", kw...)
end

mutable struct Acc
    v::Int
end

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

report(name, seconds) = @printf("RESULT\t%s\t%s\t%.6f\n", LABEL, name, seconds)

function main()
    conn = connect_bench()
    try
        b = @b run_text(conn) seconds = 8
        report("text scan 1M rows", b.time)
        stmt = DBInterface.prepare(conn, "SELECT i, f, s, n FROM perf1m")
        try
            b = @b run_binary(stmt) seconds = 8
            report("binary scan 1M rows", b.time)
        finally
            DBInterface.close!(stmt)
        end
        b = @b run_nulls(conn) seconds = 6
        report("tiny/NULL scan 1M rows", b.time)
        b = @b run_roundtrips(conn, 10_000) samples = 3 evals = 1
        report("10k round trips", b.time)
        DBInterface.execute(conn, "CREATE TABLE IF NOT EXISTS bench_many_$(LABEL) (a BIGINT, b VARCHAR(24))")
        params = (a=collect(Int64, 1:100_000), b=["value-$(i % 1000)" for i in 1:100_000])
        b = @b run_executemany(conn, "bench_many_$(LABEL)", params) samples = 1 evals = 1
        report("100k executemany", b.time)
    finally
        DBInterface.close!(conn)
    end
    big = connect_bench(; max_allowed_packet=128 * 1024 * 1024)
    try
        b = @b run_blob(big) seconds = 6
        report("64 MiB blob fetch", b.time)
    finally
        DBInterface.close!(big)
    end
    return nothing
end

main()
