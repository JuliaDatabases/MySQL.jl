# Executable compatibility manifest (plan §4.2): every row runs the same scenario on the
# Connector/C backend (`MySQL.Connection`) and the native backend
# (`MySQL.Native.Connection`) and asserts the row's disposition:
#
#   :preserve  identical observable result on both backends
#   :fix       deliberate, documented difference — the native value is asserted, the 1.x
#              value is recorded (and asserted when `legacy` is given)
#
# Rows are added per milestone; M3 covers the text protocol. The runner needs both
# connections against the same server (the mysql:8.4 live lane).
module CompatManifest

using Test, MySQL, DBInterface, Tables, Dates, DecFP

struct Row
    name::String
    disposition::Symbol
    run::Function            # conn -> value
    native::Any              # expected native value for :fix rows (ignored for :preserve)
    legacy::Any              # expected C value for :fix rows (nothing = not asserted)
    skip_legacy::String      # non-empty: why the scenario must not run on the C backend
end

Row(name, disposition, run; native=nothing, legacy=nothing, skip_legacy="") = Row(name, disposition, run, native, legacy, skip_legacy)

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
    Row("DML cursor: rows_affected, lastrowid, length, empty schema", :preserve,
        conn -> let cur = DBInterface.execute(conn, "INSERT INTO manifest_employee (Name) VALUES ('x'), ('y')")
            res = (cur.rows_affected, Int(DBInterface.lastrowid(cur)) > 0, isempty(Tables.columntable(cur)), Tables.schema(cur).names)
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
    Row("DATETIME with microsecond precision: warn and truncate to milliseconds (1.x warned, then failed)", :fix,
        conn -> try; Tables.columntable(DBInterface.execute(conn, "SELECT CAST('2021-01-02 01:02:03.456789' AS DATETIME(6)) AS dt")).dt; catch e; :error; end;
        native=Union{Missing, DateTime}[DateTime(2021, 1, 2, 1, 2, 3, 456)], legacy=:error),
    Row("mysql_date_and_time=true maps DATETIME(6) to DateAndTime", :preserve,
        conn -> Tables.columntable(DBInterface.execute(conn, "SELECT CAST('2021-01-02 01:02:03.456789' AS DATETIME(6)) AS dt"; mysql_date_and_time=true)).dt),
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
    Row("show format", :preserve,
        conn -> occursin(r"^MySQL\.(Native\.)?Connection\(host=\"[^\"]+\", user=\"root\", port=\"\d+\", db=\"manifest\"\)$", sprint(show, conn))),
)
const TEXT_ROWS = collect(Row, TEXT_ROW_TUPLE)

"""
    run!(make_c, make_native; rows=TEXT_ROWS)

`make_c(; db)`/`make_native(; db)` open fresh connections. Runs every row on both backends
inside `@testset`s.
"""
function run!(make_c::Function, make_native::Function; rows::Vector{Row}=TEXT_ROWS)
    c = make_c(; db="")
    prepare!(c)
    DBInterface.close!(c)
    @testset "compat manifest: $(row.name)" for row in rows
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
    return nothing
end

end # module
