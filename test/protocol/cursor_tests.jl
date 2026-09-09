# The DBInterface text-protocol layer (`MySQL.Connection`, `TextCursor`) against the fake
# peer: decoding policies, the row-validity contract, multi-results, LOCAL INFILE, limits,
# reconnect. Server scripts answer the connection phase with `plain_peer_connect!` (no TLS,
# SET NAMES bootstrap) and then serve commands from `after`.
using Dates, Tables, DBInterface

# ColumnDefinition41 for a column of `type` (wire byte) with `flags`.
function coldef(name::AbstractString; type::Integer=P.MYSQL_TYPE_VAR_STRING, flags::Integer=0, decimals::Integer=0, charset::Integer=0x2D, length::Integer=255, table::AbstractString="t")
    buf = UInt8[]
    for s in ("def", "db", table, table, name, name)
        P.write_lenenc_string!(buf, s)
    end
    P.write_lenenc!(buf, 0x0C)
    P.write_u16!(buf, charset)
    P.write_u32!(buf, length)
    P.write_u8!(buf, type)
    P.write_u16!(buf, flags)
    P.write_u8!(buf, decimals)
    P.write_u16!(buf, 0)
    return buf
end

const NOT_NULL = P.NOT_NULL_FLAG
const UNSIGNED = P.UNSIGNED_FLAG
const BINARY = P.BINARY_FLAG

mutable struct AcceptedCounter
    @atomic value::Int
end

function increment!(counter::AcceptedCounter)
    @atomic counter.value += 1
    return @atomic counter.value
end

wiredef(type; flags=NOT_NULL, charset=0x2D) = P.ColumnDef("def", "db", "t", "t", "x", "x", UInt16(charset), UInt32(255), UInt8(type), UInt16(flags), UInt8(0))

function decode_text(T, value; opts=N.DEFAULT_RESULT_OPTIONS)
    buf = Vector{UInt8}(codeunits(value))
    return N.decode(T, buf, 1, length(buf), opts)
end

struct FailBeforeData <: IO end
Base.eof(::FailBeforeData) = false
Base.readbytes!(::FailBeforeData, ::Vector{UInt8}, ::Integer) = error("source failed before data")

mutable struct FailAfterData <: IO
    first::Bool
end

mutable struct ChunkedSource <: IO
    chunks::Vector{Vector{UInt8}}
    next::Int
end
Base.eof(io::ChunkedSource) = io.next > length(io.chunks)
function Base.readbytes!(io::ChunkedSource, buf::Vector{UInt8}, ::Integer)
    chunk = io.chunks[io.next]
    copyto!(buf, chunk)
    io.next += 1
    return length(chunk)
end
Base.eof(::FailAfterData) = false
function Base.readbytes!(io::FailAfterData, buf::Vector{UInt8}, ::Integer)
    io.first || error("source failed after data")
    io.first = false
    buf[1] = UInt8('x')
    return 1
end

# Sends a complete text result set: column count, definitions, rows, OK terminator.
function send_resultset(conn, seq, cols::Vector{Vector{UInt8}}, rows::Vector{Vector{UInt8}}; status=P.SERVER_STATUS_AUTOCOMMIT, more::Bool=false, terminator=nothing)
    send_packet(conn, seq, column_count(length(cols)))
    seq += 1
    for c in cols
        send_packet(conn, seq, c)
        seq += 1
    end
    for r in rows
        seq = send_logical(conn, seq, r)
    end
    st = more ? status | P.SERVER_MORE_RESULTS_EXISTS : status
    send_packet(conn, seq, terminator === nothing ? ok_payload(; header=0xFE, status=st) : terminator)
    return seq + 1
end

send_ok(conn, seq; affected=0, insert_id=0, status=P.SERVER_STATUS_AUTOCOMMIT, more::Bool=false) = (send_packet(conn, seq, ok_payload(; affected=affected, insert_id=insert_id, status=more ? status | P.SERVER_MORE_RESULTS_EXISTS : status)); seq + 1)
send_err(conn, seq, code, msg; sqlstate="HY000") = (send_packet(conn, seq, vcat(UInt8[0xFF], reinterpret(UInt8, [UInt16(code)]), UInt8['#'], codeunits(sqlstate), codeunits(msg))); seq + 1)
function eof_payload(; status=P.SERVER_STATUS_AUTOCOMMIT, warnings=0)
    buf = UInt8[0xFE]
    P.write_u16!(buf, warnings)
    P.write_u16!(buf, status)
    return buf
end

# Expects COM_QUERY and returns the SQL text.
function expect_query(conn)
    seq, cmd, payload = read_command(conn)
    cmd == P.COM_QUERY || error("expected COM_QUERY, got $cmd")
    return String(payload)
end

# Serves one native connection: the handshake, then `script(conn)` for the commands, then
# waits for COM_QUIT/EOF.
function with_native(f::Function, script::Function; connect_kw=(;), caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL)
    with_server(conn -> plain_peer_connect!(conn; caps=caps, after=c -> (script(c); stall_until_eof(c)))) do port
        conn = DBInterface.connect(N.Connection, "127.0.0.1", "root", "pw"; port=port, ssl_mode=:disabled, connect_timeout=10, connect_kw...)
        try
            f(conn)
        finally
            DBInterface.close!(conn)
        end
    end
end

const TYPED_COLS = [
    coldef("i"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL),
    coldef("u"; type=P.MYSQL_TYPE_LONGLONG, flags=UNSIGNED),
    coldef("f"; type=P.MYSQL_TYPE_FLOAT),
    coldef("d"; type=P.MYSQL_TYPE_NEWDECIMAL, decimals=3),
    coldef("s"; type=P.MYSQL_TYPE_VAR_STRING),
    coldef("b"; type=P.MYSQL_TYPE_BLOB, flags=BINARY),
    coldef("bit"; type=P.MYSQL_TYPE_BIT, flags=UNSIGNED),
    coldef("dt"; type=P.MYSQL_TYPE_DATETIME),
    coldef("da"; type=P.MYSQL_TYPE_DATE),
    coldef("tm"; type=P.MYSQL_TYPE_TIME),
    coldef("y"; type=P.MYSQL_TYPE_YEAR, flags=UNSIGNED),
]

@testset "text decoder: every 1.x mapped type" begin
    mapped = (
        P.MYSQL_TYPE_BIT => MySQL.Bit,
        P.MYSQL_TYPE_TINY => Cchar,
        P.MYSQL_TYPE_ENUM => Cchar,
        P.MYSQL_TYPE_SHORT => Cshort,
        P.MYSQL_TYPE_LONG => Cint,
        P.MYSQL_TYPE_INT24 => Cint,
        P.MYSQL_TYPE_LONGLONG => Int64,
        P.MYSQL_TYPE_FLOAT => Cfloat,
        P.MYSQL_TYPE_DECIMAL => MySQL.DataDecimals.DecimalValue{MySQL.DataDecimals.Int256},
        P.MYSQL_TYPE_NEWDECIMAL => MySQL.DataDecimals.DecimalValue{MySQL.DataDecimals.Int256},
        P.MYSQL_TYPE_DOUBLE => Cdouble,
        P.MYSQL_TYPE_YEAR => Clong,
        P.MYSQL_TYPE_TIMESTAMP => DateTime,
        P.MYSQL_TYPE_DATE => Date,
        P.MYSQL_TYPE_TIME => Time,
        P.MYSQL_TYPE_DATETIME => DateTime,
        P.MYSQL_TYPE_SET => String,
        P.MYSQL_TYPE_NULL => String,
        P.MYSQL_TYPE_VARCHAR => String,
        P.MYSQL_TYPE_VAR_STRING => String,
        P.MYSQL_TYPE_STRING => String,
        P.MYSQL_TYPE_JSON => String,
    )
    for (wire, T) in mapped
        @test N.juliatype(wiredef(wire), N.DEFAULT_RESULT_OPTIONS) === T
        @test N.juliatype(wiredef(wire; flags=0), N.DEFAULT_RESULT_OPTIONS) === Union{Missing, T}
    end
    for wire in (P.MYSQL_TYPE_TINY_BLOB, P.MYSQL_TYPE_MEDIUM_BLOB, P.MYSQL_TYPE_LONG_BLOB, P.MYSQL_TYPE_BLOB, P.MYSQL_TYPE_GEOMETRY)
        @test N.juliatype(wiredef(wire; flags=NOT_NULL | BINARY), N.DEFAULT_RESULT_OPTIONS) === Vector{UInt8}
        @test N.juliatype(wiredef(wire), N.DEFAULT_RESULT_OPTIONS) === String
    end
    @test N.juliatype(wiredef(P.MYSQL_TYPE_LONGLONG; flags=NOT_NULL | UNSIGNED), N.DEFAULT_RESULT_OPTIONS) === UInt64
    @test N.juliatype(wiredef(P.MYSQL_TYPE_YEAR; flags=NOT_NULL | UNSIGNED), N.DEFAULT_RESULT_OPTIONS) === unsigned(Clong)
    @test N.juliatype(wiredef(P.MYSQL_TYPE_DATETIME), N.ResultOptions(; date_and_time=true)) === DateAndTime
    @test N.juliatype(wiredef(P.MYSQL_TYPE_DATE), N.ResultOptions(; zero_dates=:missing)) === Union{Missing, Date}
    # hostile flags must not reach `unsigned(String)` (fuzz finding): a wire-supplied
    # NUM_FLAG is not trusted, and MYSQL_TYPE_NULL maps to String
    @test N.juliatype(wiredef(P.MYSQL_TYPE_VAR_STRING; flags=NOT_NULL | UNSIGNED | P.NUM_FLAG), N.DEFAULT_RESULT_OPTIONS) === String
    @test N.juliatype(wiredef(P.MYSQL_TYPE_NULL; flags=NOT_NULL | UNSIGNED), N.DEFAULT_RESULT_OPTIONS) === String

    for (T, value, expected) in (
            (Int8, "-128", Int8(-128)), (UInt8, "255", UInt8(255)),
            (Int16, "-32768", Int16(-32768)), (UInt16, "65535", UInt16(65535)),
            (Int32, "-2147483648", typemin(Int32)), (UInt32, "4294967295", typemax(UInt32)),
            (Int64, "-9223372036854775808", typemin(Int64)),
            (UInt64, "18446744073709551615", typemax(UInt64)),
            (Float32, "1.25", 1.25f0), (Float64, "-2.5", -2.5),
        )
        @test decode_text(T, value) === expected
    end
    @test decode_text(N.DecimalResult, "12.345") == parse(N.DecimalResult, "12.345")
    # an embedded NUL must be a ConversionError (fuzz finding)
    @test_throws P.ConversionError decode_text(N.DecimalResult, "12.\x0045")
    @test decode_text(MySQL.Bit, "\x01\x02") == MySQL.Bit(0x0102)
    @test decode_text(Vector{UInt8}, "\x00\xff") == UInt8[0x00, 0xff]
    @test decode_text(String, "héllo") == "héllo"
    @test N.decode(Union{Missing, Int32}, UInt8[], 1, -1, N.DEFAULT_RESULT_OPTIONS) === missing
    @test_throws P.ConversionError N.decode(Int32, UInt8[], 1, -1, N.DEFAULT_RESULT_OPTIONS)
    @test_throws P.ConversionError decode_text(Int32, "1x")
    for T in (UInt8, UInt16, UInt32, UInt64)
        @test_throws P.ConversionError decode_text(T, "-1")
        @test_throws P.ConversionError decode_text(T, "-0")
    end
end

@testset "deferred VECTOR result columns fault at metadata" begin
    vector = coldef("v"; type=P.MYSQL_TYPE_VECTOR)
    with_native(c -> begin
        expect_query(c)
        send_packet(c, 1, column_count(1))
        try
            send_packet(c, 2, vector)
        catch
        end
    end) do conn
        @test_throws P.ProtocolError DBInterface.execute(conn, "SELECT vector_col")
        @test !isopen(conn)
    end
end

@testset "invalid UTF-8 column metadata faults before Symbol conversion" begin
    invalid_name = String(UInt8[0xFF])
    invalid = coldef(invalid_name)
    with_native(c -> begin
        expect_query(c)
        send_packet(c, 1, column_count(1))
        try
            send_packet(c, 2, invalid)
        catch
        end
    end) do conn
        @test_throws P.ProtocolError DBInterface.execute(conn, "SELECT invalid_name")
        @test !isopen(conn)
    end
end

@testset "text cursor: values, NULLs and the row-validity contract" begin
    rows = [text_row("-7", "18446744073709551615", "1.5", "12.345", "héllo", "\x00\x01", "\x01\x02", "2024-02-29 13:14:15.250500", "2024-02-29", "838:59:59", "2024"),
            text_row(nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing)]
    with_native(c -> (expect_query(c); send_resultset(c, 1, TYPED_COLS, rows))) do conn
        cur = DBInterface.execute(conn, "select typed")
        @test Tables.schema(cur) == Tables.Schema([:i, :u, :f, :d, :s, :b, :bit, :dt, :da, :tm, :y], [Int32, Union{Missing, UInt64}, Union{Missing, Float32}, Union{Missing, MySQL.DataDecimals.DecimalValue{MySQL.DataDecimals.Int256}}, Union{Missing, String}, Union{Missing, Vector{UInt8}}, Union{Missing, MySQL.Bit}, Union{Missing, DateTime}, Union{Missing, Date}, Union{Missing, Time}, Union{Missing, unsigned(Clong)}])   # YEAR → unsigned(Clong): UInt64 on 64-bit, UInt32 on Windows x64
        @test length(cur) == 2 && Base.IteratorSize(typeof(cur)) == Base.HasLength() && eltype(cur) == N.TextRow
        state = iterate(cur)
        row, st = state
        @test row.i === Int32(-7) && row.u === typemax(UInt64) && row.f === 1.5f0 && row.d === MySQL.DataDecimals.DecimalValue{MySQL.DataDecimals.Int256}(12345, 3)
        @test row.s == "héllo" && row.b == UInt8[0x00, 0x01] && row.bit == MySQL.Bit(0x0102)
        @test_throws P.ConversionError row.tm                               # 838 h does not fit Dates.Time
        @test row.da == Date(2024, 2, 29) && row.y === unsigned(Clong)(2024)        # YEAR is an unsigned numeric (Clong: UInt64 on 64-bit, UInt32 on Windows x64)
        @test (@test_logs (:warn, r"microsecond") row.dt) == DateTime(2024, 2, 29, 13, 14, 15, 250)   # sub-ms warns once, truncates
        @test propertynames(row) == [:i, :u, :f, :d, :s, :b, :bit, :dt, :da, :tm, :y] && length(row) == 11
        @test Base.IndexStyle(typeof(row)) == Base.IndexLinear()
        row2, _ = iterate(cur, st)
        @test all(ismissing, (row2.u, row2.f, row2.d, row2.s, row2.b, row2.bit, row2.dt, row2.da, row2.tm, row2.y))
        @test_throws P.ConversionError row2.i                                # NULL in a NOT NULL column
        err = try; row.i; nothing; catch e; e; end
        @test err isa ArgumentError && err.msg == "row 1 is no longer valid; mysql results are forward-only iterators where each row is only valid when iterated"
        @test iterate(cur, 3) === nothing
        @test row2.s === missing                                             # the last row stays current
    end
end

@testset "text cursor: TIME and zero-date policies" begin
    cols = [coldef("tm"; type=P.MYSQL_TYPE_TIME), coldef("dt"; type=P.MYSQL_TYPE_DATETIME, flags=NOT_NULL), coldef("da"; type=P.MYSQL_TYPE_DATE, flags=NOT_NULL)]
    rows = [text_row("-01:02:03.5", "0000-00-00 00:00:00", "0000-00-00"), text_row("23:59:59.999999", "2024-05-00 00:00:00", "2024-00-01")]
    serve = c -> (expect_query(c); send_resultset(c, 1, cols, rows))
    with_native(serve) do conn   # defaults: Time, :sentinel
        cur = DBInterface.execute(conn, "select")
        @test Tables.schema(cur).types == (Union{Missing, Time}, DateTime, Date)
        r1, st = iterate(cur)
        @test_throws P.ConversionError r1.tm                                 # negative
        @test r1.dt == DateTime(0) && r1.da == Date(0)
        r2, _ = iterate(cur, st)
        @test r2.tm == Time(23, 59, 59, 999, 999)
        @test_throws P.ConversionError r2.dt                                 # partial zero date
        @test_throws P.ConversionError r2.da
    end
    with_native(serve; connect_kw=(; zero_dates=:missing, time_type=Dates.Microsecond)) do conn
        cur = DBInterface.execute(conn, "select")
        @test Tables.schema(cur).types == (Union{Missing, Dates.Microsecond}, Union{Missing, DateTime}, Union{Missing, Date})   # NOT NULL widened
        r1, st = iterate(cur)
        @test r1.tm == Dates.Microsecond(-3_723_500_000) && r1.dt === missing && r1.da === missing
        r2, _ = iterate(cur, st)
        @test r2.tm == Dates.Microsecond(86_399_999_999) && r2.dt === missing && r2.da === missing
    end
    with_native(serve; connect_kw=(; zero_dates=:error)) do conn
        r1, _ = iterate(DBInterface.execute(conn, "select"))
        @test_throws P.ConversionError r1.dt
    end
    @test_throws ArgumentError N.ConnectOptions("h", "u"; zero_dates=:nope)
    @test_throws ArgumentError N.ConnectOptions("h", "u"; time_type=Int)

    missing_dates = N.ResultOptions(; zero_dates=:missing)
    duration = N.ResultOptions(; time_type=Dates.Microsecond)
    # a zero month or day is a partial zero date; year 0000 alone is a legal year
    @test decode_text(Union{Missing, DateTime}, "2024-00-01 00:00:00"; opts=missing_dates) === missing
    @test decode_text(Union{Missing, Date}, "2024-05-00"; opts=missing_dates) === missing
    @test_throws P.ConversionError decode_text(DateTime, "2024-00-01 00:00:00")
    @test_throws P.ConversionError decode_text(Date, "2024-05-00")
    @test decode_text(DateTime, "0000-05-01 00:00:00") == DateTime(0, 5, 1)
    @test decode_text(Date, "0000-01-01") == Date(0, 1, 1)
    @test decode_text(Union{Missing, Date}, "0000-01-01"; opts=missing_dates) == Date(0, 1, 1)
    @test decode_text(Union{Missing, DateTime}, "0000-12-31 23:59:59"; opts=missing_dates) == DateTime(0, 12, 31, 23, 59, 59)
    @test decode_text(Date, "0000-01-01"; opts=N.ResultOptions(; zero_dates=:error)) == Date(0, 1, 1)
    @test_throws P.ConversionError decode_text(Union{Missing, DateTime}, "xxxx-00-xx 00:00:00"; opts=missing_dates)
    @test_throws P.ConversionError decode_text(DateTime, "0000-00-00::::")
    @test_throws P.ConversionError decode_text(DateTime, "2024-01-01 00:00:00.")
    @test_throws P.ConversionError decode_text(DateTime, "2024-01-01 00:00:00.1234567")
    @test_throws P.ConversionError decode_text(Dates.Microsecond, "839:00:00"; opts=duration)
    @test_throws P.ConversionError decode_text(Dates.Microsecond, "01:02:03."; opts=duration)
    @test_throws P.ConversionError decode_text(Dates.Microsecond, "01:02:03.1234567"; opts=duration)
    # fractional digits are scaled by their position (DATETIME(1) `.1` is 100 ms; 1.x read it as 1 µs)
    @test decode_text(DateAndTime, "2024-01-01 00:00:00.1") == DateAndTime(Date(2024, 1, 1), Time(0, 0, 0, 100, 0))
    @test decode_text(DateAndTime, "2024-01-01 00:00:00.123") == DateAndTime(Date(2024, 1, 1), Time(0, 0, 0, 123, 0))
    @test decode_text(DateAndTime, "2024-01-01 00:00:00.123456") == DateAndTime(Date(2024, 1, 1), Time(0, 0, 0, 123, 456))
    # sub-millisecond precision into a DateTime warns once and truncates (same as the binary path)
    @test decode_text(DateTime, "2024-01-01 00:00:00.123") == DateTime(2024, 1, 1, 0, 0, 0, 123)
    @test (@test_logs (:warn, r"microsecond") decode_text(DateTime, "2024-01-01 00:00:00.123456")) == DateTime(2024, 1, 1, 0, 0, 0, 123)
end

@testset "DML cursors, lastrowid snapshots, rows_affected bitcast" begin
    with_native(c -> begin
        expect_query(c); send_ok(c, 1; affected=3, insert_id=41)
        expect_query(c); send_ok(c, 1; affected=0xFFFF_FFFF_FFFF_FFFF, insert_id=0)
        expect_query(c); send_resultset(c, 1, [coldef("x"; type=P.MYSQL_TYPE_LONG)], [text_row("1")]; terminator=ok_payload(; header=0xFE, insert_id=41))
        expect_query(c); send_resultset(c, 1, [coldef("x"; type=P.MYSQL_TYPE_LONG)], [text_row("1")])
    end) do conn
        cur = DBInterface.execute(conn, "insert")
        @test cur.rows_affected == 3 && DBInterface.lastrowid(cur) == 41 && length(cur) == -1 && isempty(Tables.columntable(cur))
        @test Tables.schema(cur) == Tables.Schema(Symbol[], Type[])
        @test sprint(show, cur) == "MySQL.TextCursor(rows_affected=3)"
        cur = DBInterface.execute(conn, "update")
        @test cur.rows_affected == -1                                          # preserved Int64 bitcast of UInt64
        cur = DBInterface.execute(conn, "select")
        @test DBInterface.lastrowid(cur) == 41                                  # from this cursor's own terminator OK
        @test sprint(show, cur) == "MySQL.TextCursor(1 rows × 1 columns)"
        cur = DBInterface.execute(conn, "select"; mysql_store_result=false)
        @test sprint(show, cur) == "MySQL.TextCursor(streaming, 1 columns)"
        DBInterface.close!(cur)
        @test sprint(show, cur) == "MySQL.TextCursor(streaming, 1 columns, closed)"
        # server facts from the greeting (the fake peer announces connection id 7, 8.4.3)
        @test MySQL.connection_id(conn) == 7
        @test MySQL.server_version(conn) == v"8.4.3"
        @test MySQL.server_kind(conn) == :mysql
    end
end

@testset "pre-DEPRECATE_EOF text cursor" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    caps = MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL & ~P.CLIENT_DEPRECATE_EOF
    for buffered in (true, false)
        with_native(c -> begin
            expect_query(c)
            send_packet(c, 1, column_count(1))
            send_packet(c, 2, cols[1])
            send_packet(c, 3, eof_payload())
            seq = send_logical(c, 4, text_row("7"))
            send_packet(c, seq, eof_payload(; warnings=2))
        end; caps=caps) do conn
            cur = DBInterface.execute(conn, "select"; mysql_store_result=buffered)
            @test [r.x for r in cur] == [7]
            @test cur.ok === nothing && cur.status == P.SERVER_STATUS_AUTOCOMMIT && cur.warnings == 2
            @test DBInterface.lastrowid(cur) == 0
        end
    end
end

@testset "streaming cursor: ownership, invalidation, close!" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_query(c); send_resultset(c, 1, cols, [text_row("1"), text_row("2"), text_row("3")])
        expect_query(c); send_ok(c, 1)
        expect_query(c); send_resultset(c, 1, cols, [text_row("10"), text_row("20")])
        expect_query(c); send_resultset(c, 1, cols, [text_row("5"), text_row("6")])
        expect_query(c); send_ok(c, 1)
    end) do conn
        cur = DBInterface.execute(conn, "select"; mysql_store_result=false)
        @test Base.IteratorSize(typeof(cur)) == Base.SizeUnknown() && length(cur) == -1
        r1, st = iterate(cur)
        @test r1.x == 1
        # a foreign command drains the rest and invalidates the streaming cursor
        DBInterface.execute(conn, "other")
        @test_throws P.ProtocolError r1.x
        @test_throws P.ProtocolError iterate(cur, st)
        # close! drains a streaming cursor so the connection is idle again
        cur = DBInterface.execute(conn, "select"; mysql_store_result=false)
        r, st = iterate(cur)
        @test r.x == 10
        DBInterface.close!(cur)
        @test iterate(cur, st) === nothing
        @test_throws ArgumentError r.x
        @test isopen(conn)
        cur = DBInterface.execute(conn, "select"; mysql_store_result=false)
        r5, st = iterate(cur)
        foreign_row = errormonitor(Threads.@spawn try
            r5.x
        catch err
            err
        end)
        @test fetch(foreign_row) isa MySQL.MySQLInterfaceError
        foreign_iterate = errormonitor(Threads.@spawn try
            iterate(cur, st)
        catch err
            err
        end)
        @test fetch(foreign_iterate) isa MySQL.MySQLInterfaceError
        @test r5.x == 5
        r6, st = iterate(cur, st)
        @test r6.x == 6
        @test_throws ArgumentError r5.x
        @test iterate(cur, st) === nothing
        @test r6.x == 6                                                     # the last row remains current
        other = errormonitor(Threads.@spawn DBInterface.execute(conn, "after"))
        @test fetch(other).rows_affected == 0
        @test_throws P.ProtocolError r6.x                                   # a competing task invalidated it
    end

    release_rows = Channel{Nothing}(1)
    with_native(c -> begin
        expect_query(c)
        send_packet(c, 1, column_count(1))
        send_packet(c, 2, cols[1])
        seq = send_logical(c, 3, text_row("11"))
        take!(release_rows)
        seq = send_logical(c, seq, text_row("12"))
        send_packet(c, seq, ok_payload(; header=0xFE))
        expect_query(c); send_ok(c, 1)
    end) do conn
        cur = DBInterface.execute(conn, "select blocked"; mysql_store_result=false)
        row, _ = iterate(cur)
        @test row.x == 11
        other = errormonitor(Threads.@spawn DBInterface.execute(conn, "other"))
        waited = timedwait(() -> (@atomic conn.active_token) == 0, 2; pollint=0.001)
        @test waited == :ok
        @test_throws P.ProtocolError row.x                                  # invalid before draining touches the wire
        put!(release_rows, nothing)
        @test fetch(other).rows_affected == 0
    end
end

@testset "cursor close is local and idempotent" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_query(c); send_resultset(c, 1, cols, [text_row("1"), text_row("2")])
        expect_query(c); send_ok(c, 1; affected=3)
    end) do conn
        cur = DBInterface.execute(conn, "select")
        row = first(cur)
        DBInterface.close!(cur)
        DBInterface.close!(cur)
        @test iterate(cur) === nothing
        @test_throws ArgumentError row.x
        @test DBInterface.execute(conn, "after close").rows_affected == 3
    end
end

@testset "multiple results: distinct cursors, drains, errors, budgets" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    cols2 = [coldef("a"; type=P.MYSQL_TYPE_VAR_STRING), coldef("a"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    # DML → SELECT → DML(final), buffered and streaming
    for buffered in (true, false)
        with_native(c -> begin
            expect_query(c)
            seq = send_ok(c, 1; affected=2, insert_id=7, more=true)
            seq = send_resultset(c, seq, cols, [text_row("1"), text_row("2")]; more=true)
            send_ok(c, seq; affected=0)
            expect_query(c); send_ok(c, 1)
        end; connect_kw=(; multi_statements=true)) do conn
            results = collect(DBInterface.executemultiple(conn, "insert; select; delete"; mysql_store_result=buffered))
            @test length(results) == 3 && length(unique(objectid.(results))) == 3
            @test results[1].rows_affected == 2 && DBInterface.lastrowid(results[1]) == 7 && isempty(results[1].names)
            @test results[2].names == [:x] && results[2].current_resultsetnumber == 2
            @test results[3].rows_affected == 0 && results[3].current_resultsetnumber == 3
            # the streaming middle result was drained when the outer iterator advanced: its rows are gone
            buffered ? (@test [r.x for r in results[2]] == [1, 2]) : (@test collect(results[2]) == [])
            @test DBInterface.execute(conn, "next").rows_affected == 0
        end
    end
    # SELECT → DML → SELECT, with retained per-result snapshots
    for buffered in (true, false)
        with_native(c -> begin
            expect_query(c)
            seq = send_resultset(c, 1, cols, [text_row("1")]; more=true)
            seq = send_ok(c, seq; affected=3, insert_id=11, more=true)
            send_resultset(c, seq, cols, [text_row("4")])
        end; connect_kw=(; multi_statements=true)) do conn
            tc = DBInterface.executemultiple(conn, "select; update; select"; mysql_store_result=buffered)
            c1, outer = iterate(tc)
            @test [r.x for r in c1] == [1]
            c2, outer = iterate(tc, outer)
            @test c2.rows_affected == 3 && DBInterface.lastrowid(c2) == 11
            c3, outer = iterate(tc, outer)
            @test [r.x for r in c3] == [4]
            @test length(unique(objectid.((c1, c2, c3)))) == 3
            @test c1.names == [:x] && isempty(c2.names) && c3.names == [:x]
            @test iterate(tc, outer) === nothing
        end
    end
    # SELECT → SELECT with changed metadata and duplicate names; stale row after advancing
    with_native(c -> begin
        expect_query(c)
        seq = send_resultset(c, 1, cols, [text_row("1")]; more=true)
        send_resultset(c, seq, cols2, [text_row("s", "9")])
    end; connect_kw=(; multi_statements=true)) do conn
        tc = DBInterface.executemultiple(conn, "select; select"; mysql_store_result=false)
        c1, st = iterate(tc)
        r1, _ = iterate(c1)
        @test r1.x == 1
        c2, st = iterate(tc, st)
        @test c2 !== c1 && c2.names == [:a, :a] && MySQL.col_index(c2, :a) == 2 && c1.names == [:x]
        @test_throws ArgumentError r1.x                                        # drained: stale row
        r2, _ = iterate(c2)
        @test r2.a == 9 && r2[1] == "s"
        @test iterate(tc, st) === nothing
    end
    # advancing the outer iterator also consumes the streaming cursor and stays task-owned
    with_native(c -> begin
        expect_query(c)
        seq = send_resultset(c, 1, cols, [text_row("1")]; more=true)
        send_resultset(c, seq, cols, [text_row("2")])
    end; connect_kw=(; multi_statements=true)) do conn
        tc = DBInterface.executemultiple(conn, "select; select"; mysql_store_result=false)
        c1, outer = iterate(tc)
        r1, _ = iterate(c1)
        foreign_advance = errormonitor(Threads.@spawn try
            iterate(tc, outer)
        catch err
            err
        end)
        @test fetch(foreign_advance) isa MySQL.MySQLInterfaceError
        @test r1.x == 1
        c2, _ = iterate(tc, outer)
        @test first(c2).x == 2
    end
    # an outer advance also stales the last row of a result that was already exhausted
    with_native(c -> begin
        expect_query(c)
        seq = send_resultset(c, 1, cols, [text_row("1")]; more=true)
        send_resultset(c, seq, cols, [text_row("2")])
    end; connect_kw=(; multi_statements=true)) do conn
        tc = DBInterface.executemultiple(conn, "select; select"; mysql_store_result=false)
        c1, outer = iterate(tc)
        r1, inner = iterate(c1)
        @test iterate(c1, inner) === nothing
        @test r1.x == 1
        c2, _ = iterate(tc, outer)
        @test_throws ArgumentError r1.x
        @test first(c2).x == 2
    end
    # closing an older cursor must not drain the newer result that now owns the response
    with_native(c -> begin
        expect_query(c)
        seq = send_resultset(c, 1, cols, [text_row("1")]; more=true)
        send_resultset(c, seq, cols, [text_row("2"), text_row("3")])
    end; connect_kw=(; multi_statements=true)) do conn
        tc = DBInterface.executemultiple(conn, "select; select"; mysql_store_result=false)
        c1, outer = iterate(tc)
        @test first(c1).x == 1
        c2, _ = iterate(tc, outer)
        DBInterface.close!(c1)
        @test [r.x for r in c2] == [2, 3]
    end
    # a later ERR ends the iteration with Error, connection usable
    with_native(c -> begin
        expect_query(c)
        seq = send_resultset(c, 1, cols, [text_row("1")]; more=true)
        send_err(c, seq, 1064, "You have an error in your SQL syntax"; sqlstate="42000")
        expect_query(c); send_ok(c, 1)
    end; connect_kw=(; multi_statements=true)) do conn
        tc = DBInterface.executemultiple(conn, "select; bogus")
        c1, st = iterate(tc)
        @test [r.x for r in c1] == [1]
        err = try; iterate(tc, st); nothing; catch e; e; end
        @test err isa P.Error && err.errno == 1064 && err.sqlstate == "42000"
        @test DBInterface.execute(conn, "ok").rows_affected == 0
    end
    # CALL: results then a final OK; plain execute drains the rest on the next command
    with_native(c -> begin
        expect_query(c)
        seq = send_resultset(c, 1, cols, [text_row("1")]; more=true)
        send_ok(c, seq; status=P.SERVER_STATUS_AUTOCOMMIT)
        expect_query(c); send_ok(c, 1; affected=5)
    end) do conn
        cur = DBInterface.execute(conn, "call p()")
        @test Tables.columntable(cur).x == [1]
        @test DBInterface.execute(conn, "next").rows_affected == 5
    end
    # buffered results individually below but jointly above max_buffered_bytes → ProtocolError, connection closed
    big = text_row(repeat("x", 300))
    with_native(c -> begin
        expect_query(c)
        seq = send_resultset(c, 1, [coldef("s")], [big, big]; more=true)
        try; send_resultset(c, seq, [coldef("s")], [big, big]); catch; end
    end; connect_kw=(; multi_statements=true, max_buffered_bytes=1000)) do conn
        tc = DBInterface.executemultiple(conn, "select; select")
        c1, st = iterate(tc)
        @test length(c1) == 2
        @test_throws P.ProtocolError iterate(tc, st)
        @test !isopen(conn)
    end
    # a single result above the budget
    with_native(c -> (expect_query(c); try; send_resultset(c, 1, [coldef("s")], [big, big, big, big]); catch; end); connect_kw=(; max_buffered_bytes=1000)) do conn
        @test_throws P.ProtocolError DBInterface.execute(conn, "select")
        @test !isopen(conn)
        err = try; DBInterface.execute(conn, "select"); nothing; catch e; e; end   # broken session, reconnect=false
        @test err isa P.Error && err.errno == P.CR_SERVER_GONE_ERROR
    end
    # metadata, the reusable offset/NULL state and every row-start entry are charged
    col = coldef("s")
    nullrows = [text_row(nothing), text_row(nothing)]
    with_native(c -> (expect_query(c); send_resultset(c, 1, [col], nullrows))) do conn
        @test length(DBInterface.execute(conn, "select")) == 2
        @test conn.buffered_bytes == length(col) + 3 * sizeof(Int) + sum(length(row) + sizeof(Int) for row in nullrows)
    end
    # metadata alone can exceed the buffered budget, while streaming ignores that budget
    with_native(c -> (expect_query(c); try; send_resultset(c, 1, [col], Vector{UInt8}[]); catch; end); connect_kw=(; max_buffered_bytes=1)) do conn
        @test_throws P.ProtocolError DBInterface.execute(conn, "select")
        @test !isopen(conn)
    end
    with_native(c -> (expect_query(c); send_resultset(c, 1, [col], [big, big, big, big])); connect_kw=(; max_buffered_bytes=1)) do conn
        cur = DBInterface.execute(conn, "select"; mysql_store_result=false)
        @test length(collect(cur)) == 4 && conn.buffered_bytes == 0 && isopen(conn)
    end
end

@testset "malformed text rows fault the connection" begin
    col = coldef("s")
    malformed = UInt8[0x02, UInt8('x')]
    with_native(c -> (expect_query(c); try; send_resultset(c, 1, [col], [malformed]); catch; end)) do conn
        @test_throws P.ProtocolError DBInterface.execute(conn, "select")
        @test !isopen(conn)
    end
    with_native(c -> (expect_query(c); try; send_resultset(c, 1, [col], [malformed]); catch; end)) do conn
        cur = DBInterface.execute(conn, "select"; mysql_store_result=false)
        @test_throws P.ProtocolError iterate(cur)
        @test !isopen(conn)
    end
    with_native(c -> (expect_query(c); try; send_resultset(c, 1, [col], [text_row("valid"), malformed]); catch; end)) do conn
        cur = DBInterface.execute(conn, "select"; mysql_store_result=false)
        row, state = iterate(cur)
        @test row.s == "valid"
        @test_throws P.ProtocolError iterate(cur, state)
        @test_throws ArgumentError row.s
        @test !isopen(conn)
    end
end

@testset "server errors keep the connection usable" begin
    with_native(c -> begin
        expect_query(c); send_err(c, 1, 1146, "Table 'x' doesn't exist"; sqlstate="42S02")
        expect_query(c); send_ok(c, 1; affected=1)
    end) do conn
        err = try; DBInterface.execute(conn, "select * from x"); nothing; catch e; e; end
        @test err isa P.Error && err.errno == 1146 && err.sqlstate == "42S02" && sprint(showerror, err) == "(1146): Table 'x' doesn't exist"
        @test DBInterface.execute(conn, "ok").rows_affected == 1
    end
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    for buffered in (true, false)
        with_native(c -> begin
            expect_query(c)
            send_packet(c, 1, column_count(1))
            send_packet(c, 2, cols[1])
            seq = send_logical(c, 3, text_row("1"))
            send_err(c, seq, 1317, "Query execution was interrupted"; sqlstate="70100")
            expect_query(c); send_ok(c, 1; affected=2)
        end) do conn
            if buffered
                err = try; DBInterface.execute(conn, "select"); nothing; catch e; e; end
                @test err isa P.Error && err.errno == 1317 && err.sqlstate == "70100"
            else
                cur = DBInterface.execute(conn, "select"; mysql_store_result=false)
                row, state = iterate(cur)
                err = try; iterate(cur, state); nothing; catch e; e; end
                @test err isa P.Error && err.errno == 1317 && row.x == 1
            end
            @test DBInterface.execute(conn, "ok").rows_affected == 2 && isopen(conn)
        end
    end
end

@testset "LOCAL INFILE state table" begin
    # the request is sent only when the client negotiated LOCAL_FILES
    infile_request(c, seq, name) = (send_packet(c, seq, vcat(UInt8[0xFB], codeunits(name))); seq + 1)
    function read_upload(c)
        chunks = Vector{UInt8}[]
        while true
            seq, data = read_packet(c)
            isempty(data) && return (seq, chunks)
            push!(chunks, data)
        end
    end
    uploads = Vector{Vector{UInt8}}[]
    handler_calls = String[]
    handler = name -> (push!(handler_calls, name); name == "refuse" ? nothing : startswith(name, "boom") ? error("handler exploded") : IOBuffer(name == "empty" ? "" : "line1\nline2\n"))
    with_native(c -> begin
        # 1. upload accepted
        expect_query(c); seq = infile_request(c, 1, "data.csv"); seq, chunks = read_upload(c); push!(uploads, chunks); send_ok(c, seq + 1; affected=2)
        # 2. empty file is a valid upload
        expect_query(c); seq = infile_request(c, 1, "empty"); seq, chunks = read_upload(c); push!(uploads, chunks); send_ok(c, seq + 1; affected=0)
        # 3. refusal, server answers OK
        expect_query(c); seq = infile_request(c, 1, "refuse"); seq, chunks = read_upload(c); push!(uploads, chunks); send_ok(c, seq + 1; affected=0)
        # 4. refusal, server answers ERR
        expect_query(c); seq = infile_request(c, 1, "refuse"); seq, chunks = read_upload(c); push!(uploads, chunks); send_err(c, seq + 1, 1148, "not allowed")
        # 5. handler throws before any data: resynchronized, the handler error surfaces, connection usable
        expect_query(c); seq = infile_request(c, 1, "boom"); seq, chunks = read_upload(c); push!(uploads, chunks); send_ok(c, seq + 1)
        # 6. a refusal ERR is retained in the handler error's exception chain
        expect_query(c); seq = infile_request(c, 1, "boom-err"); seq, chunks = read_upload(c); push!(uploads, chunks); send_err(c, seq + 1, 1148, "not allowed")
        expect_query(c); send_ok(c, 1; affected=9)
    end; connect_kw=(; local_files=true, local_infile_handler=handler)) do conn
        @test DBInterface.execute(conn, "load data local infile 'data.csv'").rows_affected == 2
        @test DBInterface.execute(conn, "load data local infile 'empty'").rows_affected == 0
        err = try; DBInterface.execute(conn, "load data local infile 'refuse'"); nothing; catch e; e; end
        @test err isa P.LocalInfileRefused && err.filename == "refuse" && occursin("accepted the empty upload", err.msg)
        err = try; DBInterface.execute(conn, "load data local infile 'refuse'"); nothing; catch e; e; end
        @test err isa P.LocalInfileRefused && occursin("(1148)", err.msg) && err.cause isa P.Error && err.cause.errno == 1148
        err = try; DBInterface.execute(conn, "load data local infile 'boom'"); nothing; catch e; e; end
        @test err isa ErrorException && err.msg == "handler exploded"
        err, stack = try
            DBInterface.execute(conn, "load data local infile 'boom-err'")
            (nothing, current_exceptions())
        catch e
            (e, current_exceptions())
        end
        @test err isa ErrorException && err.msg == "handler exploded"
        @test any(item -> item.exception isa P.Error && item.exception.errno == 1148, stack)
        @test DBInterface.execute(conn, "ok").rows_affected == 9
        @test isopen(conn)
    end
    @test uploads[1] == [Vector{UInt8}(codeunits("line1\nline2\n"))] && uploads[2] == [] && uploads[3] == [] && uploads[4] == [] && uploads[5] == [] && uploads[6] == []
    @test handler_calls == ["data.csv", "empty", "refuse", "refuse", "boom", "boom-err"]
    # an IO failure before its first byte follows the same recoverable refusal path
    with_native(c -> begin
        expect_query(c); seq = infile_request(c, 1, "before"); seq, chunks = read_upload(c); @test isempty(chunks); send_ok(c, seq + 1)
        expect_query(c); send_ok(c, 1; affected=3)
    end; connect_kw=(; local_files=true, local_infile_handler=name -> FailBeforeData())) do conn
        err = try; DBInterface.execute(conn, "load data local infile 'before'"); nothing; catch e; e; end
        @test err isa ErrorException && err.msg == "source failed before data"
        @test DBInterface.execute(conn, "ok").rows_affected == 3 && isopen(conn)
    end
    # an invalid handler return is also known to precede all upload bytes and is recoverable
    with_native(c -> begin
        expect_query(c); seq = infile_request(c, 1, "invalid"); seq, chunks = read_upload(c); @test isempty(chunks); send_ok(c, seq + 1)
        expect_query(c); send_ok(c, 1)
    end; connect_kw=(; local_files=true, local_infile_handler=name -> 7)) do conn
        @test_throws ArgumentError DBInterface.execute(conn, "load data local infile 'invalid'")
        @test DBInterface.execute(conn, "ok").rows_affected == 0 && isopen(conn)
    end
    # once a data packet was sent, the same source failure makes the stream ambiguous
    with_native(c -> begin
        expect_query(c); infile_request(c, 1, "after"); try; read_upload(c); catch; end
    end; connect_kw=(; local_files=true, local_infile_handler=name -> FailAfterData(true))) do conn
        err = try; DBInterface.execute(conn, "load data local infile 'after'"); nothing; catch e; e; end
        @test err isa ErrorException && err.msg == "source failed after data"
        @test !isopen(conn)
    end
    # a later statement can request an upload, and a following result remains a query result
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    later_uploads = Vector{UInt8}[]
    with_native(c -> begin
        expect_query(c)
        seq = send_resultset(c, 1, cols, [text_row("1")]; more=true)
        infile_request(c, seq, "later")
        upload_seq, chunks = read_upload(c)
        append!(later_uploads, chunks)
        seq = send_ok(c, upload_seq + 1; affected=2, more=true)
        send_resultset(c, seq, cols, [text_row("3")])
    end; connect_kw=(; multi_statements=true, local_files=true, local_infile_handler=name -> IOBuffer("payload"))) do conn
        results = collect(DBInterface.executemultiple(conn, "select; load data local; select"))
        @test length(results) == 3
        @test Tables.columntable(results[1]).x == [1]
        @test results[2].rows_affected == 2
        @test Tables.columntable(results[3]).x == [3]
    end
    @test later_uploads == [Vector{UInt8}(codeunits("payload"))]
    # A first chunk above the size limit has sent no data, so refusal can resynchronize.
    with_native(c -> begin
        expect_query(c); seq = infile_request(c, 1, "too-big"); seq, chunks = read_upload(c); @test isempty(chunks); send_ok(c, seq + 1)
        expect_query(c); send_ok(c, 1; affected=8)
    end; connect_kw=(; local_files=true, local_infile_handler=name -> IOBuffer("12345"), max_local_infile_bytes=4)) do conn
        @test_throws P.ProtocolError DBInterface.execute(conn, "load data local infile 'too-big'")
        @test DBInterface.execute(conn, "ok").rows_affected == 8 && isopen(conn)
    end
    # Crossing the same limit after a packet was sent makes the stream ambiguous and closes it.
    sent_before_limit = Vector{UInt8}[]
    with_native(c -> begin
        expect_query(c); infile_request(c, 1, "later-too-big")
        try
            while true
                _, data = read_packet(c)
                isempty(data) && break
                push!(sent_before_limit, data)
            end
        catch
        end
    end; connect_kw=(; local_files=true, local_infile_handler=name -> ChunkedSource([UInt8[0x61, 0x62, 0x63], UInt8[0x64, 0x65, 0x66]], 1), max_local_infile_bytes=4)) do conn
        @test_throws P.ProtocolError DBInterface.execute(conn, "load data local infile 'later-too-big'")
        @test !isopen(conn)
    end
    @test sent_before_limit == [UInt8[0x61, 0x62, 0x63]]
    # an unsolicited request (LOCAL_FILES not negotiated) is a protocol error; handler never called
    called = Ref(false)
    with_native(c -> (expect_query(c); infile_request(c, 1, "x"))) do conn
        @test_throws P.ProtocolError DBInterface.execute(conn, "select 1")
        @test !isopen(conn)
    end
    @test !called[]
end

@testset "reconnect rule and closed connections" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    # reconnect=false: a dead session is reported as "server has gone away"
    with_native(c -> (expect_query(c); send_resultset(c, 1, cols, [text_row("1")]))) do conn
        cur = DBInterface.execute(conn, "select")
        @test Tables.columntable(cur).x == [1]
        P.close!(conn.handle.session)                                         # deterministic known-closed transport
        err = try; DBInterface.execute(conn, "again"); nothing; catch e; e; end
        @test err isa P.Error && err.errno == P.CR_SERVER_GONE_ERROR
        @test first(cur).x == 1                                               # buffered rows survive transport close
        @test_throws ErrorException (DBInterface.close!(conn); DBInterface.execute(conn, "after close"))
        @test sprint(show, conn) == "MySQL.Connection(disconnected)"
    end
    # reconnect=true: a new session before the next send once the old one is known dead
    # (closed or broken), old cursors invalidated, never inside a transaction
    accepted = AcceptedCounter(0)
    listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0))
    port = Int(Reseau.TCP.addr(listener).port)
    errormonitor(Threads.@spawn begin
        while true
            c = try; Reseau.TCP.accept(listener); catch; break; end
            n = increment!(accepted)
            errormonitor(Threads.@spawn begin
                try
                    plain_peer_connect!(c; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, after=cc -> begin
                        if n == 1
                            expect_query(cc); send_resultset(cc, 1, cols, [text_row("1")])
                            stall_until_eof(cc)
                        else
                            expect_query(cc); send_ok(cc, 1; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_IN_TRANS)
                            expect_query(cc); send_ok(cc, 1; affected=4, status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_IN_TRANS)
                            expect_query(cc); send_ok(cc, 1)
                            expect_query(cc); send_ok(cc, 1; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_IN_TRANS)
                            expect_query(cc); send_ok(cc, 1)
                            expect_query(cc)                                  # close mid-command: the session becomes BROKEN
                        end
                    end)
                catch
                finally
                    close(c)
                end
            end)
        end
    end)
    try
        conn = DBInterface.connect(N.Connection, "127.0.0.1", "root", "pw"; port=port, ssl_mode=:disabled, connect_timeout=10, reconnect=true)
        cur = DBInterface.execute(conn, "select"; mysql_store_result=false)
        r, _ = iterate(cur)
        @test r.x == 1
        # Close only the transport, leaving an unread streaming response in ROWS. The next
        # command must reconnect before trying to drain a transport already known closed.
        P.transport_close(conn.handle.session.transport)
        @test conn.handle.session.phase == P.ROWS
        gen = @atomic conn.generation
        @test DBInterface.transaction(conn) do
            @test DBInterface.execute(conn, "inside reconnect").rows_affected == 4
            42
        end == 42                                                              # START reconnects before entering the transaction
        @test (@atomic conn.generation) > gen && (@atomic accepted.value) == 2 && isopen(conn)
        @test_throws P.ProtocolError r.x
        # never inside a transaction
        DBInterface.transaction(conn) do
            conn.handle.session.phase = P.BROKEN
            err = try; DBInterface.execute(conn, "in tx"); nothing; catch e; e; end
            @test err isa P.Error && err.errno == P.CR_SERVER_GONE_ERROR
            conn.handle.session.phase = P.READY
        end
        # A raw transaction is also protected by the server status, without task ownership.
        conn.handle.session.status = P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_IN_TRANS
        conn.handle.session.phase = P.CLOSED
        err = try; DBInterface.execute(conn, "in raw tx"); nothing; catch e; e; end
        @test err isa P.Error && err.errno == P.CR_SERVER_GONE_ERROR
        @test (@atomic accepted.value) == 2
        conn.handle.session.status = P.SERVER_STATUS_AUTOCOMMIT
        conn.handle.session.phase = P.READY
        # the server drops the connection instead of answering: the classic 2006, the session
        # is BROKEN, and the *next* command reconnects (the libmysqlclient contract)
        err = try; DBInterface.execute(conn, "peer hangs up"); nothing; catch e; e; end
        @test err isa P.Error && err.errno == P.CR_SERVER_GONE_ERROR
        @test !isopen(conn) && conn.handle.session.phase == P.BROKEN
        @test DBInterface.execute(conn, "after broken").rows_affected == 0
        @test (@atomic accepted.value) == 3 && isopen(conn)
        DBInterface.close!(conn)
    finally
        close(listener)
    end
end

@testset "a failed reconnect leaves the connection retryable, not closed" begin
    # When the dead session cannot be re-established, ensure_live! keeps the old (closed)
    # handle so the next command retries the reconnect, instead of reporting the connection
    # as closed forever.
    listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0))
    port = Int(Reseau.TCP.addr(listener).port)
    accepted = AcceptedCounter(0)
    server = errormonitor(Threads.@spawn begin
        while true
            c = try; Reseau.TCP.accept(listener); catch; break; end
            increment!(accepted)
            errormonitor(Threads.@spawn begin
                try
                    plain_peer_connect!(c; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, after=cc -> begin
                        expect_query(cc); send_ok(cc, 1)
                        stall_until_eof(cc)
                    end)
                catch
                finally
                    close(c)
                end
            end)
        end
    end)
    try
        conn = DBInterface.connect(N.Connection, "127.0.0.1", "root", "pw"; port=port, ssl_mode=:disabled, connect_timeout=5, reconnect=true)
        @test DBInterface.execute(conn, "select").rows_affected == 0
        @test (@atomic accepted.value) == 1
        # kill the session and stop the server so the reconnect dial fails
        P.close!(conn.handle.session)
        close(listener); wait(server)
        err = try; DBInterface.execute(conn, "reconnect fails"); nothing; catch e; e; end
        @test err isa Exception                                                # the reconnect dial failed
        @test !(err isa ErrorException && occursin("closed or disconnected", err.msg))
        @test conn.handle !== nothing                                          # not permanently "closed"
        # a second attempt still tries to reconnect (same connect-style failure), never the
        # "connection has been closed or disconnected" local error
        err2 = try; DBInterface.execute(conn, "retry"); nothing; catch e; e; end
        @test !(err2 isa ErrorException && occursin("closed or disconnected", err2.msg))
        DBInterface.close!(conn)
    finally
        close(listener)
    end
end

@testset "command read timeout faults the connection" begin
    with_native(c -> begin
        expect_query(c)
        sleep(2)
        try
            send_ok(c, 1)
        catch
        end
    end; connect_kw=(; read_timeout=1)) do conn
        started = time_ns()
        @test_throws P.TimeoutError DBInterface.execute(conn, "slow")
        @test time_ns() - started < 5_000_000_000
        @test !isopen(conn)
    end
end

@testset "read_timeout is per operation, not per command" begin
    # A streaming cursor consumed slowly (each row inside read_timeout of the previous one)
    # must not fault: the deadline is re-armed before every transport read, like
    # Connector/C's MYSQL_OPT_READ_TIMEOUT, not set once for the whole command.
    rows = [text_row(string(i)) for i in 1:4]
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_query(c)
        send_packet(c, 1, column_count(1)); send_packet(c, 2, cols[1])
        for (i, r) in enumerate(rows)
            sleep(0.4)                                                        # < read_timeout=1 between rows
            send_logical(c, 2 + i, r)
        end
        send_packet(c, 3 + length(rows), ok_payload(; header=0xFE))
    end; connect_kw=(; read_timeout=1)) do conn
        cur = DBInterface.execute(conn, "slow-stream"; mysql_store_result=false)
        @test [Int(row.x) for row in cur] == [1, 2, 3, 4]                      # total wall time > read_timeout
        @test isopen(conn)
    end
end

@testset "closing an abandoned streaming cursor after read_timeout does not throw" begin
    # The stale-deadline regression: draining an abandoned stream at close! time used the
    # previous command's (now-expired) absolute deadline and faulted a healthy connection.
    with_native(c -> begin
        expect_query(c)
        send_packet(c, 1, column_count(1)); send_packet(c, 2, coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL))
        send_logical(c, 3, text_row("1"))
        send_logical(c, 4, text_row("2"))
        send_packet(c, 5, ok_payload(; header=0xFE))
        expect_query(c); send_ok(c, 1)
    end; connect_kw=(; read_timeout=2)) do conn
        cur = DBInterface.execute(conn, "stream"; mysql_store_result=false)
        @test iterate(cur)[1].x == 1
        sleep(2.2)                                                            # let the per-command deadline expire
        DBInterface.close!(cur)                                               # must quietly drain, not fault
        @test isopen(conn)
        @test DBInterface.execute(conn, "after").rows_affected == 0
    end
end

@testset "escape and identifiers" begin
    @test N.escape_literal("a'b\"c\\d\n\r\0\x1a", false) == "a\\'b\\\"c\\\\d\\n\\r\\0\\Z"
    @test N.escape_literal("a'b\\c", true) == "a''b\\c"
    @test N.escape_identifier("we`ird") == "`we``ird`"
    with_native(c -> begin
        expect_query(c); send_ok(c, 1; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_NO_BACKSLASH_ESCAPES)
    end) do conn
        @test N.escape(conn, SubString("'); DROP TABLE Employee; --")) == "\\'); DROP TABLE Employee; --"
        DBInterface.execute(conn, "SET sql_mode='NO_BACKSLASH_ESCAPES'")
        @test N.escape(conn, "it's") == "it''s"
    end
end

@testset "transactions hold the lock; nested use is an error" begin
    seen = String[]
    with_native(c -> begin
        for _ in 1:3
            push!(seen, expect_query(c)); send_ok(c, 1)
        end
        push!(seen, expect_query(c)); send_ok(c, 1)
        push!(seen, expect_query(c)); send_ok(c, 1)
    end) do conn
        @test DBInterface.transaction(conn) do
            DBInterface.execute(conn, "insert 1")
            @test_throws MySQL.MySQLInterfaceError DBInterface.transaction(() -> nothing, conn)
            @test conn.transaction_owner === current_task()
            @test_throws MySQL.MySQLInterfaceError DBInterface.transaction(() -> nothing, conn)
            42
        end == 42
        @test_throws ErrorException DBInterface.transaction(conn) do
            error("inside")
        end
    end
    @test seen == ["START TRANSACTION", "insert 1", "COMMIT", "START TRANSACTION", "ROLLBACK"]

    seen = String[]
    with_native(c -> begin
        for _ in 1:4
            push!(seen, expect_query(c)); send_ok(c, 1)
        end
    end) do conn
        entered = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        tx = errormonitor(Threads.@spawn DBInterface.transaction(conn) do
            DBInterface.execute(conn, "inside")
            put!(entered, nothing)
            take!(release)
            7
        end)
        take!(entered)
        outside = errormonitor(Threads.@spawn DBInterface.execute(conn, "outside"))
        yield()
        @test !istaskdone(outside)
        put!(release, nothing)
        @test fetch(tx) == 7
        @test fetch(outside).rows_affected == 0
    end
    @test seen == ["START TRANSACTION", "inside", "COMMIT", "outside"]
end

@testset "connection keyword surface and show" begin
    with_native(c -> nothing) do conn
        @test sprint(show, conn) == "MySQL.Connection(host=\"127.0.0.1\", user=\"root\", port=$(conn.port), db=\"\")"
        # `execute(conn, sql, params)` now prepares and executes (see binary_tests.jl); an
        # unbindable parameter type is still a MySQLInterfaceError, checked without the wire.
        @test_throws MySQL.MySQLInterfaceError N.param_type(:not_a_value)
    end
    @test N.strip_scheme("mysql://db.example") == "db.example" && N.strip_scheme("db.example") == "db.example"
end
