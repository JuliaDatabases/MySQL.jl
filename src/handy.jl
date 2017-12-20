# Handy wrappers to functions defined in api.jl.

function mysql_next_result(hndl::MySQL.Connection)
    hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL connection."))
    resp = mysql_next_result(hndl.mysqlptr)
    resp > 0 && throw(MySQLInternalError(hndl))
    return resp
end

"""
    MySQL.insertid(hndl::MySQL.Connection) -> Int

Returns the value generated by auto increment column by the previous
insert / update statement.
"""
insertid

"""
    mysql_execute(hndl::MySQL.Connection; opformat=MYSQL_DATA_FRAME)

Execute and get results for prepared statements.  A statement must be prepared with `mysql_stmt_prepare` before calling this function.
"""
function mysql_execute(hndl::MySQL.Connection; opformat=MYSQL_DATA_FRAME)
    mysql_stmt_execute(hndl)
    naff = mysql_stmt_affected_rows(hndl)
    naff != typemax(typeof(naff)) && return naff        # Not a SELECT query
    if opformat == MYSQL_DATA_FRAME
        return [mysql_result_to_dataframe(hndl)]
    elseif opformat == MYSQL_TUPLES
        return [mysql_get_result_as_tuples(hndl)]
    else
        throw(MySQLInterfaceError("Invalid output format: $opformat"))
    end
end

"""
    mysql_execute(hndl::MySQL.Connection, typs, values; opformat=MYSQL_DATA_FRAME)

Execute and get results for prepared statements.  A statement must be prepared with `mysql_stmt_prepare` before calling this function.

Parameters are passed to the query in the `values` array.  The corresponding MySQL types must be mentioned in the `typs` array.  See `MYSQL_TYPE_*` for a list of MySQL types.
"""
function mysql_execute(hndl::MySQL.Connection, typs, values;
                       opformat=MYSQL_DATA_FRAME)
    bindarr = mysql_bind_array(typs, values)
    mysql_stmt_bind_param(hndl, bindarr)
    return mysql_execute(hndl; opformat=opformat)
end

for func = (:mysql_stmt_num_rows, :mysql_stmt_affected_rows,
            :mysql_stmt_result_to_dataframe, :mysql_stmt_error)
    @eval begin
        function ($func)(hndl::MySQL.Connection, args...)
            hndl.stmtptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL statement handle."))
            return ($func)(hndl.stmtptr, args...)
        end
    end
end

"""
    mysql_stmt_prepare(hndl::MySQL.Connection, command::String)

Creates a prepared statement with the `command` SQL string.
"""
function mysql_stmt_prepare(hndl::MySQL.Connection, command)
    hndl.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL statement."))
    val = mysql_stmt_prepare(hndl.stmtptr, command)
    val != 0 && throw(MySQLStatementError(hndl))
    return val
end

function mysql_stmt_execute(hndl::MySQL.Connection)
    hndl.stmtptr  == C_NULL && throw(MySQLInterfaceError("Method called with Null statement handle"))
    val = mysql_stmt_execute(hndl.stmtptr)
    val != 0 && throw(MySQLStatementError(hndl))
    return val
end

function mysql_stmt_fetch(hndl::MySQL.Connection)
    hndl.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL statement handle."))
    val = mysql_stmt_fetch(hndl.stmtptr)
    val == 1 && throw(MySQLStatementError(hndl))
    return val
end

function mysql_stmt_bind_result(hndl::MySQL.Connection, bindarr::Vector{MYSQL_BIND})
    hndl.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL statement handle."))
    val = mysql_stmt_bind_result(hndl.stmtptr, pointer(bindarr))
    val != 0 && throw(MySQLStatementError(hndl))
    return val
end

for func = (:mysql_stmt_store_result, :mysql_stmt_bind_param)
    @eval begin
        function ($func)(hndl, args...)
            hndl.stmtptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL statement handle."))
            val = ($func)(hndl.stmtptr, args...)
            val != 0 && throw(MySQLStatementError(hndl))
            return val
        end
    end
end

"""
Get a `MYSQL_BIND` instance given the mysql type `typ` and a `value`.
"""
mysql_bind_init(typ::MYSQL_TYPE, value) =
    mysql_bind_init(mysql_get_julia_type(typ), typ, value)

mysql_bind_init(jtype::Type{Date}, typ, value::Date) =
    MYSQL_BIND([convert(MYSQL_TIME, value)], typ)
mysql_bind_init(jtype::Type{Date}, typ, value::String) =
    MYSQL_BIND([convert(MYSQL_TIME, mysql_date(value))], typ)
mysql_bind_init(jtype::Type{DateTime}, typ, value::DateTime) =
    MYSQL_BIND([convert(MYSQL_TIME, value)], typ)
mysql_bind_init(jtype::Type{DateTime}, typ, value::String) =
    MYSQL_BIND([convert(MYSQL_TIME, mysql_datetime(value))], typ)

mysql_bind_init(::Type{String}, typ, value) = MYSQL_BIND(value, typ)
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
        #Is the value missing or equal to `nothing`?
        if ismissing(val) || val === nothing
            push!(bindarr, mysql_bind_init(MYSQL_TYPE_NULL, "NULL"))
        else
            push!(bindarr, mysql_bind_init(typ, val)) #Otherwise
        end
    end
    return bindarr
end
