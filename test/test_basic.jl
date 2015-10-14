# A basic test  that uses `MySQL.mysql_query` to execute  the queries in
# test_common.jl

include("test_common.jl")

function run_query_helper(command, msg)
    response = mysql_query(con, command)

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
    dframe = mysql_execute_query(con, command)
    println("\n *** Results as Dataframe: \n", dframe)

    retarr = mysql_execute_query(con, command, MYSQL_ARRAY)
    println("\n *** Results as Array: \n", retarr)

    println("\n *** Results using Iterator: \n")
    response = mysql_query(con, command)
    mysql_display_error(con, response != 0,
                        "Error occured while executing mysql_query on \"$command\"")

    result = mysql_store_result(con)

    for row in MySQLRowIterator(result)
        println(row)
    end

    mysql_free_result(result)
end

println("\n*** Running Basic Test ***\n")
run_test()
