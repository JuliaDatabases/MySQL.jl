# A basic test  that uses `MySQL.mysql_query` to execute  the queries in
# test_common.jl

include("test_common.jl")

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

    retarr = mysql_execute_query(hndl, command, MYSQL_ARRAY)
    println("\n *** Results as Array: \n", retarr)

    println("\n *** Results using Iterator: \n")
    response = mysql_query(hndl, command)
    mysql_display_error(hndl, response != 0,
                        "Error occured while executing mysql_query on \"$command\"")

    result = mysql_store_result(hndl)

    for row in MySQLRowIterator(result)
        println(row)
    end

    mysql_free_result(result)
end

println("\n*** Running Basic Test ***\n")
run_test()
