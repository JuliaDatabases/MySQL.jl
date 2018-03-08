
mutable struct Connection
    ptr::Ptr{Cvoid}
    host::String
    port::String
    user::String
    db::String
end
const MySQLHandle = Connection
export MySQLHandle

function Base.show(io::IO, hndl::Connection)
    if hndl.ptr == C_NULL
        print(io, "Null MySQL Connection")
    else
        print(io, """MySQL Connection
------------
Host: $(hndl.host)
Port: $(hndl.port)
User: $(hndl.user)
DB:   $(hndl.db)
""")
    end
end

struct MySQLInternalError <: MySQLError
    errno::Cuint
    msg::String
    MySQLInternalError(con::Connection) = new(API.mysql_errno(con.ptr), unsafe_string(API.mysql_error(con.ptr)))
    MySQLInternalError(ptr) = new(API.mysql_errno(ptr), unsafe_string(API.mysql_error(ptr)))
end
Base.showerror(io::IO, e::MySQLInternalError) = print(io, "($(e.errno)): $(e.msg)")

mutable struct Result
    ptr
    function Result(ptr)
        res = new(ptr)
        if ptr != C_NULL
            @compat finalizer(API.mysql_free_result, res)
        end
        return res
    end
end

function metadata(result::API.MYSQL_RES)
    nfields = API.mysql_num_fields(result)
    rawfields = API.mysql_fetch_fields(result)
    return unsafe_wrap(Array, rawfields, nfields)
end

mutable struct Query{hasresult, names, T}
    result::Result
    ptr::Ptr{Ptr{Int8}}
    ncols::Int
    nrows::Int
end

function julia_type(field_type, nullable, isunsigned)
    T = API.julia_type(field_type)
    T2 = isunsigned ? unsigned(T) : T
    return nullable ? Union{Missing, T2} : T2
end

function MySQLRowIterator(args...)
    throw(ArgumentError("`MySQLRowIterator` is deprecated, use `Data.rows(MySQL.Query(conn, sql))` to get a NamedTuple row iterator for a query resultset"))
end

"""
    MySQL.Query(conn, sql, sink=Data.Table; append::Bool=false) => MySQL.Query

execute an sql statement and return a `MySQL.Query` object. Result rows can be iterated as NamedTuples via `Data.rows(query)` where `query` is the `MySQL.Query` object. Results can also be streamed to any valid `Data.Sink` via `Data.stream!(query, sink)`.
"""
function Query(conn::Connection, sql::String; kwargs...)
    conn.ptr == C_NULL && throw(MySQLInterfaceError("Method called with null connection."))
    MySQL.API.mysql_query(conn.ptr, sql) != 0 && throw(MySQLInternalError(conn))
    result = MySQL.Result(MySQL.API.mysql_store_result(conn.ptr))
    if result.ptr != C_NULL
        nrows = MySQL.API.mysql_num_rows(result.ptr)
        fields = MySQL.metadata(result.ptr)
        names = Tuple(ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Csize_t), x.name, x.name_length) for x in fields)
        T = Tuple{(julia_type(x.field_type, API.nullable(x), API.isunsigned(x)) for x in fields)...}
        hasresult = true
        ncols = length(fields)
        ptr = MySQL.API.mysql_fetch_row(result.ptr)
    elseif API.mysql_field_count(conn.ptr) == 0
        result = Result(Int(API.mysql_affected_rows(conn.ptr)))
        nrows = ncols = 1
        names = (:num_rows_affected,)
        T = Tuple{Int}
        hasresult = false
        ptr = C_NULL
    else
        throw(MySQLInterfaceError("Query expected to produce results but did not."))
    end
    return Query{hasresult, names, T}(result, ptr, ncols, nrows)
end

function Data.schema(rt::Query{hasresult, names, T}) where {hasresult, names, T}
    return Data.Schema(Type[A for A in T.parameters],
                        collect(map(string, names)), rt.nrows)
end
Data.isdone(source::Query, row, col) = row > source.nrows
Data.streamtype(::Type{Query}, ::Type{Data.Field}) = true

cast(str, ::Type{Union{Missing, T}}) where {T} = cast(str, T)
cast(str, ::Type{API.Bit}) = API.Bit(isempty(str) ? 0 : UInt64(str[1]))
cast(str, ::Type{T}) where {T<:Number} = parse(T, str)
cast(str, ::Type{Vector{UInt8}}) = Vector{UInt8}(str)
cast(str, ::Type{<:AbstractString}) = str
cast(str, ::Type{Time}) = mysql_time(str)
cast(str, ::Type{Date}) = mysql_date(str)
cast(str, ::Type{DateTime}) = mysql_datetime(str)

@inline function Data.streamfrom(source::Query{hasresult}, ::Type{Data.Field}, ::Type{T}, row, col) where {hasresult, T}
    if !hasresult
        return T(source.result.ptr)
    else
        deref = unsafe_load(source.ptr, col)
        if deref == C_NULL
            val = missing
        else
            val = cast(unsafe_string(deref), T)
        end
        if col >= source.ncols
            source.ptr = API.mysql_fetch_row(source.result.ptr)
        end
    end
    return val
end
Data.accesspattern(::Query) = Data.RandomAccess()
