# Executable compatibility manifest (plan §4.2): every row runs the same scenario on the
# Connector/C backend (`MySQL.Connection`) and the native backend
# (`MySQL.Native.Connection`) and asserts the row's disposition:
#
#   :preserve  identical observable result on both backends
#   :fix       deliberate, documented difference — the native value is asserted, the 1.x
#              value is recorded (and asserted when `legacy` is given)
#
# Value rows cover text and binary results. Surface rows cover the remaining connection,
# option, security, lifecycle, and API contracts. A coverage assertion maps every plan row.
module CompatManifest

using Test, MySQL, DBInterface, Tables, Dates, DecFP, Logging

struct Row
    name::String
    disposition::Symbol
    run::Function            # conn -> value
    native::Any              # expected native value for :fix rows (ignored for :preserve)
    legacy::Any              # expected C value for :fix rows (nothing = not asserted)
    skip_legacy::String      # non-empty: why the scenario must not run on the C backend
end

Row(name, disposition, run; native=nothing, legacy=nothing, skip_legacy="") = Row(name, disposition, run, native, legacy, skip_legacy)

struct SurfaceRow
    plan_line::Int
    name::String
    legacy::Function
    native::Function
    legacy_expected::Any
    native_expected::Any
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
            "héllo", UInt8[0x00, 0xff], MySQL.API.Bit(0x0102),
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
        DBInterface.execute(stmt, (MySQL.API.Bit(0x0102),))
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

function password_surface(make::Function, password::AbstractString, native::Bool)
    return with_option_file(password) do path
        db = native ? nothing : ""
        omitted = connection_outcome(make; passwd=nothing, db=db, option_file=path)
        explicit_empty = connection_outcome(make; passwd="", db=db, option_file=path)
        return (omitted, explicit_empty)
    end
end

function option_database_surface(make::Function, password::AbstractString, native::Bool)
    return with_option_file(password) do path
        db = native ? nothing : ""
        return query_value(make, "SELECT DATABASE() AS db"; passwd=nothing, db=db, option_file=path)
    end
end

function environment_surface(make::Function, port::Integer; native::Bool)
    return withenv("MYSQL_TCP_PORT" => string(port)) do
        options = native ? (; port=nothing, read_env=true) : (; port=nothing)
        return connection_outcome(make; options...)
    end
end

function transport_surface(make::Function; native::Bool)
    default = connection_outcome(make; host="localhost")
    tcp = connection_outcome(make; host="localhost", protocol=MySQL.API.MYSQL_PROTOCOL_TCP)
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

function api_surface(make::Function; native::Bool)
    query = string(query_value(make, "SELECT 1 AS value"))
    if native
        return (query, isdefined(MySQL.Protocol, :Error), !isdefined(MySQL.Protocol, :MYSQL))
    end
    return (query, isdefined(MySQL.API, :Bit), isdefined(MySQL.API, :MYSQL))
end

# A tuple, not an array literal: `end` inside `[...]` is the last-index token, which breaks
# `begin ... end` closure bodies.
const TEXT_ROW_TUPLE = (
    Row("select *: Tables.schema (type mapping incl. BIGINT UNSIGNED, YEAR, BIT, TEXT, VARBINARY)", :preserve,
        conn -> schema_pairs(DBInterface.execute(conn, "SELECT * FROM manifest_employee"))),
    Row("select *: columntable values (NULLs, Dec64, Time, Date, DateTime, blob, enum, single-byte BIT, utf8mb4 text)", :preserve,
        conn -> let t = Tables.columntable(DBInterface.execute(conn, "SELECT * FROM manifest_employee"))
            Base.structdiff(t, NamedTuple{(:Flags,)})   # multi-byte BIT is a :fix row below
        end),
    Row("BIT(12) decoding: big-endian value of all bytes (1.x read the first byte only)", :fix,
        conn -> Tables.columntable(DBInterface.execute(conn, "SELECT Flags FROM manifest_employee")).Flags;
        native=Union{Missing, MySQL.API.Bit}[MySQL.API.Bit(0b101000000001), MySQL.API.Bit(1), missing],
        legacy=Union{Missing, MySQL.API.Bit}[MySQL.API.Bit(0b00001010), MySQL.API.Bit(0), missing]),
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
        end; native=:zero, legacy=:sticky),
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
        native=[(ID = Int32[1, 2, 3],), (Name = Union{Missing, String}["John", "Tom", missing],), NamedTuple()],
        skip_legacy="1.6.0 calls mysql_num_rows(NULL) on the CALL's final OK result and segfaults"),
    Row("escape honours the connection", :preserve,
        conn -> (conn isa MySQL.Connection ? MySQL.escape(conn, "a'b\\c\n") : MySQL.Native.escape(conn, "a'b\\c\n"))),
    Row("zero DATETIME under SQL_MODE='' decodes to the DateTime(0) sentinel", :preserve,
        conn -> begin
            DBInterface.execute(conn, "SET SESSION SQL_MODE=''")
            Tables.columntable(DBInterface.execute(conn, "SELECT CAST('0000-00-00' AS DATETIME) AS dt")).dt
        end),
    Row("zero DATE: sentinel Date(0) on both protocols (1.x text DATE failed to parse)", :fix,
        conn -> begin
            DBInterface.execute(conn, "SET SESSION SQL_MODE=''")
            try; Tables.columntable(DBInterface.execute(conn, "SELECT CAST('0000-00-00' AS DATE) AS d")).d; catch e; :error; end
        end; native=Union{Missing, Date}[Date(0)], legacy=:error),
    Row("DATETIME with sub-millisecond precision warns and fails", :preserve,
        conn -> try; Tables.columntable(DBInterface.execute(conn, "SELECT CAST('2021-01-02 01:02:03.456789' AS DATETIME(6)) AS dt")).dt; catch; :error; end),
    Row("mysql_date_and_time=true maps DATETIME(6) to DateAndTime", :preserve,
        conn -> Tables.columntable(DBInterface.execute(conn, "SELECT CAST('2021-01-02 01:02:03.456789' AS DATETIME(6)) AS dt"; mysql_date_and_time=true)).dt),
    Row("DateAndTime preserves the 1.x unscaled DATETIME(1) fraction", :preserve,
        conn -> Tables.columntable(DBInterface.execute(conn, "SELECT CAST('2021-01-02 01:02:03.4' AS DATETIME(1)) AS dt"; mysql_date_and_time=true)).dt),
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
        conn -> occursin(r"^MySQL\.(Native\.)?Connection\(host=\"[^\"]+\", user=\"root\", port=\"\d+\", db=\"manifest\"\)$", sprint(show, conn))),
)
const TEXT_ROWS = collect(Row, TEXT_ROW_TUPLE)

# M4: the same scenarios over the binary protocol (prepared statements). `run` uses
# `DBInterface.prepare`/`execute(stmt, params)`/`executemany`, which both backends provide.
const BINARY_ROW_TUPLE = (
    Row("prepared SELECT schema mirrors the text mapping", :preserve,
        conn -> let stmt = DBInterface.prepare(conn, "SELECT ID, EmpNo, Salary, Rate, Name, JoinDate, LastLogin, LunchTime, Photo, JobType, Senior, Born FROM manifest_employee")
            sch = Tables.schema(DBInterface.execute(stmt))
            DBInterface.close!(stmt)
            collect(zip(sch.names, sch.types))
        end),
    Row("prepared SELECT decodes values (ints, DOUBLE, Dec64, Date, DateTime, Time, blob, enum, single-byte BIT, YEAR)", :preserve,
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
        prepared_bit_parameter; native="0102"),
    Row("prepared Bool uses TINY instead of the 1.x empty-STRING fallback", :fix,
        prepared_bool_parameter; native=:one, legacy=:zero),
    Row("prepared negative TIME honours the sign and applies the Dates.Time range policy", :fix,
        prepared_negative_time;
        native=(:error, :ConversionError),
        legacy=(:value, Time(1, 2, 3, 0, 4))),
    Row("prepared zero DATETIME follows the unified zero-date sentinel policy", :fix,
        prepared_zero_datetime;
        native=DateTime(0),
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
        native=[(ID = Int32[1, 2, 3],), (Name = Union{Missing, String}["John", "Tom", missing],), NamedTuple()],
        skip_legacy="1.6.0 does not provide the prepared multi-result contract and can call mysql_num_rows(NULL) on CALL's final OK"),
    Row("prepared DATETIME(6) → DateTime warns and truncates to ms (1.x prepared quirk; the text path fails)", :preserve,
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
        end; native=Union{Missing, MySQL.API.Bit}[MySQL.API.Bit(0b101000000001), MySQL.API.Bit(1), missing]),
)
const BINARY_ROWS = collect(Row, BINARY_ROW_TUPLE)
const ALL_ROWS = vcat(TEXT_ROWS, BINARY_ROWS)

const SURFACE_ROWS = SurfaceRow[
    SurfaceRow(163, "connect shape and mysql:// host stripping",
        (make, _, _) -> string(query_value(make, "SELECT 1 AS value"; host="mysql://127.0.0.1")),
        (make, _, _) -> string(query_value(make, "SELECT 1 AS value"; host="mysql://127.0.0.1")), "1", "1"),
    SurfaceRow(164, "nothing and empty passwords stay distinct with option files",
        (make, password, _) -> password_surface(make, password, false),
        (make, password, _) -> password_surface(make, password, true), (:ok, :Error), (:ok, :Error)),
    SurfaceRow(165, "MYSQL_TCP_PORT is native opt-in and MYSQL_PWD is never used",
        (make, _, port) -> environment_surface(make, port; native=false),
        (make, _, port) -> environment_surface(make, port; native=true), :Error, :ok),
    SurfaceRow(166, "option-file database fallback",
        (make, password, _) -> option_database_surface(make, password, false),
        (make, password, _) -> option_database_surface(make, password, true), "manifest", "manifest"),
    SurfaceRow(167, "default local transport does not fall back to TCP",
        (make, _, _) -> transport_surface(make; native=false),
        (make, _, _) -> transport_surface(make; native=true), (:Error, :ok), (:ArgumentError, :ok)),
    SurfaceRow(168, "strict TLS on a deferred local transport fails clearly",
        (make, _, _) -> connection_outcome(make; host="localhost", ssl_mode=MySQL.API.SSL_MODE_REQUIRED),
        (make, _, _) -> connection_outcome(make; host="localhost", ssl_mode=:required), :Error, :ArgumentError),
    SurfaceRow(169, "multi-statements default changes from enabled to disabled",
        (make, _, _) -> multi_statement_surface(make),
        (make, _, _) -> multi_statement_surface(make), :ok, :Error),
    SurfaceRow(170, "unknown connection keywords",
        (make, _, _) -> connection_outcome(make; manifest_unknown=true),
        (make, _, _) -> connection_outcome(make; manifest_unknown=true), :ok, :ArgumentError),
    SurfaceRow(171, "init_command runs before the connection is returned",
        (make, _, _) -> init_command_surface(make),
        (make, _, _) -> init_command_surface(make), "17", "17"),
    SurfaceRow(172, "connect read and write timeouts",
        (make, _, _) -> connection_outcome(make; connect_timeout=10, read_timeout=10, write_timeout=10),
        (make, _, _) -> connection_outcome(make; connect_timeout=10, read_timeout=10, write_timeout=10), :ok, :ok),
    SurfaceRow(173, "reconnect option is accepted on both backends",
        (make, _, _) -> connection_outcome(make; reconnect=true),
        (make, _, _) -> connection_outcome(make; reconnect=true), :ok, :ok),
    SurfaceRow(174, "data_truncation compatibility option",
        (make, _, _) -> connection_outcome(make; data_truncation=true),
        (make, _, _) -> connection_outcome(make; data_truncation=true), :ok, :ok),
    SurfaceRow(175, "charset directory removal and utf8mb4 restriction",
        (make, _, _) -> (connection_outcome(make; charset_dir="/tmp"), connection_outcome(make; charset_name="utf8mb4")),
        (make, _, _) -> (connection_outcome(make; charset_dir="/tmp"), connection_outcome(make; charset_name="utf8mb4")), (:ok, :ok), (:ArgumentError, :ok)),
    SurfaceRow(176, "client bind address",
        (make, _, _) -> connection_outcome(make; bind="127.0.0.1"),
        (make, _, _) -> connection_outcome(make; bind="127.0.0.1"), :ok, :ok),
    SurfaceRow(177, "packet and buffer limit options",
        (make, _, _) -> (connection_outcome(make; max_allowed_packet=16 * 1024 * 1024), connection_outcome(make; net_buffer_length=16 * 1024)),
        (make, _, _) -> (connection_outcome(make; max_allowed_packet=16 * 1024 * 1024), connection_outcome(make; net_buffer_length=16 * 1024)), (:ok, :ok), (:ok, :ok)),
    SurfaceRow(178, "protocol enum including rejected shared memory",
        (make, _, _) -> (connection_outcome(make; protocol=MySQL.API.MYSQL_PROTOCOL_TCP), connection_outcome(make; protocol=MySQL.API.MYSQL_PROTOCOL_MEMORY)),
        (make, _, _) -> (connection_outcome(make; protocol=MySQL.API.MYSQL_PROTOCOL_TCP), connection_outcome(make; protocol=MySQL.API.MYSQL_PROTOCOL_MEMORY)), (:ok, :Error), (:ok, :ArgumentError)),
    SurfaceRow(179, "client certificate keyword surface",
        (make, _, _) -> connection_outcome(make; ssl_key=nothing, ssl_cert=nothing),
        (make, _, _) -> connection_outcome(make; ssl_key=nothing, ssl_cert=nothing), :ok, :ok),
    SurfaceRow(180, "combined CA file and directory conflict",
        (make, _, _) -> connection_outcome(make; ssl_ca=nothing, ssl_capath=nothing),
        (make, _, _) -> connection_outcome(make; ssl_ca="unused", ssl_capath="unused"), :ok, :ArgumentError),
    SurfaceRow(181, "removed TLS options",
        (make, _, _) -> connection_outcome(make; ssl_cipher="DEFAULT"),
        (make, _, _) -> connection_outcome(make; ssl_cipher="DEFAULT"), :ok, :ArgumentError),
    SurfaceRow(182, "SSL mode and contradiction table",
        (make, _, _) -> (connection_outcome(make; ssl_mode=MySQL.API.SSL_MODE_REQUIRED), connection_outcome(make; ssl_mode=MySQL.API.SSL_MODE_DISABLED, ssl_enforce=true)),
        (make, _, _) -> (connection_outcome(make; ssl_mode=MySQL.API.SSL_MODE_REQUIRED), connection_outcome(make; ssl_mode=MySQL.API.SSL_MODE_DISABLED, ssl_enforce=true)), (:ok, :ok), (:ok, :ArgumentError)),
    SurfaceRow(183, "default authentication plugin",
        (make, _, _) -> connection_outcome(make; default_auth="mysql_native_password"),
        (make, _, _) -> connection_outcome(make; default_auth="mysql_native_password"), :ok, :ok),
    SurfaceRow(184, "secure_auth compatibility option",
        (make, _, _) -> connection_outcome(make; secure_auth=true),
        (make, _, _) -> connection_outcome(make; secure_auth=true), :MethodError, :ok),
    SurfaceRow(185, "server public-key and native security options",
        (make, _, _) -> connection_outcome(make; get_server_public_key=false),
        (make, _, _) -> connection_outcome(make; get_server_public_key=false), :ok, :ok),
    SurfaceRow(186, "dynamic plugin options are removed",
        (make, _, _) -> connection_outcome(make; plugin_dir=""),
        (make, _, _) -> connection_outcome(make; plugin_dir=""), :ok, :ArgumentError),
    SurfaceRow(188, "one-shot prepared execution",
        (make, _, _) -> one_shot_parameter_surface(make),
        (make, _, _) -> one_shot_parameter_surface(make), "17", "17"),
    SurfaceRow(189, "execute rejects SQL parameters as keywords",
        (make, _, _) -> execute_keyword_surface(make),
        (make, _, _) -> execute_keyword_surface(make), :MethodError, :MethodError),
    SurfaceRow(200, "isopen local-state contract",
        (make, _, _) -> isopen_surface(make),
        (make, _, _) -> isopen_surface(make), (true, false), (true, false)),
    SurfaceRow(202, "load identifier quoting",
        (make, _, _) -> load_identifier_surface(make),
        (make, _, _) -> load_identifier_surface(make), :StmtError, :ok),
    SurfaceRow(203, "load debug value logging policy",
        (make, _, _) -> load_debug_surface(make),
        (make, _, _) -> load_debug_surface(make), true, false),
    SurfaceRow(205, "error hierarchy shape and compatibility fields",
        (make, _, _) -> error_surface(make),
        (make, _, _) -> error_surface(make), (:Error, (:errno, :msg), true, true), (:Error, (:errno, :msg, :sqlstate), true, true)),
    SurfaceRow(206, "public API value namespace and native handle removal",
        (make, _, _) -> api_surface(make; native=false),
        (make, _, _) -> api_surface(make; native=true), ("1", true, true), ("1", true, true)),
    SurfaceRow(207, "idempotent cleanup",
        (make, _, _) -> cleanup_surface(make),
        (make, _, _) -> cleanup_surface(make), true, true),
    SurfaceRow(208, "native connection serialization",
        (make, _, _) -> string(query_value(make, "SELECT 1 AS value")),
        (make, _, _) -> native_thread_surface(make), "1", [1, 2]),
    SurfaceRow(209, "deferred transport fails explicitly",
        (make, _, _) -> connection_outcome(make; protocol=MySQL.API.MYSQL_PROTOCOL_SOCKET),
        (make, _, _) -> connection_outcome(make; protocol=MySQL.API.MYSQL_PROTOCOL_SOCKET), :ok, :ArgumentError),
    SurfaceRow(210, "Julia 1.10 compatibility floor",
        (make, _, _) -> (VERSION >= v"1.10", string(query_value(make, "SELECT 1 AS value"))),
        (make, _, _) -> (VERSION >= v"1.10", string(query_value(make, "SELECT 1 AS value"))), (true, "1"), (true, "1")),
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
    run!(make_c, make_native; password, port)

`make_c(; kw...)`/`make_native(; kw...)` open fresh connections. Runs every §4.2 surface
row, including the text and prepared-statement value rows, on both backends.
"""
function run!(make_c::Function, make_native::Function; password::AbstractString, port::Integer)
    row_names = Set(row.name for row in ALL_ROWS)
    @testset "compat manifest coverage" begin
        @test all(name -> name in row_names, values(VALUE_SURFACE_EVIDENCE))
        surface_lines = Int[row.plan_line for row in SURFACE_ROWS]
        @test length(unique(surface_lines)) == length(surface_lines)
        @test union(Set(surface_lines), Set(keys(VALUE_SURFACE_EVIDENCE))) == Set(163:210)
    end
    c = make_c(; db="")
    prepare!(c)
    DBInterface.close!(c)
    @testset "compat manifest: $(row.name)" for row in ALL_ROWS
        cconn = make_c(; db="manifest")
        nconn = make_native(; db="manifest")
        try
            legacy = isempty(row.skip_legacy) ? (try; row.run(cconn); catch e; (:threw, sprint(showerror, e)); end) : (:skipped, row.skip_legacy)
            native = try; row.run(nconn); catch e; (:threw, sprint(showerror, e)); end
            if row.disposition == :preserve
                @test isequal(native, legacy)
                isequal(native, legacy) || @error "manifest divergence" row=row.name native legacy
            else
                @test isequal(native, row.native)
                isequal(native, row.native) || @error "manifest fix row mismatch" row=row.name native expected=row.native
                (row.legacy === nothing || !isempty(row.skip_legacy)) || (@test isequal(legacy, row.legacy))
            end
        finally
            DBInterface.close!(cconn)
            DBInterface.close!(nconn)
        end
    end
    @testset "compat manifest §4.2 line $(row.plan_line): $(row.name)" for row in SURFACE_ROWS
        legacy = try
            row.legacy(make_c, password, port)
        catch err
            (:unexpected, nameof(typeof(err)), sprint(showerror, err))
        end
        native = try
            row.native(make_native, password, port)
        catch err
            (:unexpected, nameof(typeof(err)), sprint(showerror, err))
        end
        @test isequal(legacy, row.legacy_expected)
        @test isequal(native, row.native_expected)
        isequal(legacy, row.legacy_expected) || @error "legacy manifest surface mismatch" plan_line=row.plan_line row=row.name actual=legacy expected=row.legacy_expected
        isequal(native, row.native_expected) || @error "native manifest surface mismatch" plan_line=row.plan_line row=row.name actual=native expected=row.native_expected
    end
    return nothing
end

end # module
