module MySQL

using Dates, Tables

abstract type MySQLError end
# For errors that happen in MySQL.jl
mutable struct MySQLInterfaceError <: MySQLError
    msg::String
end
Base.showerror(io::IO, e::MySQLInterfaceError) = print(io, e.msg)

include("api.jl")
using .API

include("types.jl")

function setoptions!(ptr, opts)
    ptr == C_NULL && throw(MySQLInterfaceError("`MySQL.setoptions!` called with NULL connection."))
    for (k, v) in opts
        val = API.mysql_options(ptr, k, v)
        val != 0 && throw(MySQLInternalError(ptr))
    end
    nothing
end

"""
    MySQL.connect(host::String, user::String, passwd::String; db::String = "", port = "3306", socket::String = MySQL.API.MYSQL_DEFAULT_SOCKET, opts = Dict())

Connect to a MySQL database.
"""
function connect(host::String, user::String, passwd::String; db::String="", port::Integer=3306, unix_socket::String=API.MYSQL_DEFAULT_SOCKET, client_flag=API.CLIENT_MULTI_STATEMENTS, opts = Dict())
    _ptr = C_NULL
    _ptr = API.mysql_init(_ptr)
    _ptr == C_NULL && throw(MySQLInterfaceError("Failed to initialize MySQL database"))
    setoptions!(_ptr, opts)
    ptr = API.mysql_real_connect(_ptr, host, user, passwd,
                                  db, UInt32(port), unix_socket, client_flag)
    ptr == C_NULL && throw(MySQLInternalError(_ptr))
    return Connection(ptr, host, string(port), user, db)
end

"""
    MySQL.disconnect(conn::MySQL.Connection)

Close a handle to a MySQL database opened by `MySQL.connect`.
"""
function disconnect(conn::Connection)
    conn.ptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL connection."))
    API.mysql_close(conn.ptr)
    conn.ptr = C_NULL
    conn.host = ""
    conn.user = ""
    conn.db = ""
    return nothing
end

function insertid(conn::Connection)
    conn.ptr == C_NULL && throw(MySQLInterfaceError("MySQL.insertid called with NULL connection."))
    return API.mysql_insert_id(conn.ptr)
end

"""
    MySQL.escape(conn::MySQL.Connection, str::String) -> String

Escapes a string using `mysql_real_escape_string()`, returns the escaped string.
"""
function escape(conn::MySQL.Connection, str::String)
    output = Vector{UInt8}(undef, sizeof(str) * 2 + 1)
    output_len = API.mysql_real_escape_string(conn.ptr, output, str, Culong(sizeof(str)))
    if output_len == typemax(Cuint)
        throw(MySQLInternalError(conn))
    end
    return String(output[1:output_len])
end

"""
    MySQL.execute!(conn, sql) => Nothing

execute an sql statement without returning results (useful for DDL statements, update, delete, etc.)
"""
function execute!(conn::Connection, sql::String)
    conn.ptr == C_NULL && throw(MySQLInterfaceError("`MySQL.execute!` called with NULL connection."))
    status = API.mysql_query(conn.ptr, sql)
    status == 0 || throw(MySQLInternalError(conn))
    res = 0
    while status == 0
        res += Int(API.mysql_affected_rows(conn.ptr))
        status = API.mysql_next_result(conn.ptr)
    end
    return res
end

"""
    MySQL.query(conn, sql, sink=Data.Table, args...; append::Bool=false) => sink

execute an sql statement and return the results in `sink`, which can be any valid `Data.Sink` (interface from DataStreams.jl), and `args...` are any necessary arguments to the sink. By default, a NamedTuple of Vectors are returned.

Passing `append=true` as a keyword argument will cause the resultset to be _appended_ to the sink instead of replacing.

To get the results as a `DataFrame`, you can just do `MySQL.query(conn, sql, DataFrame)`.

See list of DataStreams implementations [here](https://github.com/JuliaData/DataStreams.jl#list-of-known-implementations)
"""
function query end

function query(conn::Connection, sql::String, sink::Union{Type, Nothing}=nothing, args...; append::Bool=false, kwargs...)
    if sink === nothing
        Base.depwarn("`MySQL.query(conn, sql)` will return a MySQL.Query in the future; to materialize the result, use `MySQL.query(conn, sql) |> columntable` or `MySQL.query(conn, sql) |> DataFrame` instead", nothing)
        sink = columntable
    else
        Base.depwarn("`MySQL.query(conn, sql, $sink)` is deprecated; use `MySQL.query(conn, sql) |> $sink(args...)` instead", nothing)
    end
    if append
        Base.depwarn("`append=true` is deprecated; use sink-specific append features instead. For example, `columntable(existing, MySQL.query(conn, sql))` or `append!(existing_df, MySQL.query(conn, sql))`")
    end
    return Query(conn, sql; kwargs...) |> sink
end

function query(conn::Connection, sql::String, sink::T; append::Bool=false, kwargs...) where {T}
    Base.depwarn("`MySQL.query(conn, sql, ::$T)` is deprecated; `MySQL.Query` now supports the Tables.jl interface, so any valid Tables.jl sink can receive a resultset", nothing)
    if append
        Base.depwarn("`append=true` is deprecated; use sink-specific append features instead. For example, `columntable(existing, MySQL.query(conn, sql))` or `append!(existing_df, MySQL.query(conn, sql))`")
    end
    return Query(conn, sql; kwargs...) |> T
end

function query(source::Query, sink=columntable, args...; append::Bool=false)
    Base.depwarn("`MySQL.query(q::MySQL.Query)` is deprecated and will be removed in the future; `MySQL.Query` itself will iterate rows as NamedTuples and supports the Tables.jl interface", nothing)
    if append
        Base.depwarn("`append=true` is deprecated; use sink-specific append features instead. For example, `columntable(existing, MySQL.query(conn, sql))` or `append!(existing_df, MySQL.query(conn, sql))`")
    end
    return source |> sink
end
function query(source::Query, sink::T; append::Bool=false) where {T}
    Base.depwarn("`MySQL.query(q::MySQL.Query)` is deprecated and will be removed in the future; `MySQL.Query` itself will iterate rows as NamedTuples and supports the Tables.jl interface", nothing)
    if append
        Base.depwarn("`append=true` is deprecated; use sink-specific append features instead. For example, `columntable(existing, MySQL.query(conn, sql))` or `append!(existing_df, MySQL.query(conn, sql))`")
    end
    return source |> T
end

include("prepared.jl")

end # module
