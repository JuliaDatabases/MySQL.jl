# Same as test_basic.jl but uses prepare statements instead of `mysql_query`.

include("test_common.jl")

function run_query_helper(command, msg)
    stmt = mysql_stmt_init(con)
 
    if (stmt == C_NULL)
        error("Error in initialization of statement.")
    end

    response = mysql_stmt_prepare(stmt, command)
    mysql_display_error(con, response != 0,
                        "Error occured while preparing statement for query \"$command\"")

    response = mysql_stmt_execute(stmt)
    mysql_display_error(con, response != 0,
                        "Error occured while executing prepared statement for query \"$command\"")

    response = mysql_stmt_close(stmt)
    mysql_display_error(con, response != 0,
                        "Error occured while closing prepared statement for query \"$command\"")

    println("Success: " * msg)
    return true
end

function show_as_dataframe()
    command = """SELECT * FROM Employee;"""

    stmt = mysql_stmt_init(con)

    if (stmt == C_NULL)
        error("Error in initialization of statement.")
    end

    response = mysql_stmt_prepare(stmt, command)
    mysql_display_error(con, response != 0,
                        "Error occured while preparing statement for query \"$command\"")

    dframe = mysql_stmt_results_to_dataframe(stmt)
    mysql_stmt_close(stmt)
    println(dframe)
end

println("\n*** Running Prepared Statement Test ***\n")
test_helper()
