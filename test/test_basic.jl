using DataFrames
using Compat

include("test_common.jl")

@compat const ArrayResults = Array{Any}[
    Any[1, Nullable("John"), Nullable(10000.5f0), Nullable(convert(Date, "2015-08-03")),
     Nullable(convert(DateTime, "2015-09-05 12:31:30")),
     Nullable(convert(DateTime, "1970-01-01 12:00:00")),
     Nullable(Int8(1)), Nullable("HR"), Nullable(0x01), Nullable(Int16(1301))],

    Any[2, Nullable("Tom"), Nullable(20000.25f0), Nullable(convert(Date, "2015-08-04")),
     Nullable(convert(DateTime, "2015-10-12 13:12:14")),
     Nullable(convert(DateTime, "1970-01-01 13:00:00")),
     Nullable(Int8(12)), Nullable("HR"), Nullable(0x01), Nullable(Int16(1422))],

    Any[3, Nullable("Jim"), Nullable(25000.0f0), Nullable(convert(Date, "2015-06-02")),
     Nullable(convert(DateTime, "2015-09-05 10:05:10")),
     Nullable(convert(DateTime, "1970-01-01 12:30:00")),
     Nullable(Int8(45)), Nullable("Management"), Nullable{UInt8}(), Nullable(Int16(1567))],

    Any[4, Nullable("Tim"), Nullable(25000.0f0), Nullable(convert(Date, "2015-07-25")),
     Nullable(convert(DateTime, "2015-10-10 12:12:25")),
     Nullable(convert(DateTime, "1970-01-01 12:30:00")),
     Nullable(Int8(56)), Nullable("Accounts"), Nullable(0x01), Nullable(Int16(3200))],

    Any[5, Nullable{AbstractString}(), Nullable{Float32}(), Nullable{Date}(),
     Nullable{DateTime}(), Nullable{DateTime}(),
     Nullable{Int8}(), Nullable{AbstractString}(), Nullable{UInt8}(), Nullable{Int16}()]]

const DataFrameResults = DataFrame(
    ID=[1, 2, 3, 4, 5], 
    Name=@data(["John", "Tom", "Jim", "Tim", NA]),
    Salary=@data([10000.5, 20000.3, 25000.0, 25000.0, NA]),
    JoinDate=@data([convert(Date, "2015-8-3"), convert(Date, "2015-8-4"),
              convert(Date, "2015-6-2"), convert(Date, "2015-7-25"), NA]),
    LastLogin=@data([convert(DateTime, "2015-9-5 12:31:30"),
               convert(DateTime, "2015-10-12 13:12:14"),
               convert(DateTime, "2015-9-5 10:5:10"),
               convert(DateTime, "2015-10-10 12:12:25"), NA]),
    LunchTime=@data([convert(DateTime, "12:0:0"), convert(DateTime, "13:0:0"),
               convert(DateTime, "12:30:0"), convert(DateTime, "12:30:0"), NA]),
    OfficeNo=@data([1, 12, 45, 56, NA]),
    JobType=@data(["HR", "HR", "Management", "Accounts", NA]),
    Senior=@data([0x01, 0x01, NA, 0x01, NA]),
    empno=@data([1301, 1422, 1567, 3200, NA]))

function run_query_helper(command, msg)
    response = mysql_query(hndl, command)

    if (response == 0)
        println("SUCCESS: " * msg)
        return true
    else
        println("FAILED: " * msg)
        return false
    end
end

function show_results()
    command = """SELECT * FROM Employee;"""
    dframe = mysql_execute(hndl, command)
    println("\n *** Results as Dataframe: \n", dframe)
    println("\n *** Expected Result: \n", DataFrameResults)
    @test dfisequal(dframe, DataFrameResults)

    println("\n *** Results using Iterator: \n")
    i = 1
    for row in MySQLRowIterator(hndl, command)
        println(row)
        @test compare_rows(row, ArrayResults[i])
        i += 1
    end

    println("\n *** Results as tuples: \n")
    tupres = mysql_execute(hndl, command; opformat=MYSQL_TUPLES)
    println(tupres)
    for i in length(tupres)
        @test compare_rows(tupres[i], ArrayResults[i])
    end

    validate_metadata()

    # Test quoting works as expected
    @test mysql_escape(hndl, "quoting 'test'") == "quoting \\'test\\'"
end

function validate_metadata()
    mysql_query(hndl, "SELECT * FROM Employee;")
    result = mysql_store_result(hndl)
    meta = mysql_metadata(result)
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
end

println("\n*** Running Basic Test ***\n")
run_test()
