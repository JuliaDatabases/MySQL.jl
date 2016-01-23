include("test_common.jl")

const DataFrameResultsPrep = DataFrame(
    ID=[1, 2, 3, 4, 5], 
    Name=@data(["John", "Tom", "Jim", "Tim", NA]),
    Salary=@data([10000.5, 20000.5, 25000.0, 25000.0, NA]),
    JoinDate=@data([convert(Date, "2015-8-3"), convert(Date, "2015-8-4"),
              convert(Date, "2015-6-2"), convert(Date, "2015-7-25"), NA]),
    LastLogin=@data([convert(DateTime, "2015-9-5 12:31:30"),
               convert(DateTime, "2015-10-12 13:12:14"),
               convert(DateTime, "2015-9-5 10:5:10"),
               convert(DateTime, "2015-10-10 12:12:25"), NA]),
    LunchTime=@data([convert(DateTime, "12:0:0"), convert(DateTime, "13:0:0"),
               convert(DateTime, "12:30:0"), convert(DateTime, "12:30:0"), NA]),
    OfficeNo=@data([1, 12, 45, 56, NA]),
    JobType=@data([NA, NA, NA, NA, NA]),
    Senior=@data([NA, NA, NA, NA, NA]),
    empno=@data([1301, 1422, 1567, 3200, NA]))

@compat const ArrayResultsPrep = Array{Any}[
    [1, Nullable("John"), Nullable(10000.5f0), Nullable(convert(Date, "2015-08-03")),
     Nullable(convert(DateTime, "2015-09-05 12:31:30")),
     Nullable(convert(DateTime, "1970-01-01 12:00:00")),
     Nullable(Int8(1)), Nullable{AbstractString}(), Nullable{UInt8}(), Nullable(Int16(1301))],

    [2, Nullable("Tom"), Nullable(20000.25f0), Nullable(convert(Date, "2015-08-04")),
     Nullable(convert(DateTime, "2015-10-12 13:12:14")),
     Nullable(convert(DateTime, "1970-01-01 13:00:00")),
     Nullable(Int8(12)), Nullable{AbstractString}(), Nullable{UInt8}(), Nullable(Int16(1422))],

    [3, Nullable("Jim"), Nullable(25000.0f0), Nullable(convert(Date, "2015-06-02")),
     Nullable(convert(DateTime, "2015-09-05 10:05:10")),
     Nullable(convert(DateTime, "1970-01-01 12:30:00")),
     Nullable(Int8(45)), Nullable{AbstractString}(), Nullable{UInt8}(), Nullable(Int16(1567))],

    [4, Nullable("Tim"), Nullable(25000.0f0), Nullable(convert(Date, "2015-07-25")),
     Nullable(convert(DateTime, "2015-10-10 12:12:25")),
     Nullable(convert(DateTime, "1970-01-01 12:30:00")),
     Nullable(Int8(56)), Nullable{AbstractString}(), Nullable{UInt8}(), Nullable(Int16(3200))],

    [5, Nullable{AbstractString}(), Nullable{Float32}(), Nullable{Date}(),
     Nullable{DateTime}(), Nullable{DateTime}(),
     Nullable{Int8}(), Nullable{AbstractString}(), Nullable{UInt8}(), Nullable{Int16}()]]

function run_query_helper(command, msg)
    stmt = mysql_stmt_init(hndl)
    mysql_stmt_prepare(stmt, command)
    mysql_execute_query(stmt)
    mysql_stmt_close(stmt)
    println("Success: " * msg)
    return true
end

function update_values()
    command = """UPDATE Employee SET Salary = ? WHERE ID > ?;"""
    stmt = mysql_stmt_init(hndl)
    mysql_stmt_prepare(stmt, command)
    affrows = mysql_execute_query(stmt, [MYSQL_TYPE_FLOAT, MYSQL_TYPE_LONG], [25000, 2])
    println("Affected rows after update_values(): $affrows")
    mysql_stmt_close(stmt)
    return true
end

function insert_values()
    command = """INSERT INTO Employee (Name, Salary, JoinDate, LastLogin, LunchTime, OfficeNo, empno) VALUES (?, ?, ?, ?, ?, ?, ?);"""

    stmt = mysql_stmt_init(hndl)
    mysql_stmt_prepare(stmt, command)
    values = [("John", 10000.50, "2015-8-3", "2015-9-5 12:31:30", "12:00:00", 1, 1301),
              ("Tom", 20000.25, "2015-8-4", "2015-10-12 13:12:14", "13:00:00", 12, 1422),
              ("Jim", 30000.00, "2015-6-2", "2015-9-5 10:05:10", "12:30:00", 45, 1567),
              ("Tim", 15000.50, "2015-7-25", "2015-10-10 12:12:25", "12:30:00", 56, 3200)]

    typs = [MYSQL_TYPE_VARCHAR, MYSQL_TYPE_FLOAT, MYSQL_TYPE_DATE,
            MYSQL_TYPE_DATETIME, MYSQL_TYPE_TIME, MYSQL_TYPE_TINY,
            MYSQL_TYPE_SHORT]

    affrows = 0
    for value in values
        affrows += mysql_execute_query(stmt, typs, value)
    end

    println("Affected rows after insert_values(): $affrows")
    mysql_stmt_close(stmt)
    true
end

function show_results()
    command = "SELECT * FROM Employee WHERE ID > ?;"
    stmt = mysql_stmt_init(hndl)
    mysql_stmt_prepare(stmt, command)
    dframe = mysql_execute_query(stmt, [MYSQL_TYPE_LONG], [0])
    println("\n *** Results as dataframe: \n", dframe)
    println("\n *** Expected result: \n", DataFrameResultsPrep)
    @test dfisequal(dframe, DataFrameResultsPrep)

    mysql_stmt_prepare(stmt, command)
    println("\n *** Results using Iterator: \n")
    i = 1
    for row in MySQLRowIterator(stmt, [MYSQL_TYPE_LONG], [0])
        println(row)
        @test compare_rows(row, ArrayResultsPrep[i])
        i += 1
    end

    mysql_stmt_prepare(stmt, command)
    println("\n *** Results as tuples: \n")
    tupres = mysql_execute_query(stmt, [MYSQL_TYPE_LONG], [0]; opformat=MYSQL_TUPLES)
    println(tupres)
    for i in length(tupres)
        @test compare_rows(tupres[i], ArrayResultsPrep[i])
    end

    mysql_stmt_close(stmt);
    stmt_validate_metadata(stmt)
end

function stmt_validate_metadata(stmt)
    command = "SELECT * FROM Employee;"
    stmt = mysql_stmt_init(hndl)
    mysql_stmt_prepare(stmt, command)
    meta = mysql_metadata(stmt)
    @test meta.names[1] == "ID"
    @test meta.lens[1] == 11
    @test meta.mtypes[1] == MYSQL_TYPE_LONG
    @test meta.jtypes[1] == Int32
    @test meta.is_nullables[1] == false

    @test meta.names[2] == "Name"
    @test meta.lens[2] == 255
    @test meta.mtypes[2] == MYSQL_TYPE_VAR_STRING
    @test meta.jtypes[2] == AbstractString
    @test meta.is_nullables[2] == true

    mysql_stmt_close(stmt)
end

println("\n*** Running Prepared Statement Test ***\n")
run_test()
