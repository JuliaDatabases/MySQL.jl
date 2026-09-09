# Executable behavior manifest (the 1.x behavior table; docs/src/migration.md is the
# user-facing rendering). Before 2.0 every row ran on both the
# Connector/C and the native backend and asserted the row's disposition; the dual-backend
# runs proved parity, and at 2.0 the manifest became a native-only golden regression suite:
#
#   :preserve  same observable result as MySQL.jl 1.x (proved by the pre-2.0 dual runs)
#   :fix       deliberate, documented 1.x difference (see docs/src/migration.md); the
#              `legacy` value records what 1.x produced
#
# Every row's `expected` value is asserted against mysql:8.4 (the primary live lane).
# Value rows cover text and binary results. Surface rows cover the remaining connection,
# option, security, lifecycle, and API contracts. A coverage assertion maps every manifest row.
module BehaviorManifest

using Test, MySQL, DBInterface, Tables, Dates, DecFP, Logging
const DecimalResult = MySQL.DataDecimals.DecimalValue{MySQL.DataDecimals.Int256}

struct Row
    name::String
    disposition::Symbol
    run::Function            # conn -> value
    expected::Any            # asserted when not `nothing` (goldens; see capture!)
    legacy::Any              # documentation: what 1.x produced for a :fix row
    legacy_note::String      # documentation: why the scenario never ran on Connector/C
end

Row(name, disposition, run; expected=nothing, legacy=nothing, skip_legacy="") = Row(name, disposition, run, expected, legacy, skip_legacy)

struct SurfaceRow
    plan_line::Int
    name::String
    run::Function
    expected::Any
end

function capture_outcome(f::Function)
    try
        return f()
    catch err
        return nameof(typeof(err))
    end
end

function with_connection(f::Function, make::Function; kw...)
    conn = make(; kw...)
    try
        return f(conn)
    finally
        DBInterface.close!(conn)
    end
end

function connection_outcome(make::Function; kw...)
    return capture_outcome(() -> with_connection(_ -> :ok, make; kw...))
end

function query_value(make::Function, sql::AbstractString; kw...)
    return with_connection(make; kw...) do conn
        table = Tables.columntable(DBInterface.execute(conn, sql))
        return only(first(values(table)))
    end
end

const EMPLOYEE_DDL = """CREATE TABLE manifest_employee (
    ID INT NOT NULL AUTO_INCREMENT, OfficeNo TINYINT, DeptNo SMALLINT, EmpNo BIGINT UNSIGNED,
    Wage FLOAT(7,2), Salary DOUBLE, Rate DECIMAL(5, 3), LunchTime TIME, JoinDate DATE,
    LastLogin DATETIME, LastLogin2 TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, Initial CHAR(1),
    Name VARCHAR(255), Photo BLOB, JobType ENUM('HR', 'Management', 'Accounts'), Senior BIT(1),
    Born YEAR, Flags BIT(12), Note TEXT, Raw VARBINARY(8), PRIMARY KEY (ID))"""

const EMPLOYEE_ROWS = """INSERT INTO manifest_employee (OfficeNo, DeptNo, EmpNo, Wage, Salary, Rate, LunchTime, JoinDate, LastLogin, LastLogin2, Initial, Name, Photo, JobType, Senior, Born, Flags, Note, Raw) VALUES
    (1, 2, 1301, 3.14, 10000.50, 1.001, '12:00:00', '2015-8-3', '2015-9-5 12:31:30', '2015-9-5 12:31:30', 'A', 'John', 'abc', 'HR', b'1', 1999, b'101000000001', 'héllo wörld 🐘', X'0102'),
    (1, 2, 18446744073709551615, 3.14, 20000.25, 2.002, '13:00:00', '2015-8-4', '2015-10-12 13:12:14', '2015-10-12 13:12:14', 'B', 'Tom', 'def', 'HR', b'1', 2024, b'1', '', X''),
    (NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2015-9-5 10:05:10', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)"""

# Creates the fixture once per server (idempotent).
function prepare!(conn)
    DBInterface.execute(conn, "CREATE DATABASE IF NOT EXISTS manifest")
    DBInterface.execute(conn, "USE manifest")
    DBInterface.execute(conn, "DROP TABLE IF EXISTS manifest_employee")
    DBInterface.execute(conn, EMPLOYEE_DDL)
    DBInterface.execute(conn, EMPLOYEE_ROWS)
    DBInterface.execute(conn, "DROP PROCEDURE IF EXISTS manifest_proc")
    DBInterface.execute(conn, "CREATE PROCEDURE manifest_proc() BEGIN SELECT ID FROM manifest_employee; SELECT Name FROM manifest_employee; END")
    return nothing
end

schema_pairs(cur) = collect(zip(Tables.schema(cur).names, Tables.schema(cur).types))

function prepared_parameter_roundtrip(conn)
    DBInterface.execute(conn, "DROP TEMPORARY TABLE IF EXISTS manifest_params")
    DBInterface.execute(conn, """CREATE TEMPORARY TABLE manifest_params (
        i8 TINYINT NOT NULL, u8 TINYINT UNSIGNED NOT NULL,
        i16 SMALLINT NOT NULL, u16 SMALLINT UNSIGNED NOT NULL,
        i32 INT NOT NULL, u32 INT UNSIGNED NOT NULL,
        i64 BIGINT NOT NULL, u64 BIGINT UNSIGNED NOT NULL,
        f32 FLOAT NOT NULL, f64 DOUBLE NOT NULL,
        d64 DECIMAL(16, 6) NOT NULL, d128 DECIMAL(35, 6) NOT NULL,
        s VARCHAR(64) NOT NULL, bytes BLOB NOT NULL, bit_bytes BLOB NOT NULL,
        d DATE NOT NULL, dt DATETIME(3) NOT NULL, dat DATETIME(6) NOT NULL,
        tm TIME(6) NOT NULL, m INT NULL, n INT NULL)""")
    stmt = DBInterface.prepare(conn, """INSERT INTO manifest_params VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""")
    try
        DBInterface.execute(stmt, (
            typemin(Int8), typemax(UInt8), typemin(Int16), typemax(UInt16),
            typemin(Int32), typemax(UInt32), typemin(Int64), typemax(UInt64),
            1.5f0, -2.5, d64"12.345678",
            Dec128("12345678901234567890123456789.123456"),
            "héllo", UInt8[0x00, 0xff], MySQL.Bit(0x0102),
            Date(2024, 2, 29), DateTime(2024, 2, 29, 13, 14, 15, 250),
            MySQL.DateAndTime(Date(2024, 2, 29), Time(13, 14, 15, 250, 500)),
            Time(13, 14, 15, 250, 500), missing, nothing,
        ))
    finally
        DBInterface.close!(stmt)
    end
    values = Tables.columntable(DBInterface.execute(conn, """SELECT
        i8, u8, i16, u16, i32, u32, i64, u64, f32, f64,
        CAST(d64 AS CHAR) AS d64, CAST(d128 AS CHAR) AS d128,
        s, HEX(bytes) AS bytes, HEX(bit_bytes) AS bit_bytes,
        DATE_FORMAT(d, '%Y-%m-%d') AS d,
        DATE_FORMAT(dt, '%Y-%m-%d %H:%i:%s.%f') AS dt,
        DATE_FORMAT(dat, '%Y-%m-%d %H:%i:%s.%f') AS dat,
        TIME_FORMAT(tm, '%H:%i:%s.%f') AS tm,
        m IS NULL AS m_null, n IS NULL AS n_null
        FROM manifest_params"""))
    DBInterface.execute(conn, "DROP TEMPORARY TABLE manifest_params")
    # bit_bytes (a Bit parameter) is asserted by its own :fix row: the native encoder is
    # big-endian, the Connector/C encoder little-endian, so they legitimately differ.
    return Base.structdiff(values, NamedTuple{(:bit_bytes,)})
end

# A Bit(0x0102) bound as a BLOB parameter: native writes the big-endian binary string
# (matching the native big-endian BIT decode), Connector/C writes its 1.x `API.bitvalue`.
function prepared_bit_parameter(conn)
    DBInterface.execute(conn, "DROP TEMPORARY TABLE IF EXISTS manifest_bit")
    DBInterface.execute(conn, "CREATE TEMPORARY TABLE manifest_bit (b BLOB NOT NULL)")
    stmt = DBInterface.prepare(conn, "INSERT INTO manifest_bit VALUES (?)")
    try
        DBInterface.execute(stmt, (MySQL.Bit(0x0102),))
    finally
        DBInterface.close!(stmt)
    end
    v = only(Tables.columntable(DBInterface.execute(conn, "SELECT HEX(b) AS b FROM manifest_bit")).b)
    DBInterface.execute(conn, "DROP TEMPORARY TABLE manifest_bit")
    return v
end

function prepared_bool_parameter(conn)
    DBInterface.execute(conn, "SET SESSION SQL_MODE=''")
    DBInterface.execute(conn, "CREATE TEMPORARY TABLE manifest_bool (v BOOL)")
    stmt = DBInterface.prepare(conn, "INSERT INTO manifest_bool VALUES (?)")
    try
        DBInterface.execute(stmt, (true,))
    finally
        DBInterface.close!(stmt)
    end
    value = only(Tables.columntable(DBInterface.execute(conn, "SELECT v FROM manifest_bool")).v)
    DBInterface.execute(conn, "DROP TEMPORARY TABLE manifest_bool")
    return value == 1 ? :one : :zero
end

function prepared_wrongrow(conn)
    stmt = DBInterface.prepare(conn, "SELECT ID FROM manifest_employee ORDER BY ID")
    try
        cur = DBInterface.execute(stmt)
        first, state = iterate(cur)
        iterate(cur, state)
        return try
            first.ID
            (false, "no error")
        catch err
            (err isa ArgumentError, sprint(showerror, err))
        end
    finally
        DBInterface.close!(stmt)
    end
end

function prepared_negative_time(conn)
    stmt = DBInterface.prepare(conn, "SELECT CAST('-01:02:03.000004' AS TIME(6)) AS tm")
    try
        return try
            (:value, only(Tables.columntable(DBInterface.execute(stmt)).tm))
        catch err
            (:error, nameof(typeof(err)))
        end
    finally
        DBInterface.close!(stmt)
    end
end

function prepared_zero_datetime(conn)
    DBInterface.execute(conn, "SET SESSION SQL_MODE=''")
    stmt = DBInterface.prepare(conn, "SELECT CAST('0000-00-00 00:00:00' AS DATETIME) AS dt")
    try
        return only(Tables.columntable(DBInterface.execute(stmt)).dt)
    finally
        DBInterface.close!(stmt)
    end
end

function prepared_call_results(conn)
    stmt = DBInterface.prepare(conn, "CALL manifest_proc()")
    try
        return [Tables.columntable(cur) for cur in DBInterface.executemultiple(stmt)]
    finally
        DBInterface.close!(stmt)
    end
end

function with_option_file(f::Function, password::AbstractString; database::AbstractString="manifest")
    return mktemp() do path, io
        write(io, "[client]\npassword=$password\ndatabase=$database\n")
        close(io)
        Sys.iswindows() || chmod(path, 0o600)
        return f(path)
    end
end

function password_surface(make::Function, password::AbstractString)
    return with_option_file(password) do path
        omitted = connection_outcome(make; passwd=nothing, db=nothing, option_file=path)
        explicit_empty = connection_outcome(make; passwd="", db=nothing, option_file=path)
        return (omitted, explicit_empty)
    end
end

function option_database_surface(make::Function, password::AbstractString)
    return with_option_file(password) do path
        return query_value(make, "SELECT DATABASE() AS db"; passwd=nothing, db=nothing, option_file=path)
    end
end

function environment_surface(make::Function, port::Integer)
    return withenv("MYSQL_TCP_PORT" => string(port)) do
        return connection_outcome(make; port=nothing, read_env=true)
    end
end

function transport_surface(make::Function)
    default = connection_outcome(make; host="localhost")
    tcp = connection_outcome(make; host="localhost", protocol=:tcp)
    return (default, tcp)
end

function multi_statement_surface(make::Function)
    return with_connection(make) do conn
        return capture_outcome(() -> (DBInterface.execute(conn, "SELECT 1; SELECT 2"); :ok))
    end
end

function init_command_surface(make::Function)
    value = query_value(make, "SELECT @manifest_init AS value"; init_command="SET @manifest_init = 17")
    return string(value)
end

function execute_keyword_surface(make::Function)
    return with_connection(make) do conn
        return capture_outcome(() -> (DBInterface.execute(conn, "SELECT 1"; manifest_unknown=true); :ok))
    end
end

function isopen_surface(make::Function)
    conn = make()
    before = isopen(conn)
    DBInterface.close!(conn)
    return (before, isopen(conn))
end

function load_identifier_surface(make::Function)
    return with_connection(make; db="manifest") do conn
        name = "manifest`load"
        result = with_logger(Logging.NullLogger()) do
            return capture_outcome(() -> (MySQL.load([(value=17,)], conn, name); :ok))
        end
        quoted = replace(name, "`" => "``")
        try
            DBInterface.execute(conn, "DROP TABLE IF EXISTS `$quoted`")
        catch
        end
        return result
    end
end

function load_debug_surface(make::Function)
    return with_connection(make; db="manifest") do conn
        name = "manifest_debug"
        logger = Test.TestLogger(; min_level=Logging.Info)
        try
            with_logger(logger) do
                MySQL.load([(secret="manifest-secret",)], conn, name; debug=true)
            end
            return any(record -> occursin("manifest-secret", string(record.message)), logger.logs)
        finally
            DBInterface.execute(conn, "DROP TABLE IF EXISTS `$name`")
        end
    end
end

function error_surface(make::Function)
    return with_connection(make; db="manifest") do conn
        err = try
            DBInterface.execute(conn, "SELECT * FROM manifest_missing_table")
            nothing
        catch caught
            caught
        end
        return (nameof(typeof(err)), propertynames(err), typeof(err.errno) === Cuint, startswith(sprint(showerror, err), "("))
    end
end

function cleanup_surface(make::Function)
    conn = make()
    DBInterface.close!(conn)
    DBInterface.close!(conn)
    return !isopen(conn)
end

function native_thread_surface(make::Function)
    return with_connection(make; db="manifest") do conn
        tasks = [errormonitor(Threads.@spawn begin
            return only(Tables.columntable(DBInterface.execute(conn, "SELECT $i AS value")).value)
        end) for i in 1:2]
        return sort!(fetch.(tasks))
    end
end

function one_shot_parameter_surface(make::Function)
    return with_connection(make) do conn
        value = only(Tables.columntable(DBInterface.execute(conn, "SELECT ? AS value", (17,))).value)
        return string(value)
    end
end

function api_surface(make::Function)
    query = string(query_value(make, "SELECT 1 AS value"))
    return (query, isdefined(MySQL, :Bit) && MySQL.Error === MySQL.Protocol.Error, !isdefined(MySQL, :API))
end

# A tuple, not an array literal: `end` inside `[...]` is the last-index token, which breaks
# `begin ... end` closure bodies.
const TEXT_ROW_TUPLE = (
    Row("select *: Tables.schema (type mapping incl. BIGINT UNSIGNED, YEAR, BIT, TEXT, VARBINARY)", :fix,
        conn -> schema_pairs(DBInterface.execute(conn, "SELECT * FROM manifest_employee"))),
    Row("select *: columntable values (NULLs, exact decimals, Time, Date, DateTime, blob, enum, single-byte BIT, utf8mb4 text)", :fix,
        conn -> let t = Tables.columntable(DBInterface.execute(conn, "SELECT * FROM manifest_employee"))
            Base.structdiff(t, NamedTuple{(:Flags,)})   # multi-byte BIT is a :fix row below
        end),
    Row("BIT(12) decoding: big-endian value of all bytes (1.x read the first byte only)", :fix,
        conn -> Tables.columntable(DBInterface.execute(conn, "SELECT Flags FROM manifest_employee")).Flags;
        expected=Union{Missing, MySQL.Bit}[MySQL.Bit(0b101000000001), MySQL.Bit(1), missing],
        legacy=Union{Missing, MySQL.Bit}[MySQL.Bit(0b00001010), MySQL.Bit(0), missing]),
    Row("streaming (mysql_store_result=false) yields the same rows", :preserve,
        conn -> [(r.ID, r.Name) for r in DBInterface.execute(conn, "SELECT ID, Name FROM manifest_employee"; mysql_store_result=false)]),
    Row("row is valid only while current: ArgumentError text", :preserve,
        conn -> let cur = DBInterface.execute(conn, "SELECT ID FROM manifest_employee")
            r1, st = iterate(cur)
            iterate(cur, st)
            try; r1.ID; "no error"; catch e; (typeof(e) <: ArgumentError, e.msg); end
        end),
    Row("DML cursor: rows_affected, lastrowid, length, and empty schema", :preserve,
        conn -> let cur = DBInterface.execute(conn, "INSERT INTO manifest_employee (Name) VALUES ('x'), ('y')")
            res = (cur.rows_affected, Int(DBInterface.lastrowid(cur)) > 0, length(cur), isempty(Tables.columntable(cur)), Tables.schema(cur).names)
            DBInterface.execute(conn, "DELETE FROM manifest_employee WHERE Name IN ('x', 'y')")
            res
        end),
    Row("lastrowid on a SELECT cursor: snapshot of the cursor's own terminator (1.x: sticky connection state)", :fix,
        conn -> begin
            DBInterface.execute(conn, "INSERT INTO manifest_employee (Name) VALUES ('z')")
            v = Int(DBInterface.lastrowid(DBInterface.execute(conn, "SELECT ID FROM manifest_employee")))
            DBInterface.execute(conn, "DELETE FROM manifest_employee WHERE Name = 'z'")
            v == 0 ? :zero : :sticky
        end; expected=:zero, legacy=:sticky),
    Row("server error keeps the connection usable; errno and showerror format", :preserve,
        conn -> let err = try; DBInterface.execute(conn, "SELECT * FROM does_not_exist"); nothing; catch e; e; end
            (err.errno, sprint(showerror, err), Tables.columntable(DBInterface.execute(conn, "SELECT 1 AS one")).one)
        end),
    Row("CALL: first result via execute, remaining results drained by the next command", :preserve,
        conn -> let a = Tables.columntable(DBInterface.execute(conn, "CALL manifest_proc()"))
            b = Tables.columntable(DBInterface.execute(conn, "SELECT 2 AS two"))
            (a, b)
        end),
    Row("executemultiple over CALL: every result as a cursor; DML/OK results are cursors too (1.x skipped them)", :fix,
        conn -> [Tables.columntable(c) for c in DBInterface.executemultiple(conn, "CALL manifest_proc()")];
        expected=[(ID = Int32[1, 2, 3],), (Name = Union{Missing, String}["John", "Tom", missing],), NamedTuple()],
        skip_legacy="1.6.0 calls mysql_num_rows(NULL) on the CALL's final OK result and segfaults"),
    Row("escape honours the connection", :preserve,
        conn -> MySQL.escape(conn, "a'b\\c\n")),
    Row("zero DATETIME under SQL_MODE='' decodes to the DateTime(0) sentinel", :preserve,
        conn -> begin
            DBInterface.execute(conn, "SET SESSION SQL_MODE=''")
            Tables.columntable(DBInterface.execute(conn, "SELECT CAST('0000-00-00' AS DATETIME) AS dt")).dt
        end),
    Row("zero DATE: sentinel Date(0) on both protocols (1.x text DATE failed to parse)", :fix,
        conn -> begin
            DBInterface.execute(conn, "SET SESSION SQL_MODE=''")
            try; Tables.columntable(DBInterface.execute(conn, "SELECT CAST('0000-00-00' AS DATE) AS d")).d; catch e; :error; end
        end; expected=Union{Missing, Date}[Date(0)], legacy=:error),
    Row("DATETIME with sub-millisecond precision warns and truncates to ms (1.x text failed)", :fix,
        conn -> try; Tables.columntable(DBInterface.execute(conn, "SELECT CAST('2021-01-02 01:02:03.456789' AS DATETIME(6)) AS dt")).dt; catch; :error; end;
        legacy=:error),
    Row("mysql_date_and_time=true maps DATETIME(6) to DateAndTime", :preserve,
        conn -> Tables.columntable(DBInterface.execute(conn, "SELECT CAST('2021-01-02 01:02:03.456789' AS DATETIME(6)) AS dt"; mysql_date_and_time=true)).dt),
    Row("DateAndTime scales a short DATETIME(1) fraction (1.x read it as an unscaled microsecond count)", :fix,
        conn -> Tables.columntable(DBInterface.execute(conn, "SELECT CAST('2021-01-02 01:02:03.4' AS DATETIME(1)) AS dt"; mysql_date_and_time=true)).dt;
        legacy=Union{Missing, DateAndTime}[DateAndTime(Dates.Date("2021-01-02"), Dates.Time(1, 2, 3, 0, 4))]),
    Row("transaction returns f()'s value and commits", :preserve,
        conn -> begin
            v = DBInterface.transaction(conn) do
                DBInterface.execute(conn, "INSERT INTO manifest_employee (Name) VALUES ('tx')")
                7
            end
            n = Tables.columntable(DBInterface.execute(conn, "SELECT COUNT(*) AS c FROM manifest_employee WHERE Name = 'tx'")).c[1]
            DBInterface.execute(conn, "DELETE FROM manifest_employee WHERE Name = 'tx'")
            (v, n)
        end),
    Row("cursor close is idempotent and a closed cursor iterates empty", :preserve,
        conn -> let cur = DBInterface.execute(conn, "SELECT ID FROM manifest_employee LIMIT 1")
            DBInterface.close!(cur)
            DBInterface.close!(cur)
            iterate(cur) === nothing
        end),
    Row("show format", :preserve,
        conn -> occursin(r"^MySQL\.Connection\(host=\"[^\"]+\", user=\"root\", port=\d+, db=\"manifest\"\)$", sprint(show, conn))),
)
const TEXT_ROWS = collect(Row, TEXT_ROW_TUPLE)

# M4: the same scenarios over the binary protocol (prepared statements). `run` uses
# `DBInterface.prepare`/`execute(stmt, params)`/`executemany`, which both backends provide.
const BINARY_ROW_TUPLE = (
    Row("prepared SELECT schema mirrors the text mapping", :fix,
        conn -> let stmt = DBInterface.prepare(conn, "SELECT ID, EmpNo, Salary, Rate, Name, JoinDate, LastLogin, LunchTime, Photo, JobType, Senior, Born FROM manifest_employee")
            sch = Tables.schema(DBInterface.execute(stmt))
            DBInterface.close!(stmt)
            collect(zip(sch.names, sch.types))
        end),
    Row("prepared SELECT decodes values (ints, DOUBLE, exact decimals, Date, DateTime, Time, blob, enum, single-byte BIT, YEAR)", :fix,
        conn -> let stmt = DBInterface.prepare(conn, "SELECT OfficeNo, EmpNo, Salary, Rate, JoinDate, LastLogin, LunchTime, Photo, JobType, Senior, Born FROM manifest_employee ORDER BY ID")
            t = Tables.columntable(DBInterface.execute(stmt))
            DBInterface.close!(stmt)
            t
        end),
    Row("prepared WHERE with a bound parameter filters rows", :preserve,
        conn -> let stmt = DBInterface.prepare(conn, "SELECT ID FROM manifest_employee WHERE EmpNo = ? ORDER BY ID")
            v = Tables.columntable(DBInterface.execute(stmt, (1301,))).ID
            DBInterface.close!(stmt)
            v
        end),
    Row("prepared row is valid only while current: ArgumentError text", :preserve,
        prepared_wrongrow),
    Row("prepared INSERT/SELECT round-trips bound parameters (int, float, string, date, time, blob)", :preserve,
        conn -> begin
            ins = DBInterface.prepare(conn, "INSERT INTO manifest_employee (OfficeNo, Wage, Name, JoinDate, LunchTime, Photo) VALUES (?, ?, ?, ?, ?, ?)")
            DBInterface.execute(ins, (Int8(7), 1.5f0, "prep", Date(2020, 1, 2), Time(9, 30, 0), UInt8[0x01, 0x02]))
            DBInterface.close!(ins)
            sel = DBInterface.prepare(conn, "SELECT OfficeNo, Wage, Name, JoinDate, LunchTime, Photo FROM manifest_employee WHERE Name = ?")
            r = Tables.columntable(DBInterface.execute(sel, ("prep",)))
            DBInterface.close!(sel)
            DBInterface.execute(conn, "DELETE FROM manifest_employee WHERE Name = 'prep'")
            r
        end),
    Row("prepared parameters round-trip every supported non-Bool family", :preserve,
        prepared_parameter_roundtrip),
    Row("prepared Bit parameter: native writes the big-endian binary string (1.x bitvalue is little-endian and under-sized)", :fix,
        prepared_bit_parameter; expected="0102"),
    Row("prepared Bool uses TINY instead of the 1.x empty-STRING fallback", :fix,
        prepared_bool_parameter; expected=:one, legacy=:zero),
    Row("prepared negative TIME honours the sign and applies the Dates.Time range policy", :fix,
        prepared_negative_time;
        expected=(:error, :ConversionError),
        legacy=(:value, Time(1, 2, 3, 0, 4))),
    Row("prepared zero DATETIME follows the unified zero-date sentinel policy", :fix,
        prepared_zero_datetime;
        expected=DateTime(0),
        legacy=DateTime(1970, 1, 1)),
    Row("executemany bulk-inserts each parameter row in a transaction", :preserve,
        conn -> begin
            DBInterface.execute(conn, "CREATE TEMPORARY TABLE manifest_many (a INT, b VARCHAR(8))")
            stmt = DBInterface.prepare(conn, "INSERT INTO manifest_many (a, b) VALUES (?, ?)")
            DBInterface.executemany(stmt, ([1, 2, 3], ["x", "y", "z"]))
            DBInterface.close!(stmt)
            r = Tables.columntable(DBInterface.execute(conn, "SELECT a, b FROM manifest_many ORDER BY a"))
            DBInterface.execute(conn, "DROP TEMPORARY TABLE manifest_many")
            r
        end),
    Row("prepared executemultiple over CALL returns each result and the final OK", :fix,
        prepared_call_results;
        expected=[(ID = Int32[1, 2, 3],), (Name = Union{Missing, String}["John", "Tom", missing],), NamedTuple()],
        skip_legacy="1.6.0 does not provide the prepared multi-result contract and can call mysql_num_rows(NULL) on CALL's final OK"),
    Row("prepared DATETIME(6) → DateTime warns and truncates to ms", :preserve,
        conn -> let stmt = DBInterface.prepare(conn, "SELECT CAST('2021-01-02 01:02:03.456789' AS DATETIME(6)) AS dt")
            v = try; Tables.columntable(DBInterface.execute(stmt)).dt; catch; :error; end
            DBInterface.close!(stmt)
            v
        end),
    Row("prepared mysql_date_and_time=true maps DATETIME(6) to DateAndTime", :preserve,
        conn -> let stmt = DBInterface.prepare(conn, "SELECT CAST('2021-01-02 01:02:03.456789' AS DATETIME(6)) AS dt"; mysql_date_and_time=true)
            v = Tables.columntable(DBInterface.execute(stmt)).dt
            DBInterface.close!(stmt)
            v
        end),
    Row("prepared execute-time mysql_date_and_time cannot override static prepare metadata", :preserve,
        conn -> let stmt = DBInterface.prepare(conn, "SELECT CAST('2021-01-02 01:02:03' AS DATETIME) AS dt")
            T = only(Tables.schema(DBInterface.execute(stmt; mysql_date_and_time=true)).types)
            DBInterface.close!(stmt)
            T
        end),
    Row("prepared BIT(12): big-endian value of all bytes (1.x prepared read a shifted subset)", :fix,
        conn -> let stmt = DBInterface.prepare(conn, "SELECT Flags FROM manifest_employee ORDER BY ID")
            v = Tables.columntable(DBInterface.execute(stmt)).Flags
            DBInterface.close!(stmt)
            v
        end; expected=Union{Missing, MySQL.Bit}[MySQL.Bit(0b101000000001), MySQL.Bit(1), missing]),
)
const BINARY_ROWS = collect(Row, BINARY_ROW_TUPLE)
const ALL_ROWS = vcat(TEXT_ROWS, BINARY_ROWS)

# Decimal result rows now use DataDecimals and are marked :fix; 1.x used Dec64.
# Golden values for the other rows predate 2.0 as `:preserve` rows (their values were
# proved equal to Connector/C by the pre-2.0 dual-backend manifest runs). Captured against
# mysql:8.4 with `capture!`; `run!` asserts `row.expected`, falling back to this table.
const GOLDENS = Dict{String, Any}(
    "select *: Tables.schema (type mapping incl. BIGINT UNSIGNED, YEAR, BIT, TEXT, VARBINARY)" =>
        Tuple{Symbol, Type}[(:ID, Int32), (:OfficeNo, Union{Missing, Int8}), (:DeptNo, Union{Missing, Int16}), (:EmpNo, Union{Missing, UInt64}), (:Wage, Union{Missing, Float32}), (:Salary, Union{Missing, Float64}), (:Rate, Union{Missing, DecimalResult}), (:LunchTime, Union{Missing, Dates.Time}), (:JoinDate, Union{Missing, Dates.Date}), (:LastLogin, Union{Missing, Dates.DateTime}), (:LastLogin2, Dates.DateTime), (:Initial, Union{Missing, String}), (:Name, Union{Missing, String}), (:Photo, Union{Missing, Vector{UInt8}}), (:JobType, Union{Missing, String}), (:Senior, Union{Missing, MySQL.Bit}), (:Born, Union{Missing, UInt64}), (:Flags, Union{Missing, MySQL.Bit}), (:Note, Union{Missing, String}), (:Raw, Union{Missing, String})],
    "select *: columntable values (NULLs, exact decimals, Time, Date, DateTime, blob, enum, single-byte BIT, utf8mb4 text)" =>
        (ID = Int32[1, 2, 3], OfficeNo = Union{Missing, Int8}[1, 1, missing], DeptNo = Union{Missing, Int16}[2, 2, missing], EmpNo = Union{Missing, UInt64}[0x0000000000000515, 0xffffffffffffffff, missing], Wage = Union{Missing, Float32}[3.14f0, 3.14f0, missing], Salary = Union{Missing, Float64}[10000.5, 20000.25, missing], Rate = Union{Missing, DecimalResult}[DecimalResult("1.001"), DecimalResult("2.002"), missing], LunchTime = Union{Missing, Dates.Time}[Dates.Time(12), Dates.Time(13), missing], JoinDate = Union{Missing, Dates.Date}[Dates.Date("2015-08-03"), Dates.Date("2015-08-04"), missing], LastLogin = Union{Missing, Dates.DateTime}[Dates.DateTime("2015-09-05T12:31:30"), Dates.DateTime("2015-10-12T13:12:14"), missing], LastLogin2 = Dates.DateTime[Dates.DateTime("2015-09-05T12:31:30"), Dates.DateTime("2015-10-12T13:12:14"), Dates.DateTime("2015-09-05T10:05:10")], Initial = Union{Missing, String}["A", "B", missing], Name = Union{Missing, String}["John", "Tom", missing], Photo = Union{Missing, Vector{UInt8}}[UInt8[0x61, 0x62, 0x63], UInt8[0x64, 0x65, 0x66], missing], JobType = Union{Missing, String}["HR", "HR", missing], Senior = Union{Missing, MySQL.Bit}[MySQL.Bit(0x0000000000000001), MySQL.Bit(0x0000000000000001), missing], Born = Union{Missing, UInt64}[0x00000000000007cf, 0x00000000000007e8, missing], Note = Union{Missing, String}["héllo wörld 🐘", "", missing], Raw = Union{Missing, String}["\x01\x02", "", missing]),
    "streaming (mysql_store_result=false) yields the same rows" =>
        Tuple{Int32, Any}[(1, "John"), (2, "Tom"), (3, missing)],
    "row is valid only while current: ArgumentError text" =>
        (true, "row 1 is no longer valid; mysql results are forward-only iterators where each row is only valid when iterated"),
    "DML cursor: rows_affected, lastrowid, length, and empty schema" =>
        (2, true, -1, true, ()),
    "server error keeps the connection usable; errno and showerror format" =>
        (0x0000047a, "(1146): Table 'manifest.does_not_exist' doesn't exist", Int64[1]),
    "CALL: first result via execute, remaining results drained by the next command" =>
        ((ID = Int32[1, 2, 3],), (two = Int64[2],)),
    "escape honours the connection" =>
        "a\\'b\\\\c\\n",
    "zero DATETIME under SQL_MODE='' decodes to the DateTime(0) sentinel" =>
        Union{Missing, Dates.DateTime}[Dates.DateTime("0000-01-01T00:00:00")],
    "DATETIME with sub-millisecond precision warns and truncates to ms (1.x text failed)" =>
        Union{Missing, Dates.DateTime}[Dates.DateTime("2021-01-02T01:02:03.456")],
    "mysql_date_and_time=true maps DATETIME(6) to DateAndTime" =>
        Union{Missing, DateAndTime}[DateAndTime(Dates.Date("2021-01-02"), Dates.Time(1, 2, 3, 456, 789))],
    "DateAndTime scales a short DATETIME(1) fraction (1.x read it as an unscaled microsecond count)" =>
        Union{Missing, DateAndTime}[DateAndTime(Dates.Date("2021-01-02"), Dates.Time(1, 2, 3, 400, 0))],
    "transaction returns f()'s value and commits" =>
        (7, 1),
    "cursor close is idempotent and a closed cursor iterates empty" =>
        true,
    "show format" =>
        true,
    "prepared SELECT schema mirrors the text mapping" =>
        Tuple{Symbol, Type}[(:ID, Int32), (:EmpNo, Union{Missing, UInt64}), (:Salary, Union{Missing, Float64}), (:Rate, Union{Missing, DecimalResult}), (:Name, Union{Missing, String}), (:JoinDate, Union{Missing, Dates.Date}), (:LastLogin, Union{Missing, Dates.DateTime}), (:LunchTime, Union{Missing, Dates.Time}), (:Photo, Union{Missing, Vector{UInt8}}), (:JobType, Union{Missing, String}), (:Senior, Union{Missing, MySQL.Bit}), (:Born, Union{Missing, UInt64})],
    "prepared SELECT decodes values (ints, DOUBLE, exact decimals, Date, DateTime, Time, blob, enum, single-byte BIT, YEAR)" =>
        (OfficeNo = Union{Missing, Int8}[1, 1, missing], EmpNo = Union{Missing, UInt64}[0x0000000000000515, 0xffffffffffffffff, missing], Salary = Union{Missing, Float64}[10000.5, 20000.25, missing], Rate = Union{Missing, DecimalResult}[DecimalResult("1.001"), DecimalResult("2.002"), missing], JoinDate = Union{Missing, Dates.Date}[Dates.Date("2015-08-03"), Dates.Date("2015-08-04"), missing], LastLogin = Union{Missing, Dates.DateTime}[Dates.DateTime("2015-09-05T12:31:30"), Dates.DateTime("2015-10-12T13:12:14"), missing], LunchTime = Union{Missing, Dates.Time}[Dates.Time(12), Dates.Time(13), missing], Photo = Union{Missing, Vector{UInt8}}[UInt8[0x61, 0x62, 0x63], UInt8[0x64, 0x65, 0x66], missing], JobType = Union{Missing, String}["HR", "HR", missing], Senior = Union{Missing, MySQL.Bit}[MySQL.Bit(0x0000000000000001), MySQL.Bit(0x0000000000000001), missing], Born = Union{Missing, UInt64}[0x00000000000007cf, 0x00000000000007e8, missing]),
    "prepared WHERE with a bound parameter filters rows" =>
        Int32[1],
    "prepared row is valid only while current: ArgumentError text" =>
        (true, "ArgumentError: row 1 is no longer valid; mysql results are forward-only iterators where each row is only valid when iterated"),
    "prepared INSERT/SELECT round-trips bound parameters (int, float, string, date, time, blob)" =>
        (OfficeNo = Union{Missing, Int8}[7], Wage = Union{Missing, Float32}[1.5f0], Name = Union{Missing, String}["prep"], JoinDate = Union{Missing, Dates.Date}[Dates.Date("2020-01-02")], LunchTime = Union{Missing, Dates.Time}[Dates.Time(9, 30)], Photo = Union{Missing, Vector{UInt8}}[UInt8[0x01, 0x02]]),
    "prepared parameters round-trip every supported non-Bool family" =>
        (i8 = Int8[-128], u8 = UInt8[0xff], i16 = Int16[-32768], u16 = UInt16[0xffff], i32 = Int32[-2147483648], u32 = UInt32[0xffffffff], i64 = Int64[-9223372036854775808], u64 = UInt64[0xffffffffffffffff], f32 = Float32[1.5f0], f64 = Float64[-2.5], d64 = Union{Missing, String}["12.345678"], d128 = Union{Missing, String}["12345678901234567890123456789.123460"], s = String["héllo"], bytes = Union{Missing, String}["00FF"], d = Union{Missing, String}["2024-02-29"], dt = Union{Missing, String}["2024-02-29 13:14:15.250000"], dat = Union{Missing, String}["2024-02-29 13:14:15.250500"], tm = Union{Missing, String}["13:14:15.250500"], m_null = Int64[1], n_null = Int64[1]),
    "executemany bulk-inserts each parameter row in a transaction" =>
        (a = Union{Missing, Int32}[1, 2, 3], b = Union{Missing, String}["x", "y", "z"]),
    "prepared DATETIME(6) → DateTime warns and truncates to ms" =>
        Union{Missing, Dates.DateTime}[Dates.DateTime("2021-01-02T01:02:03.456")],
    "prepared mysql_date_and_time=true maps DATETIME(6) to DateAndTime" =>
        Union{Missing, DateAndTime}[DateAndTime(Dates.Date("2021-01-02"), Dates.Time(1, 2, 3, 456, 789))],
    "prepared execute-time mysql_date_and_time cannot override static prepare metadata" =>
        Union{Missing, Dates.DateTime},
)

const SURFACE_ROWS = SurfaceRow[
    SurfaceRow(163, "connect shape and mysql:// host stripping",
        (make, _, _) -> string(query_value(make, "SELECT 1 AS value"; host="mysql://127.0.0.1")), "1"),
    SurfaceRow(164, "nothing and empty passwords stay distinct with option files",
        (make, password, _) -> password_surface(make, password), (:ok, :Error)),
    SurfaceRow(165, "MYSQL_TCP_PORT is opt-in via read_env and MYSQL_PWD is never used",
        (make, _, port) -> environment_surface(make, port), :ok),
    SurfaceRow(166, "option-file database fallback",
        (make, password, _) -> option_database_surface(make, password), "manifest"),
    SurfaceRow(167, "localhost is dialed over TCP (with and without protocol=:tcp)",
        (make, _, _) -> transport_surface(make), (:ok, :ok)),
    SurfaceRow(168, "a unix_socket path is accepted and reserved; TCP is used",
        (make, _, _) -> connection_outcome(make; host="localhost", unix_socket="/nonexistent/mysql.sock"), :ok),
    SurfaceRow(169, "multi-statements are disabled by default",
        (make, _, _) -> multi_statement_surface(make), :Error),
    SurfaceRow(170, "unknown connection keywords",
        (make, _, _) -> connection_outcome(make; manifest_unknown=true), :ArgumentError),
    SurfaceRow(171, "init_command runs before the connection is returned",
        (make, _, _) -> init_command_surface(make), "17"),
    SurfaceRow(172, "connect read and write timeouts",
        (make, _, _) -> connection_outcome(make; connect_timeout=10, read_timeout=10, write_timeout=10), :ok),
    SurfaceRow(173, "reconnect option is accepted",
        (make, _, _) -> connection_outcome(make; reconnect=true), :ok),
    SurfaceRow(174, "data_truncation compatibility option warns but connects",
        (make, _, _) -> connection_outcome(make; data_truncation=true), :ok),
    SurfaceRow(175, "charset directory removal and utf8mb4 restriction",
        (make, _, _) -> (connection_outcome(make; charset_dir="/tmp"), connection_outcome(make; charset_name="utf8mb4")), (:ArgumentError, :ok)),
    SurfaceRow(176, "client bind address",
        (make, _, _) -> connection_outcome(make; bind="127.0.0.1"), :ok),
    SurfaceRow(177, "packet and buffer limit options",
        (make, _, _) -> (connection_outcome(make; max_allowed_packet=16 * 1024 * 1024), connection_outcome(make; net_buffer_length=16 * 1024)), (:ok, :ok)),
    SurfaceRow(178, "protocol selection including rejected shared memory",
        (make, _, _) -> (connection_outcome(make; protocol=:tcp), connection_outcome(make; protocol=:memory)), (:ok, :ArgumentError)),
    SurfaceRow(179, "client certificate keyword surface",
        (make, _, _) -> connection_outcome(make; ssl_key=nothing, ssl_cert=nothing), :ok),
    SurfaceRow(180, "combined CA file and directory conflict",
        (make, _, _) -> connection_outcome(make; ssl_ca="unused", ssl_capath="unused"), :ArgumentError),
    SurfaceRow(181, "removed TLS options",
        (make, _, _) -> connection_outcome(make; ssl_cipher="DEFAULT"), :ArgumentError),
    SurfaceRow(182, "SSL mode and contradiction table",
        (make, _, _) -> (connection_outcome(make; ssl_mode=:required), connection_outcome(make; ssl_mode=:disabled, ssl_enforce=true)), (:ok, :ArgumentError)),
    SurfaceRow(183, "default authentication plugin",
        (make, _, _) -> connection_outcome(make; default_auth="mysql_native_password"), :ok),
    SurfaceRow(184, "secure_auth compatibility option warns but connects",
        (make, _, _) -> connection_outcome(make; secure_auth=true), :ok),
    SurfaceRow(185, "server public-key and native security options",
        (make, _, _) -> connection_outcome(make; get_server_public_key=false), :ok),
    SurfaceRow(186, "dynamic plugin options are removed",
        (make, _, _) -> connection_outcome(make; plugin_dir=""), :ArgumentError),
    SurfaceRow(188, "one-shot prepared execution",
        (make, _, _) -> one_shot_parameter_surface(make), "17"),
    SurfaceRow(189, "execute rejects SQL parameters as keywords",
        (make, _, _) -> execute_keyword_surface(make), :MethodError),
    SurfaceRow(200, "isopen local-state contract",
        (make, _, _) -> isopen_surface(make), (true, false)),
    SurfaceRow(202, "load identifier quoting",
        (make, _, _) -> load_identifier_surface(make), :ok),
    SurfaceRow(203, "load debug value logging policy",
        (make, _, _) -> load_debug_surface(make), false),
    SurfaceRow(205, "error hierarchy shape and compatibility fields",
        (make, _, _) -> error_surface(make), (:Error, (:errno, :msg, :sqlstate), true, true)),
    SurfaceRow(206, "public API value namespace and C handle removal",
        (make, _, _) -> api_surface(make), ("1", true, true)),
    SurfaceRow(207, "idempotent cleanup",
        (make, _, _) -> cleanup_surface(make), true),
    SurfaceRow(208, "connection serialization across tasks",
        (make, _, _) -> native_thread_surface(make), [1, 2]),
    SurfaceRow(209, "deferred transport fails explicitly",
        (make, _, _) -> connection_outcome(make; protocol=:socket), :ArgumentError),
    SurfaceRow(210, "Julia 1.10 compatibility floor",
        (make, _, _) -> (VERSION >= v"1.10", string(query_value(make, "SELECT 1 AS value"))), (true, "1")),
]

const VALUE_SURFACE_EVIDENCE = Dict(
    187 => "select *: Tables.schema (type mapping incl. BIGINT UNSIGNED, YEAR, BIT, TEXT, VARBINARY)",
    190 => "executemany bulk-inserts each parameter row in a transaction",
    191 => "executemultiple over CALL: every result as a cursor; DML/OK results are cursors too (1.x skipped them)",
    192 => "prepared SELECT schema mirrors the text mapping",
    193 => "prepared parameters round-trip every supported non-Bool family",
    194 => "prepared SELECT schema mirrors the text mapping",
    195 => "BIT(12) decoding: big-endian value of all bytes (1.x read the first byte only)",
    196 => "prepared negative TIME honours the sign and applies the Dates.Time range policy",
    197 => "zero DATE: sentinel Date(0) on both protocols (1.x text DATE failed to parse)",
    198 => "lastrowid on a SELECT cursor: snapshot of the cursor's own terminator (1.x: sticky connection state)",
    199 => "cursor close is idempotent and a closed cursor iterates empty",
    201 => "show format",
    204 => "transaction returns f()'s value and commits",
)

"""
    run!(make; password, port)

`make(; kw...)` opens a fresh connection. Runs every §4.2 row and asserts its golden
`expected` value; rows with `expected === nothing` only assert that the scenario runs.
Use `capture!(make)` to print `repr` values for baking new goldens.
"""
function run!(make::Function; password::AbstractString, port::Integer)
    row_names = Set(row.name for row in ALL_ROWS)
    @testset "behavior manifest coverage" begin
        @test all(name -> name in row_names, values(VALUE_SURFACE_EVIDENCE))
        surface_lines = Int[row.plan_line for row in SURFACE_ROWS]
        @test length(unique(surface_lines)) == length(surface_lines)
        @test union(Set(surface_lines), Set(keys(VALUE_SURFACE_EVIDENCE))) == Set(163:210)
        # every value row asserts a golden (either inline `expected` or the GOLDENS table)
        @test all(row -> row.expected !== nothing || haskey(GOLDENS, row.name), ALL_ROWS)
        @test all(name -> any(row -> row.name == name, ALL_ROWS), keys(GOLDENS))
    end
    c = make(; db="")
    prepare!(c)
    DBInterface.close!(c)
    @testset "behavior manifest: $(row.name)" for row in ALL_ROWS
        conn = make(; db="manifest")
        try
            value = try; row.run(conn); catch e; (:threw, sprint(showerror, e)); end
            expected = row.expected === nothing ? get(GOLDENS, row.name, nothing) : row.expected
            if expected === nothing
                threw = value isa Tuple && length(value) == 2 && value[1] === :threw
                @test !threw
                threw && @error "manifest row threw" row=row.name value
            else
                @test isequal(value, expected)
                isequal(value, expected) || @error "manifest golden mismatch" row=row.name value expected
            end
        finally
            DBInterface.close!(conn)
        end
    end
    @testset "behavior manifest §4.2 line $(row.plan_line): $(row.name)" for row in SURFACE_ROWS
        value = try
            row.run(make, password, port)
        catch err
            (:unexpected, nameof(typeof(err)), sprint(showerror, err))
        end
        @test isequal(value, row.expected)
        isequal(value, row.expected) || @error "manifest surface mismatch" plan_line=row.plan_line row=row.name actual=value expected=row.expected
    end
    return nothing
end

# `repr` that survives an eval round trip for every value the rows produce (`MySQL.Bit`
# and `Dec64` print forms that do not).
golden_repr(x) = repr(x)
golden_repr(x::MySQL.Bit) = "MySQL.Bit(" * repr(x.bits) * ")"
golden_repr(x::Dec64) = "d64\"" * string(x) * "\""
golden_repr(x::Missing) = "missing"
golden_repr(v::AbstractVector{UInt8}) = repr(v)
golden_repr(v::AbstractVector) = string(eltype(v)) * "[" * join(map(golden_repr, v), ", ") * "]"
golden_repr(t::Tuple) = "(" * join(map(golden_repr, t), ", ") * (length(t) == 1 ? ",)" : ")")
golden_repr(nt::NamedTuple) = isempty(nt) ? "NamedTuple()" : "(" * join(["$k = $(golden_repr(v))" for (k, v) in pairs(nt)], ", ") * (length(nt) == 1 ? ",)" : ")")

"""
    capture!(make)

Prints `name => golden` for every value row whose golden `expected` is not recorded yet,
ready to paste into the row definitions.
"""
function capture!(make::Function)
    c = make(; db="")
    prepare!(c)
    DBInterface.close!(c)
    for row in ALL_ROWS
        (row.expected === nothing && !haskey(GOLDENS, row.name)) || continue
        conn = make(; db="manifest")
        try
            value = try; row.run(conn); catch e; (:threw, sprint(showerror, e)); end
            println(repr(row.name), " =>\n    ", golden_repr(value), ",")
        finally
            DBInterface.close!(conn)
        end
    end
    return nothing
end

end # module
