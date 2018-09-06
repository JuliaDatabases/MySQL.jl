struct MySQLStatementError <: MySQLError
    ptr::Ptr{Cvoid}
    MySQLStatementError(ptr) = new(ptr)
end
Base.showerror(io::IO, e::MySQLStatementError) = print(io, unsafe_string(API.mysql_stmt_error(e.ptr)))

"""
    MySQL.Stmt(conn, sql) => MySQL.Stmt

Prepare an SQL statement that may contain `?` parameter placeholders.

A `MySQL.Stmt` may then be executed by calling `MySQL.execute!(stmt, params)` where `params` are the values to be bound to the `?` placeholders in the original SQL statement. Params must be provided for every `?` and will be matched in the same order they appeared in the original SQL statement.

Bulk statement execution can be accomplished by "streaming" a param source like:

    Data.stream!(source, stmt)

where `source` is any valid `Data.Source` (from DataStreams.jl). As with `MySQL.execute!`, the `source` must provide enough params and will be matched in the same order.
"""
mutable struct Stmt
    ptr::Ptr{Cvoid}
    sql::String
    nparams::Int
    rows_affected::Int
    function Stmt(conn::Connection, sql::String)
        ptr = API.mysql_stmt_init(conn.ptr)
        API.mysql_stmt_prepare(ptr, sql) != 0 && throw(MySQLInternalError(conn))
        nparams = API.mysql_stmt_param_count(ptr)
        stmt = new(ptr, sql, nparams, 0)
        finalizer(x->API.mysql_stmt_close(x.ptr), stmt)
        return stmt
    end
end

bind(x::Dates.TimeType) = API.MYSQL_BIND([convert(API.MYSQL_TIME, x)], API.mysql_type(x))
bind(x::AbstractString) = API.MYSQL_BIND(string(x), API.mysql_type(x))
bind(x::Vector{UInt8}) = API.MYSQL_BIND(x, API.mysql_type(x))
bind(x::Unsigned) = API.MYSQL_BIND([x], API.mysql_type(x))
bind(x::Missing) = API.MYSQL_BIND([x], API.mysql_type(x))
bind(x::T) where {T} = API.MYSQL_BIND([x], API.mysql_type(T))

function execute!(stmt::Stmt, params=[])
    stmt.ptr == C_NULL && throw(MySQLInterfaceError("prepared statement execution called with null statement pointer"))
    length(params) == stmt.nparams || throw(MySQLInterfaceError("stmt requires $(stmt.nparams) params, only $(length(params)) provided"))
    binds = [bind(x) for x in params]
    API.mysql_stmt_bind_param(stmt.ptr, pointer(binds)) == 0 || throw(MySQLStatementError(stmt.ptr))
    API.mysql_stmt_execute(stmt.ptr) == 0 || throw(MySQLStatementError(stmt.ptr))
    return API.mysql_stmt_affected_rows(stmt.ptr)
end

execute!(itr, conn::Connection, sql::String) = execute!(itr, Stmt(conn, sql))
function execute!(itr, stmt::Stmt)
    rows = Tables.rows(itr)
    state = iterate(rows)
    state === nothing && return stmt
    row, st = state
    sch = Tables.Schema(propertynames(row), nothing)
    binds = Vector{API.MYSQL_BIND}(undef, stmt.nparams)
    bindptr = pointer(binds)

    while true
        Tables.eachcolumn(sch, row) do val, col, nm
            binds[col] = bind(val)
        end
        API.mysql_stmt_bind_param(stmt.ptr, bindptr) == 0 || throw(MySQLStatementError(stmt.ptr))
        API.mysql_stmt_execute(stmt.ptr) == 0 || throw(MySQLStatementError(stmt.ptr))
        stmt.rows_affected += API.mysql_stmt_affected_rows(stmt.ptr)
        state = iterate(rows, st)
        state === nothing && break
        row, st = state
    end
    return stmt
end
