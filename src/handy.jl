# Handy wrappers to functions defined in api.jl.

"""
A handy function that wraps mysql_init and mysql_real_connect. Also does error
checking on the pointers returned by init and real_connect.
"""
function mysql_connect(host::String,
                        user::String,
                        passwd::String,
                        db::String,
                        port::Integer = 0,
                        unix_socket::Any = C_NULL,
                        client_flag::Integer = 0)

    mysqlptr::MYSQL = C_NULL
    mysqlptr = mysql_init(mysqlptr)

    if mysqlptr == C_NULL
        error("Failed to initialize MySQL database")
    end

    mysqlptr = mysql_real_connect(mysqlptr,
                                  host,
                                  user,
                                  passwd,
                                  db,
                                  convert(Cint, port),
                                  unix_socket,
                                  convert(Uint64, client_flag))

    if mysqlptr == C_NULL
        error("Failed to connect to MySQL database")
    end

    return mysqlptr
end

"""
Wrapper over mysql_real_connect with CLIENT_MULTI_STATEMENTS passed
as client flag options.
"""
function mysql_connect(hostName::String, userName::String, password::String, db::String)
    return mysql_connect(hostName, userName, password, db, 0,
                                  C_NULL, CLIENT_MULTI_STATEMENTS)
end

"""
Wrapper over mysql_close. Must be called to close the connection opened by mysql_connect.
"""
function mysql_disconnect(db::MYSQL)
    mysql_close(db)
end

"""
Execute a query and return results as a dataframe if the query was a select query.
If query is not a select query then return the number of affected rows.
"""
function mysql_execute_query(con::MYSQL, command::String, opformat=MYSQL_DATA_FRAME)
    response = mysql_query(con, command)
    mysql_display_error(con, response != 0,
                        "Error occured while executing mysql_query on \"$command\"")

    result = mysql_store_result(con)
    if (result == C_NULL)
        affectedRows = mysql_affected_rows(con)
        return convert(Int, affectedRows)
    end

    retval = Nothing
    if opformat == MYSQL_DATA_FRAME
        retval = mysql_result_to_dataframe(result)
    else opformat == MYSQL_ARRAY
        retval = mysql_get_result_as_array(result)
    end

    mysql_free_result(result)
    return retval
end

"""
Same as execute query but for multi-statements.
"""
function mysql_execute_multi_query(con::MYSQL, command::String, opformat=MYSQL_DATA_FRAME)
    # Ideally, we should find out what the current auto-commit mode is
    # before setting/unsetting it.
    mysql_autocommit(con, convert(Int8, 0))

    response = mysql_query(con, command)
    mysql_display_error(con, response != 0,
                        "Error occured while executing mysql_query on \"$command\"")

    result = mysql_store_result(con)
    
    if (result == C_NULL)
        affectedRows = 0

        while (mysql_next_result(con) == 0)
            affectedRows = affectedRows + mysql_affected_rows(con)
        end

        mysql_autocommit(con, convert(Int8, 1))
        return affectedRows
    end

    mysql_autocommit(con, convert(Int8, 1))

    retval = Nothing
    if opformat == MYSQL_DATA_FRAME
        retval = mysql_result_to_dataframe(result)
    else opformat == MYSQL_ARRAY
        retval = mysql_get_result_as_array(result)
    end

    mysql_free_result(result)
    return retval
end

"""
A handy function to display the `mysql_error` message along with a user message `msg` through `error`
 when `condition` is true.
"""
function mysql_display_error(con, condition, msg)
    if (condition)
        err_string = msg * "\nMySQL ERROR: " * bytestring(mysql_error(con))
        error(err_string)
    end
end

"""
Given a prepared statement pointer `stmtptr` returns a dataframe containing the results.
`mysql_stmt_prepare` must be called on the statement pointer before this can be used.
"""
function mysql_stmt_result_to_dataframe(stmtptr::Ptr{MYSQL_STMT})
    stmt = unsafe_load(stmtptr)
    metadata = mysql_stmt_result_metadata(stmtptr)
    mysql_display_error(stmt.mysql, metadata == C_NULL,
                        "Error occured while retrieving metadata")

    response = mysql_stmt_execute(stmtptr)
    mysql_display_error(stmt.mysql, response != 0,
                        "Error occured while executing prepared statement")

    retval = mysql_stmt_result_to_dataframe(metadata, stmtptr)
    mysql_free_result(metadata)
    return retval
end
