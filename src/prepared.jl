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
        @compat finalizer(x->API.mysql_stmt_close(x.ptr), stmt)
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

Data.streamtypes(::Type{Stmt}) = [Data.Row]
function Data.streamto!(sink::Stmt, ::Type{Data.Row}, val, row, col)
    sink.rows_affected += execute!(sink, val)
    return
end

Stmt(sch::Data.Schema, ::Type{Data.Row}, append::Bool, conn::Connection, sql::String) = Stmt(conn, sql)
Stmt(sink::Stmt, sch::Data.Schema, ::Type{Data.Row}, append::Bool) = sink

function MySQLStatementIterator(args...)
    throw(ArgumentError("`MySQLStatementIterator` is deprecated; instead, you can create a prepared statement by doing `stmt = MySQL.Stmt(conn, sql)` and then \"stream\" parameters to it, with the statement being executed once for each row in the source, like `Data.stream!(source, stmt)`"))
end