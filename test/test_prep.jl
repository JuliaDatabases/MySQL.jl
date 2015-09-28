# Same as test_basic.jl but uses prepare statements instead of `mysql_query`.

include("test_common.jl")

function run_query_helper(command, msg)
    stmt = MySQL.mysql_stmt_init(con)
 
    if (stmt == C_NULL)
        error("Error in initialization of statement.")
    end

    response = MySQL.mysql_stmt_prepare(stmt, command)
    MySQL.mysql_display_error(con, response != 0,
                        "Error occured while preparing statement for query \"$command\"")

    response = MySQL.mysql_stmt_execute(stmt)
    MySQL.mysql_display_error(con, response != 0,
                        "Error occured while executing prepared statement for query \"$command\"")

    response = MySQL.mysql_stmt_close(stmt)
    MySQL.mysql_display_error(con, response != 0,
                        "Error occured while closing prepared statement for query \"$command\"")

    println("Success: " * msg)
    return true
end

function show_as_dataframe()
    command = """SELECT * FROM Employee;"""

    stmt = MySQL.mysql_stmt_init(con)

    if (stmt == C_NULL)
        error("Error in initialization of statement.")
    end

    response = MySQL.mysql_stmt_prepare(stmt, command)
    MySQL.mysql_display_error(con, response != 0,
                        "Error occured while preparing statement for query \"$command\"")

    dframe = MySQL.stmt_results_to_dataframe(stmt)
    MySQL.mysql_stmt_close(stmt)
    println(dframe)
end

println("\n*** Running Prepared Statement Test ***\n")
run_test()
