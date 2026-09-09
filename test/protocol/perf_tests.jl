# Serverless subset of the §8.9 performance/allocation gates: the per-row allocation
# contract of the read/scan/decode hot path — nothing is allocated per row (string and
# bytes values are views; a streaming cursor allocates one arena per `STREAM_ARENA_BYTES`
# of rows) — asserted against the fake peer on every CI lane (no Docker needed). The full
# server-backed correctness/limit/allocation gates and the timing report live in
# `test/perf/perf_gates.jl` and run inside `Pkg.test` when Docker is available.

const PERF_NROWS = 20_000

function perf_frame!(out::Vector{UInt8}, seq::Integer, payload::Vector{UInt8})
    P.write_u24!(out, length(payload))
    P.write_u8!(out, seq)
    append!(out, payload)
    return seq + 1
end

# One pre-serialized resultset stream (single write: the peer must not allocate per row
# while the client side is being measured).
function perf_stream(cols::Vector{Vector{UInt8}}, rows::Vector{Vector{UInt8}})
    out = UInt8[]
    seq = 1
    count = UInt8[]
    P.write_lenenc!(count, length(cols))
    seq = perf_frame!(out, seq, count)
    for c in cols
        seq = perf_frame!(out, seq, c)
    end
    for r in rows
        seq = perf_frame!(out, seq, r)
    end
    perf_frame!(out, seq, ok_payload(; header=0xFE))
    return out
end

function perf_text_row(i::Int)
    buf = UInt8[]
    P.write_lenenc_string!(buf, string(i))
    P.write_lenenc_string!(buf, "3.25")
    P.write_lenenc_string!(buf, "name-$(i % 100)-of-the-batch")   # > 12 bytes: an out-of-line view
    P.write_lenenc_string!(buf, "12345.67")
    i % 10 == 0 ? P.write_u8!(buf, P.NULL_VALUE) : P.write_lenenc_string!(buf, "7")
    return buf
end

function perf_null_row(::Int)
    buf = UInt8[]
    P.write_u8!(buf, P.NULL_VALUE)
    P.write_u8!(buf, P.NULL_VALUE)
    return buf
end

# Decodes every column of every row through the schema-specialized Tables path (as sinks
# like `columntable` consume rows: `getcolumn(row, ::Type{T}, …)` with a static `T`, so
# bits values are not boxed). The checksum keeps the decodes live.
mutable struct PerfAcc
    v::Int
end

perf_scan(cursor) = perf_scan_rows(cursor, Tables.schema(cursor))

function perf_scan_rows(cursor, sch::Tables.Schema)
    acc = PerfAcc(0)
    consume = (v, i, nm) -> begin
        v === missing && return nothing
        if v isa AbstractString
            acc.v += ncodeunits(v)
        elseif v isa DataDecimals.AbstractDecimal
            acc.v += DataDecimals.decimallength(v)
        elseif v isa AbstractFloat
            acc.v += unsafe_trunc(Int, v)
        else
            acc.v += Int(v)
        end
        return nothing
    end
    for row in cursor
        Tables.eachcolumn(consume, sch, row)
    end
    return acc.v
end

# Transition-coverage recording is a test-only fixture (off in production) that allocates
# per transition; the per-row gate measures the production configuration.
function alloc_count(f::Function)
    f()   # warmup (compilation)
    was_enabled = P.COVERAGE_ENABLED[]
    P.COVERAGE_ENABLED[] = false
    try
        stats = Base.gc_num()
        f()
        return Base.gc_alloc_count(Base.GC_Diff(Base.gc_num(), stats))
    finally
        P.COVERAGE_ENABLED[] = was_enabled
    end
end

@testset "per-row allocation gates (§8.9 serverless subset)" begin
    typed_cols = [
        coldef("i"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL),
        coldef("f"; type=P.MYSQL_TYPE_DOUBLE),
        coldef("s"; type=P.MYSQL_TYPE_VAR_STRING),
        coldef("d"; type=P.MYSQL_TYPE_NEWDECIMAL, flags=NOT_NULL, decimals=2),
        coldef("n"; type=P.MYSQL_TYPE_LONG),
    ]
    null_cols = [coldef("a"; type=P.MYSQL_TYPE_LONG), coldef("b"; type=P.MYSQL_TYPE_SHORT)]
    typed_stream = perf_stream(typed_cols, [perf_text_row(i) for i in 1:PERF_NROWS])
    null_stream = perf_stream(null_cols, [perf_null_row(i) for i in 1:PERF_NROWS])
    # The budget is a fixed slack (cursor, metadata, arenas), not a per-row count: a pass
    # that allocates once per row exceeds it several times over.
    slack = 3_000
    @testset "buffered: decode-only passes over a retained result" begin
        with_native(c -> begin
            expect_query(c)
            send_raw(c, typed_stream)
            expect_query(c)
            send_raw(c, null_stream)
        end) do conn
            cursor = DBInterface.execute(conn, "typed")
            @test length(cursor) == PERF_NROWS
            allocs = alloc_count(() -> perf_scan(cursor))
            @info "buffered typed scan" allocs_per_row=allocs / PERF_NROWS
            @test allocs <= slack
            nullcur = DBInterface.execute(conn, "nulls")
            allocs = alloc_count(() -> perf_scan(nullcur))
            @info "buffered NULL scan" allocs_per_row=allocs / PERF_NROWS
            @test allocs <= slack
        end
    end
    @testset "streaming: full execute + scan passes" begin
        with_native(c -> begin
            for _ in 1:4
                expect_query(c)
                send_raw(c, typed_stream)
            end
        end) do conn
            run = () -> perf_scan(DBInterface.execute(conn, "typed"; mysql_store_result=false))
            run(); run()   # warm both the execute and scan paths
            allocs = alloc_count(run)
            @info "streaming typed scan" allocs_per_row=allocs / PERF_NROWS
            @test allocs <= slack
        end
    end
end
