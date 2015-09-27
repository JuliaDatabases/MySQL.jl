# Same as test_basic.jl but uses prepare statements instead of `mysql_query`.

include("test_common.jl")

function run_query_helper(command, msg)
    stmt = MySQL.mysql_stmt_init(con)
 
    if (stmt == C_NULL)
        error("Error in initialization of statement.")
    end

    response = MySQL.mysql_stmt_prepare(stmt, command)
    if (response != 0)
        err_string = "Error occured while preparing statement for query \"$command\""
        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
        error(err_string)
    end

    response = MySQL.mysql_stmt_execute(stmt)
    if (response != 0)
        err_string = "Error occured while executing prepared statement for query \"$command\""
        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
        error(err_string)
    end

    response = MySQL.mysql_stmt_close(stmt)
    if (response != 0)
        err_string = "Error occured while closing prepared statement for query \"$command\""
        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
        error(err_string)
    end

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
    if (response != 0)
        err_string = "Error occured while preparing statement for query \"$command\""
        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
        error(err_string)
    end

    metadata = MySQL.mysql_stmt_result_metadata(stmt)
    if (metadata == C_NULL)
        err_string = "Error occured while retrieving metadata for query \"$command\""
        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
        error(err_string)
    end

    response = MySQL.mysql_stmt_execute(stmt)
    if (response != 0)
        err_string = "Error occured while executing prepared statement for query \"$command\""
        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
        error(err_string)
    end

    dframe = MySQL.stmt_results_to_dataframe(metadata, stmt)
    MySQL.mysql_stmt_close(stmt)
    println(dframe)
end

println("\n*** Running Prepared Statement Test ***\n")
run_test()
