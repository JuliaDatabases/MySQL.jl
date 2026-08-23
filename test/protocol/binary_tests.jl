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

function expect_long_data(conn)
    _, cmd, payload = read_command(conn)
    cmd == P.COM_STMT_SEND_LONG_DATA || error("expected COM_STMT_SEND_LONG_DATA, got $cmd")
    length(payload) >= 6 || error("expected a 6-byte long-data header")
    statement_id = UInt32(payload[1]) |
                   (UInt32(payload[2]) << 8) |
                   (UInt32(payload[3]) << 16) |
                   (UInt32(payload[4]) << 24)
    parameter_number = UInt16(payload[5]) | (UInt16(payload[6]) << 8)
    return (statement_id, parameter_number, payload[7:end])
end

function serve_load(conn, table_name::String, column_name::String)
    @test expect_query(conn) == "CREATE TABLE IF NOT EXISTS $table_name ($column_name VARCHAR(255) )"
    send_ok(conn, 1)
    @test expect_query(conn) == "START TRANSACTION"
    send_ok(conn, 1)
    @test expect_prepare(conn) == "INSERT INTO $table_name ($column_name) VALUES (?)"
    send_prepare_ok(conn, 1, 91, paramdefs(1), P.ColumnDef[])
    expect_execute(conn)
    send_ok(conn, 1; affected=1)
    @test expect_stmt_close(conn) == 91
    @test expect_query(conn) == "COMMIT"
    send_ok(conn, 1)
    return nothing
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

execute_null_bitmap(payload, nparams) = payload[10:(9 + ((nparams + 7) >> 3))]

@testset "MySQL.load native identifier and debug policy" begin
    row = NamedTuple{(Symbol("co`l"),)}(("secret-value",))
    with_native(c -> serve_load(c, "`ta``ble`", "`co``l`")) do conn
        @test_logs (:info, r"executing create table statement") (:info, r"executing insert statement") begin
            @test MySQL.load([row], conn, "ta`ble"; debug=true) == "`ta``ble`"
        end
    end
    with_native(c -> serve_load(c, "`ta``ble`", "`co``l`")) do conn
        @test_logs (:info, r"executing create table statement") (:info, r"executing insert statement") (:info, r"(?s)inserting row 1;.*secret-value") begin
            @test MySQL.load([row], conn, "ta`ble"; debug=:values) == "`ta``ble`"
        end
    end
    with_native(c -> nothing) do conn
        @test_throws ArgumentError MySQL.load([row], conn, "ta`ble"; debug=:invalid)
    end
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

@testset "COM_STMT_EXECUTE header shape" begin
    @test P.build_stmt_execute(0x01020304, UInt8[0xaa, 0xbb]) ==
          UInt8[0x04, 0x03, 0x02, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0xaa, 0xbb]
end

@testset "COM_STMT_PREPARE errors and metadata limits" begin
    with_native(c -> begin
        expect_prepare(c)
        send_err(c, 1, 1064, "bad prepared SQL"; sqlstate="42000")
        @test expect_query(c) == "SELECT 1"
        send_ok(c, 1)
    end) do conn
        err = try
            DBInterface.prepare(conn, "bad SQL")
            nothing
        catch caught
            caught
        end
        @test err isa P.StmtError && err.errno == 1064 && err.sqlstate == "42000"
        @test DBInterface.execute(conn, "SELECT 1").rows_affected == 0
    end

    with_native(c -> begin
        expect_prepare(c)
        header = UInt8[0x00]
        P.write_u32!(header, 1)
        P.write_u16!(header, 2)
        P.write_u16!(header, 0)
        P.write_u8!(header, 0)
        P.write_u16!(header, 0)
        send_packet(c, 1, header)
    end; connect_kw=(; max_columns=1)) do conn
        @test_throws P.ProtocolError DBInterface.prepare(conn, "SELECT 1, 2")
        @test !isopen(conn)
    end

    def = coldef("parameter_name"; type=P.MYSQL_TYPE_VAR_STRING)
    with_native(c -> begin
        expect_prepare(c)
        try
            send_prepare_ok(c, 1, 2, [def], P.ColumnDef[])
        catch
        end
    end; connect_kw=(; max_metadata_bytes=length(def) - 1)) do conn
        @test_throws P.ProtocolError DBInterface.prepare(conn, "SELECT ?")
        @test !isopen(conn)
    end
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

    newdate = UInt8[0x00, 0x00, 0x03, 0x6f, 0x6c, 0x64]
    P.scan_binary_row!(UInt8[P.MYSQL_TYPE_NEWDATE], pv(newdate), offsets, lengths)
    @test lengths == [3]
    @test String(newdate[offsets[1]:(offsets[1] + lengths[1] - 1)]) == "old"

    @test_throws P.ProtocolError P.scan_binary_row!(UInt8[P.MYSQL_TYPE_DATETIME], pv(UInt8[0x00, 0x00, 0x03, 0x00, 0x00, 0x00]), Int[], Int[])
    @test_throws P.ProtocolError P.scan_binary_row!(UInt8[P.MYSQL_TYPE_TIME], pv(UInt8[0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), Int[], Int[])
    @test_throws P.ProtocolError P.scan_binary_row!(UInt8[P.MYSQL_TYPE_DATE], pv(UInt8[0x00, 0x00, 0x07, 0xe8, 0x07, 0x02, 0x1d, 0x0d, 0x0e, 0x0f]), Int[], Int[])
    @test_throws P.ProtocolError P.scan_binary_row!(UInt8[P.MYSQL_TYPE_DATE], pv(UInt8[0x00, 0x00, 0x0b, 0xe8, 0x07, 0x02, 0x1d, 0x0d, 0x0e, 0x0f, 0x00, 0x00, 0x00, 0x00]), Int[], Int[])
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
    @test_throws P.ConversionError N.decode_binary(Date, UInt8[0xe8, 0x07, 0x02, 0x1d, 0x0d, 0x0e, 0x0f], 1, 7, o)
    # floats
    @test N.decode_binary(Float32, reinterpret(UInt8, [1.25f0]) |> collect, 1, 4, o) === 1.25f0
    @test N.decode_binary(Float64, reinterpret(UInt8, [-2.5]) |> collect, 1, 8, o) === -2.5
    @test_throws P.ConversionError N.decode_binary(Float64, UInt8[0x00, 0x00, 0x00, 0x00], 1, 4, o)
    @test_throws P.ConversionError N.decode_binary(Float32, UInt8[0x00, 0x00, 0x00, 0x00], 2, 4, o)
    @test_throws P.ConversionError N.decode_binary(Int32, UInt8[0x00, 0x00, 0x00, 0x00], 0, 4, o)
    # string, blob, decimal, BIT (big-endian) share the text content decoders
    @test N.decode_binary(String, Vector{UInt8}(codeunits("héllo")), 1, ncodeunits("héllo"), o) == "héllo"
    @test N.decode_binary(String, UInt8[], 1, 0, o) == ""
    @test_throws P.ConversionError N.decode_binary(String, UInt8[0x61], 2, 1, o)
    @test_throws P.ConversionError N.decode_binary(String, UInt8[0x61], typemax(Int), 0, o)
    @test N.decode_binary(Vector{UInt8}, UInt8[0x00, 0xff], 1, 2, o) == UInt8[0x00, 0xff]
    @test N.decode_binary(Dec64, Vector{UInt8}(codeunits("12.345")), 1, 6, o) == d64"12.345"
    @test N.decode_binary(MySQL.API.Bit, UInt8[0x01, 0x02], 1, 2, o) == MySQL.API.Bit(0x0102)
    @test N.decode_binary(MySQL.API.Bit, fill(0xff, 8), 1, 8, o) == MySQL.API.Bit(typemax(UInt64))
    @test_throws P.ConversionError N.decode_binary(MySQL.API.Bit, fill(0xff, 9), 1, 9, o)
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
    @test_throws P.ConversionError N.decode_binary(Date, bad_clock, 1, 11, o)
    bad_date_micros = vcat(date4, UInt8[0x00, 0x00, 0x00], reinterpret(UInt8, UInt32[1_000_000]))
    @test_throws P.ConversionError N.decode_binary(Date, bad_date_micros, 1, 11, o)
    # invalid length is a conversion error, not an out-of-bounds read
    @test_throws P.ConversionError N.decode_binary(DateTime, UInt8[0x00, 0x00, 0x00], 1, 3, o)
end

@testset "binary zero-date policy matches the text path" begin
    zero = UInt8[]
    @test N.decode_binary(DateTime, zero, 1, 0, N.DEFAULT_RESULT_OPTIONS) == DateTime(0)   # :sentinel
    @test N.decode_binary(Date, zero, 1, 0, N.DEFAULT_RESULT_OPTIONS) == Date(0)
    @test N.decode_binary(Union{Missing, Date}, zero, 1, 0, N.ResultOptions(; zero_dates=:missing)) === missing
    @test_throws P.ConversionError N.decode_binary(DateTime, zero, 1, 0, N.ResultOptions(; zero_dates=:error))
    partial = UInt8[0xE8, 0x07, 0x00, 0x01]   # 2024-00-01
    @test_throws P.ConversionError N.decode_binary(Date, partial, 1, 4, N.DEFAULT_RESULT_OPTIONS)
    @test N.decode_binary(Union{Missing, Date}, partial, 1, 4, N.ResultOptions(; zero_dates=:missing)) === missing
    year0 = UInt8[0x00, 0x00, 0x01, 0x01]   # 0000-01-01: a legal date, not a partial zero
    @test N.decode_binary(Date, year0, 1, 4, N.DEFAULT_RESULT_OPTIONS) == Date(0, 1, 1)
    @test N.decode_binary(Union{Missing, Date}, year0, 1, 4, N.ResultOptions(; zero_dates=:missing)) == Date(0, 1, 1)
    @test N.decode_binary(DateTime, vcat(year0, UInt8[0x17, 0x3B, 0x3B]), 1, 7, N.ResultOptions(; zero_dates=:error)) == DateTime(0, 1, 1, 23, 59, 59)
    malformed_partial = vcat(partial, UInt8[0x18, 0x00, 0x00])
    @test_throws P.ConversionError N.decode_binary(Union{Missing, Date}, malformed_partial, 1, 7, N.ResultOptions(; zero_dates=:missing))
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

    # The execute NULL bitmap uses bit offset 0 at every byte boundary.
    for n in (1, 7, 8, 9, 64)
        values = Any[Int8(1) for _ in 1:n]
        values[end] = missing
        block = N.encode_param_block(values, N.param_signature(values), true)
        nullbytes = (n + 7) >> 3
        expected = zeros(UInt8, nullbytes)
        bit = n - 1
        expected[(bit >> 3) + 1] |= UInt8(1) << (bit & 7)
        @test block[1:nullbytes] == expected
    end

    # A native BIT parameter is the big-endian binary string of its value (no leading zero
    # bytes, at least one byte), matching the native big-endian BIT decode.
    @test N.bit_param_bytes(MySQL.API.Bit(0)) == UInt8[0x00]
    @test N.bit_param_bytes(MySQL.API.Bit(0x7f)) == UInt8[0x7f]
    @test N.bit_param_bytes(MySQL.API.Bit(0x0100)) == UInt8[0x01, 0x00]
    @test N.bit_param_bytes(MySQL.API.Bit(0x01ff)) == UInt8[0x01, 0xff]
    @test N.bit_param_bytes(MySQL.API.Bit(0x0102)) == UInt8[0x01, 0x02]
    @test N.bit_param_bytes(MySQL.API.Bit(0xffff)) == UInt8[0xff, 0xff]
    @test N.bit_param_bytes(MySQL.API.Bit(0x0001_0000_0000)) == UInt8[0x01, 0x00, 0x00, 0x00, 0x00]
    @test N.bit_param_bytes(MySQL.API.Bit(typemax(UInt64))) == fill(0xff, 8)
    @test N.bit_param_bytes(MySQL.API.Bit(0x8000_0000_0000_0000)) == UInt8[0x80, 0, 0, 0, 0, 0, 0, 0]
    bit = MySQL.API.Bit(0x0102)
    bitbuf = UInt8[]
    N.encode_param_value!(bitbuf, bit)
    c = P.PacketCursor(bitbuf)
    off, len = P.read_lenenc_window_len!(c, "Bit parameter")
    @test bitbuf[off:(off + len - 1)] == UInt8[0x01, 0x02]
    # and the text/binary decoders read the same bytes back (BIT round trip)
    @test N.decode(MySQL.API.Bit, bitbuf, off, len, N.ResultOptions()) == bit
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

@testset "parameter signature cache follows NULL type changes" begin
    payloads = Vector{UInt8}[]
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 4, paramdefs(1), P.ColumnDef[])
        for _ in 1:4
            push!(payloads, expect_execute(c))
            send_ok(c, 1)
        end
    end) do conn
        stmt = DBInterface.prepare(conn, "DO ?")
        DBInterface.execute(stmt, (Int32(1),))
        DBInterface.execute(stmt, (missing,))
        DBInterface.execute(stmt, (nothing,))
        DBInterface.execute(stmt, (Int32(2),))
        DBInterface.close!(stmt)
    end
    @test execute_new_params_flag.(payloads, 1) == UInt8[0x01, 0x01, 0x00, 0x01]
    @test [only(execute_null_bitmap(p, 1)) for p in payloads] == UInt8[0x00, 0x01, 0x01, 0x00]
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
    changedcol = coldef("changed"; type=P.MYSQL_TYPE_VAR_STRING, flags=NOT_NULL)
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 61, P.ColumnDef[], [dtcol])
        expect_execute(c)
        send_resultset(c, 1, [changedcol], Vector{UInt8}[];
            status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_METADATA_CHANGED)

        expect_prepare(c)
        send_prepare_ok(c, 1, 62, P.ColumnDef[], P.ColumnDef[])
        expect_execute(c)
        send_resultset(c, 1, [dtcol], Vector{UInt8}[])
        expect_execute(c)
        send_resultset(c, 1, [dtcol], Vector{UInt8}[])
    end) do conn
        static_stmt = DBInterface.prepare(conn, "SELECT CAST(NOW() AS DATETIME) AS dt")
        static_cur = DBInterface.execute(static_stmt; mysql_date_and_time=true)
        @test Tables.schema(static_cur) == Tables.Schema((:changed,), (String,))
        @test static_stmt.names == [:changed] && static_stmt.types == Type[String]
        @test static_stmt.names !== static_cur.names
        @test static_stmt.types !== static_cur.types
        @test static_stmt.lookup !== static_cur.lookup

        dynamic_stmt = DBInterface.prepare(conn, "CALL dynamic_metadata()")
        dynamic_cur = DBInterface.execute(dynamic_stmt; mysql_date_and_time=true)
        @test Tables.schema(dynamic_cur).types == (MySQL.DateAndTime,)
        @test dynamic_stmt.names == [:dt] && dynamic_stmt.types == Type[MySQL.DateAndTime]
        # Caching the execute-time definitions must not turn a dynamic statement into a
        # static one: each execute still honours its own mysql_date_and_time keyword.
        @test Tables.schema(DBInterface.execute(dynamic_stmt)).types == (DateTime,)
        DBInterface.close!(static_stmt)
        DBInterface.close!(dynamic_stmt)
    end

    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 64, paramdefs(1), P.ColumnDef[])
        expect_execute(c)
        send_resultset(c, 1, [dtcol], Vector{UInt8}[])
    end) do conn
        cur = DBInterface.execute(
            conn,
            "CALL dynamic_metadata(?)",
            (1,);
            mysql_date_and_time=true,
        )
        @test Tables.schema(cur).types == (MySQL.DateAndTime,)
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

@testset "binary cursor wrongrow contract in both storage modes" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    for buffered in (true, false)
        with_native(c -> begin
            expect_prepare(c); send_prepare_ok(c, 1, 3, P.ColumnDef[], cols)
            expect_execute(c); send_resultset(c, 1, cols, [binary_row(Int32(1)), binary_row(Int32(2))])
        end) do conn
            stmt = DBInterface.prepare(conn, "SELECT x FROM t")
            cur = DBInterface.execute(stmt; mysql_store_result=buffered)
            expected_size = buffered ? Base.HasLength() : Base.SizeUnknown()
            @test Base.IteratorSize(typeof(cur)) == expected_size
            r1, st = iterate(cur)
            @test r1.x == 1
            r2, st = iterate(cur, st)
            @test r2.x == 2
            @test_throws ArgumentError r1.x           # forward-only: the old row is stale
            @test iterate(cur, st) === nothing
            DBInterface.close!(stmt)
        end
    end
end

@testset "binary NULL and zero-date schema contracts" begin
    notnull = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 5, P.ColumnDef[], notnull)
        expect_execute(c); send_resultset(c, 1, notnull, [binary_row(missing)])
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT x FROM t")
        row = only(DBInterface.execute(stmt))
        @test_throws P.ConversionError row.x
        DBInterface.close!(stmt)
    end

    dates = [
        coldef("d"; type=P.MYSQL_TYPE_DATE, flags=NOT_NULL),
        coldef("dt"; type=P.MYSQL_TYPE_DATETIME, flags=NOT_NULL),
    ]
    zero_and_partial = UInt8[0x00, 0x00, 0x00, 0x04, 0xe8, 0x07, 0x00, 0x01]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 6, P.ColumnDef[], dates)
        expect_execute(c); send_resultset(c, 1, dates, [zero_and_partial])
    end; connect_kw=(; zero_dates=:missing)) do conn
        stmt = DBInterface.prepare(conn, "SELECT d, dt FROM t")
        cur = DBInterface.execute(stmt)
        @test Tables.schema(cur).types == (Union{Missing, Date}, Union{Missing, DateTime})
        row = only(cur)
        @test row.d === missing && row.dt === missing
        DBInterface.close!(stmt)
    end
end

@testset "malformed binary rows fault before retention" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 7, P.ColumnDef[], cols)
        expect_execute(c)
        try
            send_resultset(c, 1, cols, [UInt8[0x00, 0x00, 0x01]])
        catch
        end
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT x FROM t")
        @test_throws P.ProtocolError DBInterface.execute(stmt)
        @test !isopen(conn)
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


    dtcol = coldef("dt"; type=P.MYSQL_TYPE_DATETIME, flags=NOT_NULL)
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 22, P.ColumnDef[], P.ColumnDef[])
        expect_prepare(c)
        send_prepare_ok(c, 1, 23, P.ColumnDef[], [dtcol])
        expect_execute(c)
        send_resultset(c, 1, [dtcol], Vector{UInt8}[])
    end) do conn
        stmt = DBInterface.prepare(conn, "CALL metadata_after_reconnect()")
        stmt.generation -= 1
        cur = DBInterface.execute(stmt; mysql_date_and_time=true)
        @test Tables.schema(cur).types == (DateTime,)
        DBInterface.close!(stmt)
    end
end

@testset "re-prepare validates refreshed parameter metadata" begin
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 24, paramdefs(1), P.ColumnDef[])
        # A reconnect refresh changes the parameter count. The old one-parameter call must
        # stop after PREPARE_OK, before the client sends a malformed COM_STMT_EXECUTE.
        expect_prepare(c)
        send_prepare_ok(c, 1, 25, paramdefs(2), P.ColumnDef[])
        payload = expect_execute(c)
        @test execute_new_params_flag(payload, 2) == 0x01
        send_ok(c, 1)
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT ?")
        stmt.generation -= 1
        @test_throws MySQL.MySQLInterfaceError DBInterface.execute(stmt, (1,))
        @test stmt.nparams == 2 && stmt.statement_id == 25
        @test DBInterface.execute(stmt, (1, 2)).rows_affected == 0
        DBInterface.close!(stmt)
    end

    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 30, paramdefs(1), P.ColumnDef[])
        expect_execute(c)
        send_err(c, 1, P.ER_NEED_REPREPARE, "Prepared statement needs re-preparing")
        expect_prepare(c)
        send_prepare_ok(c, 1, 31, paramdefs(2), P.ColumnDef[])
        @test expect_stmt_close(c) == 30
        payload = expect_execute(c)
        @test execute_new_params_flag(payload, 2) == 0x01
        send_ok(c, 1)
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT ?")
        @test_throws MySQL.MySQLInterfaceError DBInterface.execute(stmt, (1,))
        @test stmt.nparams == 2 && stmt.statement_id == 31
        @test DBInterface.execute(stmt, (1, 2)).rows_affected == 0
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

    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 78, P.ColumnDef[], P.ColumnDef[])
        expect_prepare(c)
        send_prepare_ok(c, 1, 79, P.ColumnDef[], P.ColumnDef[])
    end) do conn
        first = DBInterface.prepare(conn, "SELECT 1")
        second = DBInterface.prepare(conn, "SELECT 2")
        DBInterface.close!(first)
        DBInterface.close!(second)
        @test conn.stmts_to_close === second.reap
        @test second.reap.next === first.reap
        DBInterface.close!(conn)
        @test conn.stmts_to_close === nothing
        @test first.reap.next === nothing && second.reap.next === nothing
        @test !(@atomic conn.statement_reaping_open)
        # A late statement finalizer cannot repopulate a closed connection's queue.
        second.closed = false
        N.finalize_statement(second)
        @test conn.stmts_to_close === nothing
    end
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

    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 92, paramdefs(1), cols)
        expect_execute(c); send_resultset(c, 1, cols, [binary_row(Int32(2)), binary_row(Int32(4))])
        @test expect_stmt_close(c) == 92
        expect_query(c); send_ok(c, 1; affected=1)
    end) do conn
        DBInterface.execute(conn, "SELECT x FROM t WHERE x >= ?", (1,); mysql_store_result=false)
        # begin_command! must drain the unread binary rows before it reaps the one-shot id.
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

@testset "a later prepared result error remains a StmtError" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 32, P.ColumnDef[], cols)
        expect_execute(c)
        seq = send_resultset(c, 1, cols, [binary_row(Int32(1))]; more=true)
        send_err(c, seq, P.ER_QUERY_INTERRUPTED, "later result failed")
        @test expect_query(c) == "SELECT 1"
        send_ok(c, 1)
    end) do conn
        stmt = DBInterface.prepare(conn, "CALL p()")
        results = DBInterface.executemultiple(stmt)
        first, state = iterate(results)
        @test Tables.columntable(first).x == Int32[1]
        err = try
            iterate(results, state)
            nothing
        catch caught
            caught
        end
        @test err isa P.StmtError && err.errno == P.ER_QUERY_INTERRUPTED
        @test DBInterface.execute(conn, "SELECT 1").rows_affected == 0
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
    @test roundtrip(UInt8, typemax(UInt8)) === typemax(UInt8)
    @test roundtrip(Int16, typemin(Int16)) === typemin(Int16)
    @test roundtrip(UInt16, typemax(UInt16)) === typemax(UInt16)
    @test roundtrip(Int32, typemin(Int32)) === typemin(Int32)
    @test roundtrip(UInt32, typemax(UInt32)) === typemax(UInt32)
    @test roundtrip(Int64, typemin(Int64)) === typemin(Int64)
    @test roundtrip(UInt64, UInt64(9)) === UInt64(9)
    @test roundtrip(Float32, 1.5f0) === 1.5f0
    @test roundtrip(Float64, -2.5) === -2.5
    @test roundtrip(String, "héllo") == "héllo"
    @test roundtrip(Vector{UInt8}, UInt8[1, 2, 3]) == UInt8[1, 2, 3]
    @test roundtrip(MySQL.API.Bit, MySQL.API.Bit(0x7f)) == MySQL.API.Bit(0x7f)
    @test roundtrip(MySQL.API.Bit, MySQL.API.Bit(0x0102)) == MySQL.API.Bit(0x0102)
    @test roundtrip(MySQL.API.Bit, MySQL.API.Bit(typemax(UInt64))) == MySQL.API.Bit(typemax(UInt64))
    @test roundtrip(Dec64, d64"12.345") == d64"12.345"
    @test roundtrip(Date, Date(2024, 2, 29)) == Date(2024, 2, 29)
    @test roundtrip(DateTime, DateTime(2024, 2, 29, 13, 14, 15, 250)) == DateTime(2024, 2, 29, 13, 14, 15, 250)
    @test roundtrip(MySQL.DateAndTime, MySQL.DateAndTime(Date(2024, 1, 2), Time(1, 2, 3, 456, 789))) == MySQL.DateAndTime(Date(2024, 1, 2), Time(1, 2, 3, 456, 789))
    @test roundtrip(Time, Time(13, 14, 15)) == Time(13, 14, 15)
    @test roundtrip(Time, Time(13, 14, 15, 250, 500)) == Time(13, 14, 15, 250, 500)

    decimal = Dec128("12345678901234567890123456789.123456")
    encoded_decimal = UInt8[]
    N.encode_param_value!(encoded_decimal, decimal)
    c = P.PacketCursor(encoded_decimal)
    @test P.read_lenenc_string!(c, "Dec128 parameter") == string(decimal)
    @test P.atend(c)
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

@testset "statement long data survives 1615 and reconnect re-prepare" begin
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 80, paramdefs(1), P.ColumnDef[])
        @test expect_long_data(c) == (UInt32(80), UInt16(0), UInt8[0x61, 0x62])
        @test expect_long_data(c) == (UInt32(80), UInt16(0), UInt8[0x63])
        first = expect_execute(c)
        @test execute_new_params_flag(first, 1) == 0x01
        @test length(first) == 13   # header + NULL map + bind flag + type; no inline value
        send_err(c, 1, P.ER_NEED_REPREPARE, "Prepared statement needs re-preparing")
        expect_prepare(c)
        send_prepare_ok(c, 1, 81, paramdefs(1), P.ColumnDef[])
        @test expect_stmt_close(c) == 80
        @test expect_long_data(c) == (UInt32(81), UInt16(0), UInt8[0x61, 0x62])
        @test expect_long_data(c) == (UInt32(81), UInt16(0), UInt8[0x63])
        retry = expect_execute(c)
        @test execute_new_params_flag(retry, 1) == 0x01
        @test length(retry) == 13
        send_ok(c, 1)
    end) do conn
        stmt = DBInterface.prepare(conn, "INSERT INTO t VALUES (?)")
        @test_throws MySQL.MySQLInterfaceError N.send_long_data!(stmt, 1, "out of range")
        chunk = UInt8[0x61, 0x62]
        N.send_long_data!(stmt, 0, chunk)
        N.send_long_data!(stmt, 0, "c")
        chunk[1] = 0x7a   # the retained replay must own its bytes
        @test length(stmt.long_data) == 2
        @test_throws MySQL.MySQLInterfaceError DBInterface.execute(stmt, (Int32(1),))
        DBInterface.execute(stmt, (UInt8[0xff],))
        @test isempty(stmt.long_data)
        DBInterface.close!(stmt)
    end

    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 82, paramdefs(1), P.ColumnDef[])
        @test expect_long_data(c) == (UInt32(82), UInt16(0), UInt8[0x63])
        expect_prepare(c)
        send_prepare_ok(c, 1, 83, paramdefs(1), P.ColumnDef[])
        @test expect_long_data(c) == (UInt32(83), UInt16(0), UInt8[0x63])
        payload = expect_execute(c)
        @test length(payload) == 13
        send_ok(c, 1)
    end) do conn
        stmt = DBInterface.prepare(conn, "INSERT INTO t VALUES (?)")
        N.send_long_data!(stmt, 0, "c")
        stmt.generation -= 1
        DBInterface.execute(stmt, ("ignored",))
        @test stmt.statement_id == 83 && isempty(stmt.long_data)
        DBInterface.close!(stmt)
    end
end

@testset "re-prepare discards out-of-range long data" begin
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 85, paramdefs(2), P.ColumnDef[])
        @test expect_long_data(c) == (UInt32(85), UInt16(1), UInt8[0x73, 0x74, 0x61, 0x6c, 0x65])
        expect_prepare(c)
        send_prepare_ok(c, 1, 86, paramdefs(1), P.ColumnDef[])
        payload = expect_execute(c)
        @test execute_new_params_flag(payload, 1) == 0x01
        send_ok(c, 1)
    end) do conn
        stmt = DBInterface.prepare(conn, "INSERT INTO t VALUES (?, ?)")
        N.send_long_data!(stmt, 1, "stale")
        stmt.generation -= 1
        err = try; DBInterface.execute(stmt, ("keep", "ignored")); nothing; catch e; e; end
        @test err isa MySQL.MySQLInterfaceError
        @test occursin("outside 0:0", sprint(showerror, err))
        @test stmt.nparams == 1 && isempty(stmt.long_data)
        @test DBInterface.execute(stmt, ("inline",)).rows_affected == 0
        DBInterface.close!(stmt)
    end
end

@testset "statement reset clears retained long data" begin
    payload = Ref(UInt8[])
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 84, paramdefs(1), P.ColumnDef[])
        @test expect_long_data(c) == (UInt32(84), UInt16(0), UInt8[0x61])
        _, cmd, reset_payload = read_command(c)
        @test cmd == P.COM_STMT_RESET
        @test reset_payload == reinterpret(UInt8, UInt32[84])
        send_ok(c, 1)
        payload[] = expect_execute(c)
        send_ok(c, 1)
    end) do conn
        stmt = DBInterface.prepare(conn, "INSERT INTO t VALUES (?)")
        N.send_long_data!(stmt, 0, "a")
        N.reset_statement!(stmt)
        @test isempty(stmt.long_data) && stmt.statement_id == 84
        DBInterface.execute(stmt, ("inline",))
        DBInterface.close!(stmt)
    end
    @test length(payload[]) > 13   # reset made the value inline again
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

@testset "COM_STMT_RESET retains the id and cached parameter signature" begin
    payloads = Vector{UInt8}[]
    with_native(c -> begin
        expect_prepare(c)
        send_prepare_ok(c, 1, 52, paramdefs(1), P.ColumnDef[])
        push!(payloads, expect_execute(c))
        send_ok(c, 1)
        _, cmd, payload = read_command(c)
        @test cmd == P.COM_STMT_RESET
        @test payload == reinterpret(UInt8, UInt32[52])
        send_ok(c, 1)
        push!(payloads, expect_execute(c))
        send_ok(c, 1)
    end) do conn
        stmt = DBInterface.prepare(conn, "DO ?")
        DBInterface.execute(stmt, (Int32(1),))
        lock(conn.lock) do
            s = N.session(conn)
            P.stmt_reset!(s, stmt.statement_id)
            @test P.read_command_response!(s) isa P.OKPacket
        end
        @test stmt.statement_id == 52
        DBInterface.execute(stmt, (Int32(2),))
        DBInterface.close!(stmt)
    end
    # RESET clears accumulated long data and cursor state, not the parameter type cache.
    @test execute_new_params_flag.(payloads, 1) == UInt8[0x01, 0x00]
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
