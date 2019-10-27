
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
            finalizer(API.mysql_free_result, res)
        end
        return res
    end
end

function metadata(result::API.MYSQL_RES)
    nfields = API.mysql_num_fields(result)
    rawfields = API.mysql_fetch_fields(result)
    return unsafe_wrap(Array, rawfields, nfields)
end

# resulttype is a symbol with values :none :streaming :default
# names and types relate to the returned columns in the query
mutable struct Query{resulttype, names, T}
    result::Result
    ptr::Ptr{Ptr{Int8}}
    ncols::Int
    nrows::Int
end

function julia_type(field_type, notnullable, isunsigned)
    T = API.julia_type(field_type)
    T2 = isunsigned ? unsigned(T) : T
    return notnullable ? T2 : Union{Missing, T2}
end

"""
    MySQL.Query(conn, sql; kwargs...) => MySQL.Query

Execute an SQL statement and return a `MySQL.Query` object. Result rows can be
iterated as NamedTuples via `Table.rows(query)` where `query` is the `MySQL.Query`
object.

Supported Key Word Arguments:
* `streaming` - Defaults to false. If true, length of the result size is unknown as the result is returned row by row. May be more memory efficient.

To materialize the results as a `DataFrame`, use `MySQL.Query(conn, sql) |> DataFrame`.
"""
function Query(conn::Connection, sql::String; streaming::Bool=false, kwargs...)
    conn.ptr == C_NULL && throw(MySQLInterfaceError("Method called with null connection."))
    MySQL.API.mysql_query(conn.ptr, sql) != 0 && throw(MySQLInternalError(conn))

    if streaming
        resulttype = :streaming
        result = MySQL.Result(MySQL.API.mysql_use_result(conn.ptr))
    else
        resulttype = :default
        result = MySQL.Result(MySQL.API.mysql_store_result(conn.ptr))
    end

    if result.ptr != C_NULL
        nrows = MySQL.API.mysql_num_rows(result.ptr)
        fields = MySQL.metadata(result.ptr)
        names = Tuple(ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Csize_t), x.name, x.name_length) for x in fields)
        T = Tuple{(julia_type(x.field_type, API.notnullable(x), API.isunsigned(x)) for x in fields)...}
        ncols = length(fields)
        ptr = MySQL.API.mysql_fetch_row(result.ptr)
    elseif API.mysql_field_count(conn.ptr) == 0
        result = Result(Int(API.mysql_affected_rows(conn.ptr)))
        nrows = ncols = 1
        names = (:num_rows_affected,)
        T = Tuple{Int}
        resulttype = :none
        ptr = C_NULL
    else
        throw(MySQLInterfaceError("Query expected to produce results but did not."))
    end
    return Query{resulttype, names, T}(result, ptr, ncols, nrows)
end

Base.IteratorSize(::Type{Query{resulttype, names, T}}) where {resulttype, names, T} = resulttype == :streaming ? Base.SizeUnknown() : Base.HasLength()

Tables.istable(::Type{<:Query}) = true
Tables.rowaccess(::Type{<:Query}) = true
Tables.rows(q::Query) = q
Tables.schema(q::Query{hasresult, names, T}) where {hasresult, names, T} = Tables.Schema(names, T)

Base.length(q::Query) = q.ptr == C_NULL ? 0 : q.nrows
Base.eltype(q::Query{hasresult, names, types}) where {hasresult, names, types} = NamedTuple{names}

cast(str, ::Type{Union{Missing, T}}) where {T} = cast(str, T)
cast(str, ::Type{API.Bit}) = API.Bit(isempty(str) ? 0 : UInt64(str[1]))
cast(str, ::Type{T}) where {T<:Number} = parse(T, str)
cast(str, ::Type{Vector{UInt8}}) = Vector{UInt8}(str)
cast(str, ::Type{<:AbstractString}) = str
cast(str, ::Type{Time}) = mysql_time(str)
cast(str, ::Type{Date}) = mysql_date(str)
cast(str, ::Type{DateTime}) = mysql_datetime(str)

function getvalue(ptr, col, ::Type{T}) where {T}
    deref = unsafe_load(ptr, col)
    return deref == C_NULL ? missing : cast(unsafe_string(deref), T)
end

function Base.iterate(q::Query{resulttype, names, types}, st=1) where {resulttype, names, types}
    st == 1 && resulttype == :none && return (num_rows_affected=Int(q.result.ptr),), 2
    q.ptr == C_NULL && return nothing
    nt = NamedTuple{names}([getvalue(q.ptr, i, fieldtype(types, i)) for i in 1:fieldcount(types)])
    q.ptr = API.mysql_fetch_row(q.result.ptr)
    return nt, st + 1
end
