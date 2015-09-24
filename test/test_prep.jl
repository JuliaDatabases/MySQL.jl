# Same as test_basic.jl but uses prepare statements instead of `mysql_query`.

include("test_common.jl")

function run_query_helper(command, msg)
    stmt = MySQL.mysql_stmt_init(con.ptr)
    
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

    return true
end

run_test()
