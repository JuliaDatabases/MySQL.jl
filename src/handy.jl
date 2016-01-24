# Handy wrappers to functions defined in api.jl.

using Compat

"""
Set multiple options specified in the dictionary opts.  The keys represent the option type,
 for example `MYSQL_OPT_RECONNECT` and the values are the value of the corresponding option.
"""
function mysql_options(hndl, opts)
    for (k, v) in opts
        mysql_options(hndl, k, v)
    end
end

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
                        client_flag; opts = Dict())
    _mysqlptr = C_NULL
    _mysqlptr = mysql_init(_mysqlptr)
    _mysqlptr == C_NULL && throw(MySQLInterfaceError("Failed to initialize MySQL database"))
    mysql_options(_mysqlptr, opts)
    mysqlptr = mysql_real_connect(_mysqlptr, host, user, passwd,
                                  db, port, unix_socket, client_flag)
    mysqlptr == C_NULL && throw(MySQLInternalError(_mysqlptr))
    return MySQLHandle(mysqlptr, host, user, db)
end

"""
Wrapper over mysql_real_connect with CLIENT_MULTI_STATEMENTS passed
as client flag options.
"""
function mysql_connect(host::AbstractString, user::AbstractString,
                       passwd::AbstractString, db::AbstractString; opts = Dict())
    return mysql_connect(host, user, passwd, db, convert(Cuint, 0),
                         convert(Ptr{Cchar}, C_NULL), CLIENT_MULTI_STATEMENTS, opts=opts)
end

"""
Wrapper over mysql_close. Must be called to close the connection opened by mysql_connect.
"""
function mysql_disconnect(hndl)
    hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL connection."))
    mysql_close(hndl.mysqlptr)
    hndl.mysqlptr = C_NULL
    hndl.host = ""
    hndl.user = ""
    hndl.db = ""
    nothing
end

function mysql_affected_rows(res::MySQLResult)
    res.resptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL result."))
    ret = mysql_affected_rows(res.resptr)
    ret == typemax(Culong) && throw(MySQLInternalError(res.con))
    return ret
end

function mysql_next_result(hndl::MySQLHandle)
    hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL connection."))
    resp = mysql_next_result(hndl.mysqlptr)
    resp > 0 && throw(MySQLInternalError(hndl))
    return resp
end

for func = (:mysql_field_count, :mysql_error, :mysql_insert_id)
    eval(quote
        function ($func)(hndl::MySQLHandle, args...)
            hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL connection."))
            return ($func)(hndl.mysqlptr, args...)
        end
    end)
end

# wrappers to take MySQLHandle as input as well as check for NULL pointer.
for func = (:mysql_query, :mysql_options)
    eval(quote
        function ($func)(hndl::MySQLHandle, args...)
            hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL connection."))
            val = ($func)(hndl.mysqlptr, args...)
            val != 0 && throw(MySQLInternalError(hndl))
            return val
        end
    end)
end

function mysql_store_result(hndl::MySQLHandle)
    hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL connection."))
    ptr = mysql_store_result(hndl.mysqlptr)
    ptr == C_NULL && throw(MySQLInternalError(hndl))
    return MySQLResult(hndl, ptr)
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
 Set `opformat` to `MYSQL_TUPLES` to get results as tuples.
"""
function mysql_execute_query(con, command; opformat=MYSQL_DATA_FRAME)
    con.mysqlptr == C_NULL && throw(MySQLInterfaceError("Method called with null connection."))
    mysql_query(con.mysqlptr, command) != 0 && throw(MySQLInternalError(con))

    data = Any[]

    if opformat == MYSQL_DATA_FRAME
        convfunc = mysql_result_to_dataframe
    elseif opformat == MYSQL_TUPLES
        convfunc = mysql_get_result_as_tuples
    else
        throw(MySQLInterfaceError("Invalid output format: $opformat"))
    end

    while true
        result = mysql_store_result(con.mysqlptr)
        if result != C_NULL # if select query
            retval = convfunc(MySQLResult(con, result))
            push!(data, retval)
            mysql_free_result(result)

        elseif mysql_field_count(con.mysqlptr) == 0
            push!(data, @compat Int(mysql_affected_rows(con.mysqlptr)))
        else
            throw(MySQLInterfaceError("Query expected to produce results but did not."))
        end
        
        status = mysql_next_result(con.mysqlptr)
        if status > 0
            throw(MySQLInternalError(con))
        elseif status == -1 # if no more results
            break
        end
    end

    if length(data) == 1
        return data[1]
    end
    return data
end

function mysql_execute_query(stmt::MySQLStatementHandle; opformat=MYSQL_DATA_FRAME)
    mysql_stmt_execute(stmt)
    naff = mysql_stmt_affected_rows(stmt)
    naff != typemax(typeof(naff)) && return naff        # Not a SELECT query
    if opformat == MYSQL_DATA_FRAME
        return mysql_result_to_dataframe(stmt)
    elseif opformat == MYSQL_TUPLES
        return mysql_get_result_as_tuples(stmt)
    else
        throw(MySQLInterfaceError("Invalid output format: $opformat"))
    end
end

function mysql_execute_query(stmt::MySQLStatementHandle, typs, values;
                             opformat=MYSQL_DATA_FRAME)
    bindarr = mysql_bind_array(typs, values)
    mysql_stmt_bind_param(stmt, bindarr)
    return mysql_execute_query(stmt; opformat=opformat)
end

function mysql_stmt_init(hndl::MySQLHandle)
    hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL connection."))
    ptr = mysql_stmt_init(hndl.mysqlptr)
    ptr == C_NULL && throw(MySQLInternalError(hndl))
    return MySQLStatementHandle(ptr)
end

for func = (:mysql_stmt_num_rows, :mysql_stmt_affected_rows,
            :mysql_stmt_result_to_dataframe, :mysql_stmt_error)
    eval(quote
        function ($func)(stmt::MySQLStatementHandle, args...)
            stmt.stmtptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL statement handle."))
            return ($func)(stmt.stmtptr, args...)
        end
    end)
end

function mysql_stmt_prepare(stmt::MySQLStatementHandle, command)
    stmt.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL statement."))
    val = mysql_stmt_prepare(stmt.stmtptr, command)
    val != 0 && throw(MySQLStatementError(stmt))
    return val
end

function mysql_stmt_close(stmt::MySQLStatementHandle)
    stmt.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with Null statement handle"))
    mysql_stmt_close(stmt.stmtptr) != 0 && throw(MySQLStatementError(stmt))
    stmt.stmtptr = C_NULL
    nothing
end

function mysql_stmt_execute(stmt::MySQLStatementHandle)
    stmt.stmtptr  == C_NULL && throw(MySQLInterfaceError("Method called with Null statement handle"))
    val = mysql_stmt_execute(stmt.stmtptr)
    val != 0 && throw(MySQLStatementError(stmt))
    return val
end

function mysql_stmt_fetch(stmt::MySQLStatementHandle)
    stmt.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL statement handle."))
    val = mysql_stmt_fetch(stmt.stmtptr)
    val == 1 && throw(MySQLStatementError(stmt))
    return val
end

function mysql_stmt_bind_result(stmt::MySQLStatementHandle, bindarr::Array{MYSQL_BIND, 1})
    stmt.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL statement handle."))
    val = mysql_stmt_bind_result(stmt.stmtptr, pointer(bindarr))
    val != 0 && throw(MySQLStatementError(stmt))
    return val
end

for func = (:mysql_stmt_store_result, :mysql_stmt_bind_param)
    eval(quote
        function ($func)(stmt, args...)
            stmt.stmtptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL statement handle."))
            val = ($func)(stmt.stmtptr, args...)
            val != 0 && throw(MySQLStatementError(stmt))
            return val
        end
    end)
end

for func = (:mysql_num_rows, :mysql_fetch_row)
    eval(quote
        function ($func)(hndl, args...)
            hndl.resptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL result set."))
            return ($func)(hndl.resptr, args...)
        end
    end)
end

"""
Get a `MYSQL_BIND` instance given the mysql type `typ` and a `value`.
"""
mysql_bind_init(typ::MYSQL_TYPE, value) =
    mysql_bind_init(mysql_get_julia_type(typ), typ, value)

mysql_bind_init(jtype::@compat(Union{Type{Date}, Type{DateTime}}), typ, value) =
    MYSQL_BIND([convert(MYSQL_TIME, convert(jtype, value))], typ)

mysql_bind_init(::Type{AbstractString}, typ, value) = MYSQL_BIND(value, typ)
mysql_bind_init(jtype, typ, value) = MYSQL_BIND([convert(jtype, value)], typ)

"""
Get the binding array for arguments to be passed to prepared statements.

`typs` is an array of `MYSQL_TYPES` and `params` is and array of corresponding values.

Returns an array of `MYSQL_BIND`.
"""
function mysql_bind_array(typs, params)
    length(typs) != length(params) && throw(MySQLInterfaceError("Length of `typs` and `params` must be same."))
    bindarr = MYSQL_BIND[]
    for (typ, val) in zip(typs, params)
        push!(bindarr, mysql_bind_init(typ, val))
    end
    return bindarr
end

function MySQLResult(con, resptr)
    res = MySQLResult(con, resptr)
    finalizer(ret, x -> mysql_free_result(res.resptr))
    return res
end

function mysql_metadata(result::MySQLResult)
    result.resptr == C_NULL && throw(MySQLInterfaceError("Method called with null result set."))
    return MySQLMetadata(mysql_metadata(result.resptr))
end

function mysql_metadata(stmt::MySQLStatementHandle)
    stmt.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with null statement pointer."))
    return MySQLMetadata(mysql_metadata(stmt.stmtptr))
end

export mysql_options, mysql_connect, mysql_disconnect, mysql_execute_query,
       mysql_insert_id, mysql_store_result, mysql_metadata, mysql_query,

       mysql_stmt_init, mysql_stmt_prepare, mysql_stmt_close
