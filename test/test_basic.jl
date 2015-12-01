# A basic test  that uses `MySQL.mysql_query` to execute  the queries in
# test_common.jl

using DataFrames

if VERSION < v"0.4-"
    using Dates
else
    using Base.Dates
end

include("test_common.jl")

const ArrayResults = Array{Any}[
    [1, Nullable("John"), Nullable(10000.5f0), Nullable(convert(Date, "2015-08-03")),
     Nullable(convert(DateTime, "2015-09-05 12:31:30")),
     Nullable(convert(DateTime, "1970-01-01 12:00:00")),
     Nullable(Int8(1)), Nullable("HR"), Nullable(0x01), Nullable(Int16(1301))],

    [2, Nullable("Tom"), Nullable(20000.25f0), Nullable(convert(Date, "2015-08-04")),
     Nullable(convert(DateTime, "2015-10-12 13:12:14")),
     Nullable(convert(DateTime, "1970-01-01 13:00:00")),
     Nullable(Int8(12)), Nullable("HR"), Nullable(0x01), Nullable(Int16(1422))],

    [3, Nullable("Jim"), Nullable(25000.0f0), Nullable(convert(Date, "2015-06-02")),
     Nullable(convert(DateTime, "2015-09-05 10:05:10")),
     Nullable(convert(DateTime, "1970-01-01 12:30:00")),
     Nullable(Int8(45)), Nullable("Management"), Nullable{UInt8}(), Nullable(Int16(1567))],

    [4, Nullable("Tim"), Nullable(25000.0f0), Nullable(convert(Date, "2015-07-25")),
     Nullable(convert(DateTime, "2015-10-10 12:12:25")),
     Nullable(convert(DateTime, "1970-01-01 12:30:00")),
     Nullable(Int8(56)), Nullable("Accounts"), Nullable(0x01), Nullable(Int16(3200))],

    [5, Nullable{AbstractString}(), Nullable{Float32}(), Nullable{Date}(),
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

function compare_values(u::Nullable, v::Nullable)
    if !isnull(u) && !isnull(v)
        return u.value == v.value
    elseif isnull(u) && isnull(v)
        return typeof(u) == typeof(v)
    else
        println("*** ALERT: Non null value being compared with null.")
        return false
    end
end

compare_values(u, v) = u == v

function compare_rows(rowu, rowv)
    length(rowu) == length(rowv) || return false
    for i = 1:length(rowu)
        compare_values(rowu[i], rowv[i]) || return false
    end
    return true
end

function show_results()
    command = """SELECT * FROM Employee;"""
    dframe = mysql_execute_query(hndl, command)
    println("\n *** Results as Dataframe: \n", dframe)
    println("\n *** Expected Result: \n", DataFrameResults)
    @test dfisequal(dframe, DataFrameResults)

    retarr = mysql_execute_query(hndl, command, MYSQL_ARRAY)
    println("\n *** Results as Array: \n", retarr)
    println("\n *** Expected Result: \n", ArrayResults)

    println("\n *** Results using Iterator: \n")
    response = mysql_query(hndl, command)
    mysql_display_error(hndl, response != 0,
                        "Error occured while executing mysql_query on \"$command\"")

    result = mysql_store_result(hndl)

    i = 1
    for row in MySQLRowIterator(result)
        println(row)
        @test compare_rows(row, ArrayResults[i])
        i += 1
    end

    mysql_free_result(result)

    println("\n *** Results as tuples: \n")
    tupres = mysql_execute_query(hndl, command, MYSQL_TUPLES)
    println(tupres)
    for i in length(tupres)
        @test compare_rows(tupres[i], ArrayResults[i])
    end
end

println("\n*** Running Basic Test ***\n")
run_test()
