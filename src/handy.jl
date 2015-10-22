# Handy wrappers to functions defined in api.jl.

using Compat

"""
A handy function that wraps mysql_init and mysql_real_connect. Also does error
checking on the pointers returned by init and real_connect.
"""
function mysql_connect(host::AbstractString,
                        user::AbstractString,
                        passwd::AbstractString,
                        db::AbstractString,
                        port::Cuint,
                        unix_socket::Ptr{Cchar},
                        client_flag)

    mysqlptr::Ptr{Void} = C_NULL
    mysqlptr = mysql_init(mysqlptr)

    if mysqlptr == C_NULL
        error("Failed to initialize MySQL database")
    end

    mysqlptr = mysql_real_connect(mysqlptr,
                                  host,
                                  user,
                                  passwd,
                                  db,
                                  port,
                                  unix_socket,
                                  client_flag)

    if mysqlptr == C_NULL
        error("Failed to connect to MySQL database")
    end

    return MySQLHandle(mysqlptr, host, user, db)
end

"""
Wrapper over mysql_real_connect with CLIENT_MULTI_STATEMENTS passed
as client flag options.
"""
function mysql_connect(hostName::AbstractString, userName::AbstractString, password::AbstractString, db::AbstractString)
    return mysql_connect(hostName, userName, password, db, convert(Cuint, 0),
                         convert(Ptr{Cchar}, C_NULL), CLIENT_MULTI_STATEMENTS)
end

"""
Wrapper over mysql_close. Must be called to close the connection opened by mysql_connect.
"""
function mysql_disconnect(hndl)
    if (hndl.mysqlptr == C_NULL)
        error("Disconnect called with NULL connection.")
    end
    mysql_close(hndl.mysqlptr)
    hndl.mysqlptr = C_NULL
    hndl.host = ""
    hndl.user = ""
    hndl.db = ""
    Void
end

# wrappers to take MySQLHandle as input as well as check for NULL pointer.
for func = (:mysql_query, :mysql_store_result, :mysql_field_count, :mysql_affected_rows,
            :mysql_next_result, :mysql_error, :mysql_execute_query)
    eval(quote
        function ($func)(hndl, args...)
            if hndl.mysqlptr == C_NULL
                error($(string(func)) * " called with NULL connection.")
            end
            ($func)(hndl.mysqlptr, args...)
        end
    end)
end

"""
A function for executing queries and getting results.

In the case of multi queries returns an array of number of affected
 rows and DataFrames. The number of affected rows correspond to the
 non-SELECT queries and the DataFrames for the SELECT queries in the
 multi-query.

In the case of non-multi queries returns either the number of affected
 rows for non-SELECT queries or a DataFrame for SELECT queries.

By default, returns SELECT query results as DataFrames.
 Set `opformat` to `MYSQL_ARRAY` to get results as arrays.
"""
function mysql_execute_query(mysqlptr::Ptr{Void}, command, opformat=MYSQL_DATA_FRAME)
    response = mysql_query(mysqlptr, command)
    mysql_display_error(mysqlptr, response)

    data = Any[]

    while true
        result = mysql_store_result(mysqlptr)
        if result != C_NULL # if select query
            retval = Void
            if opformat == MYSQL_DATA_FRAME
                retval = mysql_result_to_dataframe(result)
            else opformat == MYSQL_ARRAY
                retval = mysql_get_result_as_array(result)
            end
            push!(data, retval)
            mysql_free_result(result)

        elseif mysql_field_count(mysqlptr) == 0
            push!(data, @compat Int(mysql_affected_rows(mysqlptr)))
        else
            mysql_display_error(mysqlptr,
                                "Query expected to produce results but did not.")
        end
        
        status = mysql_next_result(mysqlptr)
        if status > 0
            mysql_display_error(mysqlptr, "Could not execute multi statements.")
        elseif status == -1 # if no more results
            break
        end
    end

    if length(data) == 1
        return data[1]
    end
    return data
end

"""
A handy function to display the `mysql_error` message along with a user message `msg` through `error`
 when `condition` is true.
"""
function mysql_display_error(hndl, condition::Bool, msg)
    if (condition)
        err_string = msg * "\nMySQL ERROR: " * bytestring(mysql_error(hndl))
        error(err_string)
    end
end

function mysql_display_error(hndl::MySQLStatementHandle, condition::Bool, msg)
    if (condition)
        err_string = msg * "\nMySQL ERROR: " * bytestring(mysql_stmt_error(hndl))
        error(err_string)
    end
end

mysql_display_error(hndl, condition::Bool) = mysql_display_error(hndl, condition, "")
mysql_display_error(hndl, response, msg) = mysql_display_error(hndl, response != 0, msg)
mysql_display_error(hndl, response) = mysql_display_error(hndl, response, "")
mysql_display_error(hndl, msg::AbstractString) = mysql_display_error(hndl, true, msg)

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
    mysql_display_error(stmt.mysql, response,
                        "Error occured while executing prepared statement")

    retval = mysql_stmt_result_to_dataframe(metadata, stmtptr)
    mysql_free_result(metadata)
    return retval
end

function mysql_stmt_init(hndl::MySQLHandle)
    if hndl.mysqlptr == C_NULL
        error("mysql_stmt_init called with NULL connection.")
    end
    MySQLStatementHandle(mysql_stmt_init(hndl.mysqlptr))
end

function mysql_stmt_close(hndl::MySQLStatementHandle)
    if hndl.stmtptr == C_NULL
        error("mysql_stmt_close called with Null statement handle")
    end

    response = mysql_stmt_close(hndl.stmtptr)
    hndl.stmtptr = C_NULL
    return response
end

# wrappers to take MySQLStatementHandle as input as well as check for NULL pointer.
for func = (:mysql_stmt_execute, :mysql_stmt_prepare, :mysql_stmt_error,
            :mysql_stmt_store_result, :mysql_stmt_result_metadata,
            :mysql_stmt_num_rows, :mysql_stmt_fetch, :mysql_stmt_bind_result,
            :mysql_stmt_bind_param, :mysql_stmt_affected_rows, :mysql_stmt_result_to_dataframe)
    eval(quote
        function ($func)(hndl, args...)
            if hndl.stmtptr == C_NULL
                error($(string(func)) * " called with NULL statement handle.")
            end
            ($func)(hndl.stmtptr, args...)
        end
    end)
end
