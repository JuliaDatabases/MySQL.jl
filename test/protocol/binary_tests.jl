# The prepared-statement / binary-protocol layer (`Native.Statement`, binary `Cursor`) against
# the fake peer: binary value codecs, parameter binding and the type signature, the
# COM_STMT_PREPARE/EXECUTE round trip, DML and NULL parameters, the single 1615 re-prepare,
# statement reaping, one-shot `execute(conn, sql, params)`, `executemany`, and multi-result
# prepared CALLs. Reuses the `coldef`/`send_resultset`/`with_native` helpers from the text
# cursor tests (included earlier in the suite).

# ---- server-side helpers ----

function send_prepare_ok(conn, seq, statement_id, param_defs::Vector, col_defs::Vector; warnings=0)
    hdr = UInt8[0x00]
    P.write_u32!(hdr, statement_id)
    P.write_u16!(hdr, length(col_defs))
    P.write_u16!(hdr, length(param_defs))
    P.write_u8!(hdr, 0)
    P.write_u16!(hdr, warnings)
    send_packet(conn, seq, hdr)
    seq += 1
    for d in param_defs
        send_packet(conn, seq, d); seq += 1
    end
    for d in col_defs
        send_packet(conn, seq, d); seq += 1
    end
    return seq
end

function expect_prepare(conn)
    _, cmd, payload = read_command(conn)
    cmd == P.COM_STMT_PREPARE || error("expected COM_STMT_PREPARE, got $cmd")
    return String(payload)
end

function expect_execute(conn)
    _, cmd, payload = read_command(conn)
    cmd == P.COM_STMT_EXECUTE || error("expected COM_STMT_EXECUTE, got $cmd")
    return payload
end

function expect_stmt_close(conn)
    _, cmd, payload = read_command(conn)
    cmd == P.COM_STMT_CLOSE || error("expected COM_STMT_CLOSE, got $cmd")
    length(payload) == 4 || error("expected a 4-byte statement id")
    return UInt32(payload[1]) |
           (UInt32(payload[2]) << 8) |
           (UInt32(payload[3]) << 16) |
           (UInt32(payload[4]) << 24)
end

# A binary protocol resultset row: 0x00 header, NULL bitmap (bit offset 2), then the non-NULL
# values encoded exactly as parameters are (same wire form).
function binary_row(values...)
    n = length(values)
    buf = UInt8[0x00]
    nb = (n + 7 + 2) >> 3
    null = zeros(UInt8, nb)
    for (i, v) in enumerate(values)
        if v === missing || v === nothing
            bit = i - 1 + 2
            null[(bit >> 3) + 1] |= UInt8(1) << (bit & 7)
        end
    end
    append!(buf, null)
    for v in values
        (v === missing || v === nothing) && continue
        N.encode_param_value!(buf, v)
    end
    return buf
end

paramdefs(n) = [coldef("p$i"; type=P.MYSQL_TYPE_VAR_STRING) for i in 1:n]

# new_params_bind_flag byte of a COM_STMT_EXECUTE payload with `nparams` parameters.
function execute_new_params_flag(payload, nparams)
    nb = (nparams + 7) >> 3
    return payload[4 + 1 + 4 + nb + 1]
end

@testset "COM_STMT_PREPARE_OK header shape" begin
    header = UInt8[0x00]
    P.write_u32!(header, 0x01020304)
    P.write_u16!(header, 2)
    P.write_u16!(header, 3)
    P.write_u8!(header, 0)
    @test P.parse_prepare_ok_header(pv(copy(header))) == (UInt32(0x01020304), 2, 3, UInt16(0))
    P.write_u16!(header, 7)
    @test P.parse_prepare_ok_header(pv(copy(header))) == (UInt32(0x01020304), 2, 3, UInt16(7))
    @test_throws P.ProtocolError P.parse_prepare_ok_header(pv(vcat(header, 0x01)))
    @test_throws P.ProtocolError P.parse_prepare_ok_header(pv(header[1:11]))
    bad_reserved = copy(header)
    bad_reserved[10] = 0x01
    @test_throws P.ProtocolError P.parse_prepare_ok_header(pv(bad_reserved))
end

@testset "binary row spans and NULL bitmap boundaries" begin
    for n in (1, 7, 8, 9, 64)
        null_index = n
        row = UInt8[0x00]
        nullbytes = (n + 7 + 2) >> 3
        nullmap = zeros(UInt8, nullbytes)
        bit = null_index - 1 + 2
        nullmap[(bit >> 3) + 1] |= UInt8(1) << (bit & 7)
        append!(row, nullmap)
        append!(row, fill(0x2a, n - 1))
        offsets, lengths = Int[], Int[]
        P.scan_binary_row!(fill(P.MYSQL_TYPE_TINY, n), pv(row), offsets, lengths)
        @test length(offsets) == n && length(lengths) == n
        @test lengths[1:(n - 1)] == fill(1, n - 1)
        @test lengths[n] == -1
    end

    row = UInt8[0x00, 0x00]
    P.write_u32!(row, 7)
    append!(row, UInt8[0x07, 0xe8, 0x07, 0x02, 0x1d, 0x0d, 0x0e, 0x0f])
    P.write_lenenc_string!(row, "abc")
    push!(row, 0x00)
    offsets, lengths = Int[], Int[]
    types = UInt8[P.MYSQL_TYPE_LONG, P.MYSQL_TYPE_DATETIME, P.MYSQL_TYPE_VAR_STRING, P.MYSQL_TYPE_TIME]
    P.scan_binary_row!(types, pv(row), offsets, lengths)
    @test lengths == [4, 7, 3, 0]
    @test row[offsets[1]:(offsets[1] + 3)] == reinterpret(UInt8, UInt32[7])
    @test row[offsets[2]:(offsets[2] + 6)] == UInt8[0xe8, 0x07, 0x02, 0x1d, 0x0d, 0x0e, 0x0f]
    @test String(row[offsets[3]:(offsets[3] + 2)]) == "abc"

    @test_throws P.ProtocolError P.scan_binary_row!(UInt8[P.MYSQL_TYPE_DATETIME], pv(UInt8[0x00, 0x00, 0x03, 0x00, 0x00, 0x00]), Int[], Int[])
    @test_throws P.ProtocolError P.scan_binary_row!(UInt8[P.MYSQL_TYPE_TIME], pv(UInt8[0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), Int[], Int[])
    @test_throws P.ProtocolError P.scan_binary_row!(UInt8[P.MYSQL_TYPE_NEWDATE], pv(UInt8[0x00, 0x00, 0x00]), Int[], Int[])
    @test_throws P.ProtocolError P.scan_binary_row!(UInt8[P.MYSQL_TYPE_NULL], pv(UInt8[0x00, 0x00, 0x00]), Int[], Int[])
    @test_throws P.ProtocolError P.scan_binary_row!(UInt8[P.MYSQL_TYPE_LONG], pv(UInt8[0x00, 0x00, 0x01]), Int[], Int[])
    @test_throws P.ProtocolError P.scan_binary_row!(UInt8[P.MYSQL_TYPE_VAR_STRING], pv(UInt8[0x00, 0x00, 0x03, 0x61]), Int[], Int[])
end

@testset "binary value decoder: fixed, float, string, temporal" begin
    o = N.DEFAULT_RESULT_OPTIONS
    # signed and unsigned integers at every width, boundaries included
    @test N.decode_binary(Int8, UInt8[0x80], 1, 1, o) === Int8(-128)
    @test N.decode_binary(UInt8, UInt8[0xFF], 1, 1, o) === UInt8(255)
    @test N.decode_binary(Int16, UInt8[0x00, 0x80], 1, 2, o) === typemin(Int16)
    @test N.decode_binary(UInt16, UInt8[0xFF, 0xFF], 1, 2, o) === typemax(UInt16)
    @test N.decode_binary(Int32, UInt8[0x00, 0x00, 0x00, 0x80], 1, 4, o) === typemin(Int32)
    @test N.decode_binary(UInt32, UInt8[0xFF, 0xFF, 0xFF, 0xFF], 1, 4, o) === typemax(UInt32)
    @test N.decode_binary(Int64, reinterpret(UInt8, [typemin(Int64)]) |> collect, 1, 8, o) === typemin(Int64)
    @test N.decode_binary(UInt64, fill(0xFF, 8), 1, 8, o) === typemax(UInt64)
    @test N.decode_binary(UInt64, UInt8[0xE8, 0x07], 1, 2, o) === UInt64(2024)   # YEAR: 2-byte wire → UInt64
    @test N.decode_binary(Int8, Vector{UInt8}(codeunits("Management")), 1, 10, o) === Int8('M')  # preserved ENUM/Cchar truncation
    # floats
    @test N.decode_binary(Float32, reinterpret(UInt8, [1.25f0]) |> collect, 1, 4, o) === 1.25f0
    @test N.decode_binary(Float64, reinterpret(UInt8, [-2.5]) |> collect, 1, 8, o) === -2.5
    @test_throws P.ConversionError N.decode_binary(Float64, UInt8[0x00, 0x00, 0x00, 0x00], 1, 4, o)
    @test_throws P.ConversionError N.decode_binary(Float32, UInt8[0x00, 0x00, 0x00, 0x00], 2, 4, o)
    @test_throws P.ConversionError N.decode_binary(Int32, UInt8[0x00, 0x00, 0x00, 0x00], 0, 4, o)
    # string, blob, decimal, BIT (big-endian) share the text content decoders
    @test N.decode_binary(String, Vector{UInt8}(codeunits("héllo")), 1, ncodeunits("héllo"), o) == "héllo"
    @test N.decode_binary(Vector{UInt8}, UInt8[0x00, 0xff], 1, 2, o) == UInt8[0x00, 0xff]
    @test N.decode_binary(Dec64, Vector{UInt8}(codeunits("12.345")), 1, 6, o) == d64"12.345"
    @test N.decode_binary(MySQL.API.Bit, UInt8[0x01, 0x02], 1, 2, o) == MySQL.API.Bit(0x0102)
    # DATE (len 4), DATETIME (len 7 and 11), TIMESTAMP is the same as DATETIME
    date4 = UInt8[0xe8, 0x07, 0x02, 0x1d]                                   # 2024-02-29
    @test N.decode_binary(Date, date4, 1, 4, o) == Date(2024, 2, 29)
    dt7 = UInt8[0xe8, 0x07, 0x02, 0x1d, 0x0d, 0x0e, 0x0f]                   # 2024-02-29 13:14:15
    @test N.decode_binary(DateTime, dt7, 1, 7, o) == DateTime(2024, 2, 29, 13, 14, 15)
    dt11 = vcat(dt7, reinterpret(UInt8, UInt32[250000]))                    # .250000 → 250 ms exactly
    @test N.decode_binary(DateTime, dt11, 1, 11, o) == DateTime(2024, 2, 29, 13, 14, 15, 250)
    # sub-millisecond precision: 1.x prepared-statement behaviour warns then truncates to ms
    dtsub = vcat(dt7, reinterpret(UInt8, UInt32[250500]))
    @test (@test_logs (:warn, r"microsecond") N.decode_binary(DateTime, dtsub, 1, 11, o)) == DateTime(2024, 2, 29, 13, 14, 15, 250)
    @test N.decode_binary(MySQL.DateAndTime, dtsub, 1, 11, o) == MySQL.DateAndTime(Date(2024, 2, 29), Time(13, 14, 15, 250, 500))
    # TIME len 0 (zero), 8 (no micros) and 12 (with micros and days), and the negative/day Fix
    @test N.decode_binary(Time, UInt8[], 1, 0, o) == Time(0)
    time8 = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x0d, 0x0e, 0x0f]           # +0d 13:14:15
    @test N.decode_binary(Time, time8, 1, 8, o) == Time(13, 14, 15)
    # 2 days 01:02:03.5 as Dates.Microsecond (Fix: days honoured, unlike 1.x binary)
    time12 = vcat(UInt8[0x00], reinterpret(UInt8, UInt32[2]), UInt8[0x01, 0x02, 0x03], reinterpret(UInt8, UInt32[500000]))
    micros = ((2 * 24 + 1) * 3600 + 2 * 60 + 3) * 1_000_000 + 500_000
    @test N.decode_binary(Dates.Microsecond, time12, 1, 12, N.ResultOptions(; time_type=Dates.Microsecond)) == Dates.Microsecond(micros)
    @test_throws P.ConversionError N.decode_binary(Time, time12, 1, 12, o)   # ≥ 24h does not fit Dates.Time
    neg = vcat(UInt8[0x01], reinterpret(UInt8, UInt32[0]), UInt8[0x01, 0x02, 0x03])
    @test N.decode_binary(Dates.Microsecond, neg, 1, 8, N.ResultOptions(; time_type=Dates.Microsecond)) == Dates.Microsecond(-((1 * 3600 + 2 * 60 + 3) * 1_000_000))
    max_time = vcat(UInt8[0x00], reinterpret(UInt8, UInt32[34]), UInt8[0x16, 0x3b, 0x3b], reinterpret(UInt8, UInt32[999999]))
    max_micros = ((838 * 60 + 59) * 60 + 59) * 1_000_000 + 999_999
    @test N.decode_binary(Dates.Microsecond, max_time, 1, 12, N.ResultOptions(; time_type=Dates.Microsecond)) == Dates.Microsecond(max_micros)
    @test_throws P.ConversionError N.decode_binary(Dates.Microsecond, vcat(UInt8[0x02], max_time[2:end]), 1, 12, o)
    @test_throws P.ConversionError N.decode_binary(Dates.Microsecond, vcat(UInt8[0x00], reinterpret(UInt8, UInt32[35]), UInt8[0x00, 0x00, 0x00]), 1, 8, o)
    @test_throws P.ConversionError N.decode_binary(Dates.Microsecond, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x00], 1, 8, o)
    bad_micros = vcat(time8, reinterpret(UInt8, UInt32[1_000_000]))
    @test_throws P.ConversionError N.decode_binary(Dates.Microsecond, bad_micros, 1, 12, o)
    bad_clock = vcat(UInt8[0xe8, 0x07, 0x02, 0x1d, 0x18, 0x00, 0x00], reinterpret(UInt8, UInt32[0]))
    @test_throws P.ConversionError N.decode_binary(MySQL.DateAndTime, bad_clock, 1, 11, o)
    # invalid length is a conversion error, not an out-of-bounds read
    @test_throws P.ConversionError N.decode_binary(DateTime, UInt8[0x00, 0x00, 0x00], 1, 3, o)
end

@testset "binary zero-date policy matches the text path" begin
    zero = UInt8[]
    @test N.decode_binary(DateTime, zero, 1, 0, N.DEFAULT_RESULT_OPTIONS) == DateTime(0)   # :sentinel
    @test N.decode_binary(Date, zero, 1, 0, N.DEFAULT_RESULT_OPTIONS) == Date(0)
    @test N.decode_binary(Union{Missing, Date}, zero, 1, 0, N.ResultOptions(; zero_dates=:missing)) === missing
    @test_throws P.ConversionError N.decode_binary(DateTime, zero, 1, 0, N.ResultOptions(; zero_dates=:error))
    partial = UInt8[0x00, 0x00, 0x05, 0x01]   # 0000-05-01
    @test_throws P.ConversionError N.decode_binary(Date, partial, 1, 4, N.DEFAULT_RESULT_OPTIONS)
    @test N.decode_binary(Union{Missing, Date}, partial, 1, 4, N.ResultOptions(; zero_dates=:missing)) === missing
    @test N.decode_binary(Union{Missing, Int32}, UInt8[], 1, -1, N.DEFAULT_RESULT_OPTIONS) === missing
    @test_throws P.ConversionError N.decode_binary(Int32, UInt8[], 1, -1, N.DEFAULT_RESULT_OPTIONS)
end

@testset "parameter signature and encoding" begin
    @test N.param_signature(Any[Int32(1), missing, "s", UInt64(2)]) == UInt16[0x0003, 0x0006, 0x00fe, UInt16(P.MYSQL_TYPE_LONGLONG) | 0x8000]
    # Preserve the effective 1.x bind types after `val`: Bit becomes bytes, and DecFP
    # becomes a String. Bool is the one deliberate M4 deviation and uses TINY.
    @test N.param_signature(Any[MySQL.API.Bit(0x101), d64"12.3", Dec128("4.5"), true]) == UInt16[
        P.MYSQL_TYPE_BLOB,
        P.MYSQL_TYPE_STRING,
        P.MYSQL_TYPE_STRING,
        P.MYSQL_TYPE_TINY,
    ]
    # a NULL parameter sets its bitmap bit and contributes no value bytes
    blk = N.encode_param_block(Any[missing, Int32(7)], N.param_signature(Any[missing, Int32(7)]), true)
    @test blk[1] == 0x01                                   # null bitmap: bit 0 set for the first (missing) param
    @test blk[2] == 0x01                                   # new_params_bind_flag
    @test blk[end - 3:end] == reinterpret(UInt8, Int32[7]) # only the non-null value trails
    # long-data parameters (skip) carry their type but no inline value and are not NULL
    v = Any[Vector{UInt8}([0x61, 0x62]), Int32(9)]
    sig = N.param_signature(v)
    blk = N.encode_param_block(v, sig, true; skip=(1,))
    @test blk[1] == 0x00                                      # neither parameter is NULL
    @test blk[2] == 0x01                                      # new_params_bind_flag
    @test blk[3:end] == vcat(reinterpret(UInt8, sig), reinterpret(UInt8, Int32[9]))  # types, then only param 2's value
    @test isempty(N.encode_param_block((), UInt16[], true))
end

@testset "prepare then execute: binary result set round trip" begin
    cols = [coldef("i"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL), coldef("s"; type=P.MYSQL_TYPE_VAR_STRING)]
    with_native(c -> begin
        @test expect_prepare(c) == "SELECT i, s FROM t WHERE i > ?"
        send_prepare_ok(c, 1, 1, paramdefs(1), cols)
        payload = expect_execute(c)
        @test execute_new_params_flag(payload, 1) == 0x01           # first execute sends types
        send_resultset(c, 1, cols, [binary_row(Int32(7), "abc"), binary_row(Int32(9), missing)])
        payload2 = expect_execute(c)
        @test execute_new_params_flag(payload2, 1) == 0x00          # same signature ⇒ types not resent
        send_resultset(c, 1, cols, [binary_row(Int32(7), "abc")])
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT i, s FROM t WHERE i > ?")
        @test stmt isa N.Statement && stmt.nparams == 1
        @test stmt.names == [:i, :s] && stmt.types == Type[Int32, Union{Missing, String}]
        cur = DBInterface.execute(stmt, (5,))
        @test cur isa N.BinaryCursor && eltype(cur) == N.BinaryRow
        @test Tables.schema(cur) == Tables.Schema([:i, :s], [Int32, Union{Missing, String}])
        seen = [(r.i, r.s) for r in cur]     # fields read while each row is current
        @test isequal(seen, [(Int32(7), "abc"), (Int32(9), missing)])
        @test Tables.columntable(DBInterface.execute(stmt, (5,))).i == Int32[7]
        DBInterface.close!(stmt)
    end
end

@testset "prepared DML: OK result, rows_affected, lastrowid, empty schema" begin
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 5, paramdefs(2), P.ColumnDef[])
        expect_execute(c); send_ok(c, 1; affected=2, insert_id=41)
    end) do conn
        stmt = DBInterface.prepare(conn, "INSERT INTO t (a, b) VALUES (?, ?)")
        @test stmt.nparams == 2 && isempty(stmt.names)
        cur = DBInterface.execute(stmt, ("x", 3))
        @test cur.rows_affected == 2 && DBInterface.lastrowid(cur) == 41 && length(cur) == -1
        @test isempty(Tables.columntable(cur))
        DBInterface.close!(stmt)
    end
end

@testset "prepared API compatibility checks and execute-time metadata" begin
    dtcol = coldef("dt"; type=P.MYSQL_TYPE_DATETIME, flags=NOT_NULL)
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 61, P.ColumnDef[], [dtcol])
        expect_execute(c)
        send_resultset(c, 1, [dtcol], Vector{UInt8}[])

        expect_prepare(c)
        send_prepare_ok(c, 1, 62, P.ColumnDef[], P.ColumnDef[])
        expect_execute(c)
        send_resultset(c, 1, [dtcol], Vector{UInt8}[])
    end) do conn
        static_stmt = DBInterface.prepare(conn, "SELECT CAST(NOW() AS DATETIME) AS dt")
        static_cur = DBInterface.execute(static_stmt; mysql_date_and_time=true)
        @test Tables.schema(static_cur).types == (DateTime,)

        dynamic_stmt = DBInterface.prepare(conn, "CALL dynamic_metadata()")
        dynamic_cur = DBInterface.execute(dynamic_stmt; mysql_date_and_time=true)
        @test Tables.schema(dynamic_cur).types == (MySQL.DateAndTime,)
        DBInterface.close!(static_stmt)
        DBInterface.close!(dynamic_stmt)
    end

    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 63, paramdefs(2), P.ColumnDef[])
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT ?, ?")
        err = try
            DBInterface.execute(stmt, (1,))
            nothing
        catch caught
            caught
        end
        @test err isa MySQL.MySQLInterfaceError
        @test sprint(showerror, err) == "stmt requires 2 params, only 1 provided"
        DBInterface.close!(stmt)
        closederr = try
            DBInterface.execute(stmt, (1, 2))
            nothing
        catch caught
            caught
        end
        @test closederr isa ErrorException
        @test sprint(showerror, closederr) == "prepared mysql statement has been closed"
    end
end

@testset "streaming binary cursor and the wrongrow contract" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 3, P.ColumnDef[], cols)
        expect_execute(c); send_resultset(c, 1, cols, [binary_row(Int32(1)), binary_row(Int32(2))])
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT x FROM t")
        cur = DBInterface.execute(stmt; mysql_store_result=false)
        @test Base.IteratorSize(typeof(cur)) == Base.SizeUnknown()
        r1, st = iterate(cur)
        @test r1.x == 1
        r2, st = iterate(cur, st)
        @test r2.x == 2
        @test_throws ArgumentError r1.x               # forward-only: the old row is stale
        @test iterate(cur, st) === nothing
        DBInterface.close!(stmt)
    end
end

@testset "ER_NEED_REPREPARE (1615): one re-prepare, one re-execute" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 10, paramdefs(1), cols)
        expect_execute(c); send_err(c, 1, P.ER_NEED_REPREPARE, "Prepared statement needs re-preparing")
        @test expect_prepare(c) == "SELECT x FROM t WHERE x = ?"    # re-prepared
        send_prepare_ok(c, 1, 11, paramdefs(1), cols)
        @test expect_stmt_close(c) == 10                             # superseded id is released
        payload = expect_execute(c)
        @test execute_new_params_flag(payload, 1) == 0x01           # types re-sent after re-prepare
        send_resultset(c, 1, cols, [binary_row(Int32(5))])
        # a persistent 1615 propagates after the single retry
        expect_execute(c); send_err(c, 1, P.ER_NEED_REPREPARE, "still stale")
        expect_prepare(c); send_prepare_ok(c, 1, 12, paramdefs(1), cols)
        @test expect_stmt_close(c) == 11
        expect_execute(c); send_err(c, 1, P.ER_NEED_REPREPARE, "still stale")
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT x FROM t WHERE x = ?")
        @test Tables.columntable(DBInterface.execute(stmt, (5,))).x == Int32[5]
        @test stmt.statement_id == 11                                # updated to the re-prepared id
        err = try; DBInterface.execute(stmt, (5,)); nothing; catch e; e; end
        @test err isa P.StmtError && err.errno == P.ER_NEED_REPREPARE
        DBInterface.close!(stmt)
    end
end

@testset "reconnect re-prepares a stale statement id" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 20, P.ColumnDef[], cols)
        # after the simulated generation bump the client must re-prepare before executing
        expect_prepare(c); send_prepare_ok(c, 1, 21, P.ColumnDef[], cols)
        expect_execute(c); send_resultset(c, 1, cols, [binary_row(Int32(8))])
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT x FROM t")
        stmt.generation -= 1                                          # as if a reconnect happened
        @test Tables.columntable(DBInterface.execute(stmt)).x == Int32[8]
        @test stmt.statement_id == 21 && stmt.generation == (@atomic conn.generation)
        DBInterface.close!(stmt)
    end
end

@testset "statement close is parked and reaped on the next command" begin
    closed = Ref(UInt32(0))
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 77, P.ColumnDef[], [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)])
        # the next command must be preceded by COM_STMT_CLOSE(77)
        closed[] = expect_stmt_close(c)
        expect_query(c); send_ok(c, 1)
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT x FROM t")
        # Explicit close must wait for a busy reaper lock. It must not drop the id.
        lock(conn.reaplock)
        close_task = errormonitor(Threads.@spawn DBInterface.close!(stmt))
        try
            while !islocked(conn.lock)
                yield()
            end
            @test !istaskdone(close_task)
        finally
            unlock(conn.reaplock)
        end
        wait(close_task)
        @test conn.stmts_to_close === stmt.reap
        DBInterface.close!(stmt)                                     # idempotent
        @test DBInterface.execute(conn, "SELECT 1").rows_affected == 0
        @test conn.stmts_to_close === nothing
    end
    @test closed[] == 77
end

@testset "one-shot execute(conn, sql, params) prepares, executes, then reaps" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 91, paramdefs(1), cols)
        expect_execute(c); send_resultset(c, 1, cols, [binary_row(Int32(2)), binary_row(Int32(4))])
        _, cmd, _ = read_command(c); @test cmd == P.COM_STMT_CLOSE   # reaped before the next command
        expect_query(c); send_ok(c, 1; affected=1)
    end) do conn
        cur = DBInterface.execute(conn, "SELECT x FROM t WHERE x >= ?", (1,))
        @test cur isa N.BinaryCursor && Tables.columntable(cur).x == Int32[2, 4]
        @test DBInterface.execute(conn, "SELECT 1").rows_affected == 1
    end
end

@testset "executemany binds each row in a transaction" begin
    seen = String[]
    execs = Vector{UInt8}[]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 8, paramdefs(1), P.ColumnDef[])
        push!(seen, expect_query(c)); send_ok(c, 1)                  # START TRANSACTION
        for _ in 1:3
            push!(execs, expect_execute(c)); send_ok(c, 1; affected=1)
        end
        push!(seen, expect_query(c)); send_ok(c, 1)                  # COMMIT
    end) do conn
        stmt = DBInterface.prepare(conn, "INSERT INTO t (a) VALUES (?)")
        DBInterface.executemany(stmt, ([10, 20, 30],))
        DBInterface.close!(stmt)
    end
    @test seen == ["START TRANSACTION", "COMMIT"]
    @test length(execs) == 3
    @test execute_new_params_flag(execs[1], 1) == 0x01 && execute_new_params_flag(execs[2], 1) == 0x00
end

@testset "prepared CALL: distinct binary cursors per result" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 30, P.ColumnDef[], cols)
        expect_execute(c)
        seq = send_resultset(c, 1, cols, [binary_row(Int32(1))]; more=true)
        seq = send_resultset(c, seq, cols, [binary_row(Int32(2)), binary_row(Int32(3))]; more=true)
        send_ok(c, seq; affected=0)                                  # CALL's terminating OK
    end) do conn
        stmt = DBInterface.prepare(conn, "CALL p()")
        results = collect(DBInterface.executemultiple(stmt))
        @test length(results) == 3 && length(unique(objectid.(results))) == 3
        @test all(r -> r isa N.BinaryCursor, results)
        @test Tables.columntable(results[1]).x == Int32[1]
        @test Tables.columntable(results[2]).x == Int32[2, 3]
        @test results[3].rows_affected == 0 && isempty(results[3].names)
        DBInterface.close!(stmt)
    end
end

@testset "parameter types round-trip through encode and the binary decoders" begin
    o = N.DEFAULT_RESULT_OPTIONS
    roundtrip(T, x) = begin
        buf = UInt8[]
        N.encode_param_value!(buf, x)
        # strip the length prefix the temporal encoders write, mirroring scan_binary_row!
        if x isa Union{Date, DateTime, MySQL.DateAndTime, Dates.Time}
            len = Int(buf[1])
            return N.decode_binary(T, buf, 2, len, o)
        elseif x isa Union{AbstractString, Vector{UInt8}, MySQL.API.Bit, DecFP.DecimalFloatingPoint}
            c = P.PacketCursor(buf); off, len = P.read_lenenc_window_len!(c, "v")
            return N.decode_binary(T, buf, off, len, o)
        else
            return N.decode_binary(T, buf, 1, length(buf), o)
        end
    end
    @test roundtrip(Int8, Int8(-5)) === Int8(-5)
    @test roundtrip(UInt64, UInt64(9)) === UInt64(9)
    @test roundtrip(Float32, 1.5f0) === 1.5f0
    @test roundtrip(Float64, -2.5) === -2.5
    @test roundtrip(String, "héllo") == "héllo"
    @test roundtrip(Vector{UInt8}, UInt8[1, 2, 3]) == UInt8[1, 2, 3]
    @test roundtrip(MySQL.API.Bit, MySQL.API.Bit(0x7f)) == MySQL.API.Bit(0x7f)   # single-byte (1.x bitvalue under-sizes wider BITs)
    @test roundtrip(Dec64, d64"12.345") == d64"12.345"
    @test roundtrip(Date, Date(2024, 2, 29)) == Date(2024, 2, 29)
    @test roundtrip(DateTime, DateTime(2024, 2, 29, 13, 14, 15, 250)) == DateTime(2024, 2, 29, 13, 14, 15, 250)
    @test roundtrip(MySQL.DateAndTime, MySQL.DateAndTime(Date(2024, 1, 2), Time(1, 2, 3, 456, 789))) == MySQL.DateAndTime(Date(2024, 1, 2), Time(1, 2, 3, 456, 789))
    @test roundtrip(Time, Time(13, 14, 15)) == Time(13, 14, 15)
end

@testset "COM_STMT_SEND_LONG_DATA framing" begin
    sent = Vector{UInt8}[]
    with_native(c -> begin
        for _ in 1:2
            _, cmd, payload = read_command(c)
            @test cmd == P.COM_STMT_SEND_LONG_DATA
            push!(sent, payload)
        end
        expect_query(c); send_ok(c, 1)
    end) do conn
        s = N.session(conn)
        P.stmt_send_long_data!(s, 5, 0, UInt8[0x61, 0x62])
        P.stmt_send_long_data!(s, 5, 0, UInt8[0x63])
        @test DBInterface.execute(conn, "SELECT 1").rows_affected == 0
    end
    @test sent[1] == vcat(reinterpret(UInt8, UInt32[5]), reinterpret(UInt8, UInt16[0]), UInt8[0x61, 0x62])
    @test sent[2] == vcat(reinterpret(UInt8, UInt32[5]), reinterpret(UInt8, UInt16[0]), UInt8[0x63])
end

@testset "prepared response errors retain StmtError" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 51, P.ColumnDef[], cols)
        expect_execute(c)
        send_packet(c, 1, column_count(1))
        send_packet(c, 2, cols[1])
        send_err(c, 3, P.ER_QUERY_INTERRUPTED, "row failed")

        _, cmd, payload = read_command(c)
        @test cmd == P.COM_STMT_RESET
        @test payload == reinterpret(UInt8, UInt32[51])
        send_err(c, 1, 1243, "unknown statement")
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT x FROM t")
        cur = DBInterface.execute(stmt; mysql_store_result=false)
        rowerr = try
            iterate(cur)
            nothing
        catch err
            err
        end
        @test rowerr isa P.StmtError
        @test rowerr.errno == P.ER_QUERY_INTERRUPTED

        s = N.session(conn)
        P.stmt_reset!(s, stmt.statement_id)
        reseterr = try
            P.read_command_response!(s)
            nothing
        catch err
            err
        end
        @test reseterr isa P.StmtError
        @test reseterr.errno == 1243
        DBInterface.close!(stmt)
    end
end

@testset "buffered binary metadata charges its column type table" begin
    col = coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)
    limit = length(col) + 3 * sizeof(Int)
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 70, P.ColumnDef[], P.ColumnDef[])
        expect_execute(c)
        try
            send_resultset(c, 1, [col], Vector{UInt8}[])
        catch
        end
    end; connect_kw=(; max_buffered_bytes=limit)) do conn
        stmt = DBInterface.prepare(conn, "CALL dynamic_metadata()")
        @test_throws P.ProtocolError DBInterface.execute(stmt)
        @test !isopen(conn)
    end
end

@testset "pre-DEPRECATE_EOF prepare reads the definition EOFs" begin
    caps = MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL & ~P.CLIENT_DEPRECATE_EOF
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_prepare(c)
        # legacy servers close each non-empty definition block with its own EOF packet
        hdr = UInt8[0x00]; P.write_u32!(hdr, 44); P.write_u16!(hdr, 1); P.write_u16!(hdr, 1); P.write_u8!(hdr, 0); P.write_u16!(hdr, 0)
        send_packet(c, 1, hdr)
        send_packet(c, 2, paramdefs(1)[1]); send_packet(c, 3, eof_payload())
        send_packet(c, 4, cols[1]); send_packet(c, 5, eof_payload())
        expect_execute(c)
        send_packet(c, 1, column_count(1)); send_packet(c, 2, cols[1]); send_packet(c, 3, eof_payload())
        seq = send_logical(c, 4, binary_row(Int32(6))); send_packet(c, seq, eof_payload())
    end; caps=caps) do conn
        stmt = DBInterface.prepare(conn, "SELECT x FROM t WHERE x = ?")
        @test stmt.nparams == 1 && stmt.names == [:x]
        @test Tables.columntable(DBInterface.execute(stmt, (6,))).x == Int32[6]
        DBInterface.close!(stmt)
    end
end
