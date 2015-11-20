# A basic test  that uses `MySQL.mysql_query` to execute  the queries in
# test_common.jl

using DataFrames

include("test_common.jl")

const ArrayResults = Array{Any}[
    [1, "John", 10000.5f0, MySQLDate("2015-8-3"),
     MySQLDateTime("2015-9-5 12:31:30"), MySQLTime("12:0:0"),
     1, "HR", 0x01, 1301],

    [2, "Tom", 20000.25f0, MySQLDate("2015-8-4"),
     MySQLDateTime("2015-10-12 13:12:14"), MySQLTime("13:0:0"),
     12, "HR", 0x01, 1422],

    [3, "Jim", 25000.0f0, MySQLDate("2015-6-2"),
     MySQLDateTime("2015-9-5 10:5:10"), MySQLTime("12:30:0"),
     45, "Management", Void, 1567],

    [4, "Tim", 25000.0f0, MySQLDate("2015-7-25"),
     MySQLDateTime("2015-10-10 12:12:25"), MySQLTime("12:30:0"),
     56, "Accounts", 0x01, 3200],

    [5, Void, Void, Void, Void, Void, Void, Void, Void, Void]]

const DataFrameResults = DataFrame(
    ID=[1, 2, 3, 4, 5], 
    Name=@data(["John", "Tom", "Jim", "Tim", NA]),
    Salary=@data([10000.5, 20000.3, 25000.0, 25000.0, NA]),
    JoinDate=@data([MySQLDate("2015-8-3"), MySQLDate("2015-8-4"),
              MySQLDate("2015-6-2"), MySQLDate("2015-7-25"), NA]),
    LastLogin=@data([MySQLDateTime("2015-9-5 12:31:30"),
               MySQLDateTime("2015-10-12 13:12:14"),
               MySQLDateTime("2015-9-5 10:5:10"),
               MySQLDateTime("2015-10-10 12:12:25"), NA]),
    LunchTime=@data([MySQLTime("12:0:0"), MySQLTime("13:0:0"),
               MySQLTime("12:30:0"), MySQLTime("12:30:0"), NA]),
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
        @test row == tuple(ArrayResults[i]...)
        i += 1
    end

    mysql_free_result(result)

    println("\n *** Results as tuples: \n")
    tupres = mysql_execute_query(hndl, command, MYSQL_TUPLES)
    println(tupres)
    for i in length(tupres)
        @test tupres[i] == tuple(ArrayResults[i]...)
    end
end

println("\n*** Running Basic Test ***\n")
run_test()
