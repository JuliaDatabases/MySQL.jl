mutable struct TextCursor{buffered} <: DBInterface.Cursor
    conn::Connection
    sql::String
    nfields::Int
    nrows::Int
    rows_affected::Int64
    result::API.MYSQL_RES
    names::Vector{Symbol}
    types::Vector{Type}
    lookup::Dict{Symbol, Int}
end

struct TextRow{buffered} <: AbstractVector{Any}
    cursor::TextCursor{buffered}
    row::Ptr{Ptr{UInt8}}
    lengths::Vector{Culong}
end

getcursor(r::TextRow) = getfield(r, :cursor)
getrow(r::TextRow) = getfield(r, :row)
getlengths(r::TextRow) = getfield(r, :lengths)

Base.size(r::TextRow) = (getcursor(r).nfields,)
Base.IndexStyle(::Type{<:TextRow}) = Base.IndexLinear()
Base.propertynames(r::TextRow) = getcursor(r).names

cast(::Type{Union{Missing, T}}, ptr, len) where {T} = ptr == C_NULL ? missing : cast(T, ptr, len)

cast(::Type{API.Bit}, ptr, len) = API.Bit(len == 0 ? 0 : UInt64(unsafe_load(ptr)))

function cast(::Type{Vector{UInt8}}, ptr, len)
    A = Vector{UInt8}(undef, len)
    Base.unsafe_copyto!(pointer(A), ptr, len)
    return A
end

function cast(::Type{String}, ptr, len)
    str = Base._string_n(len)
    Base.unsafe_copyto!(pointer(str), ptr, len)
    return str
end

function cast(::Type{Dec64}, ptr, len)
    str = cast(String, ptr, len)
    return parse(Dec64, str)
end

@noinline casterror(T, ptr, len) = error("error parsing $T from \"$(unsafe_string(ptr, len))\"")

function cast(::Type{T}, ptr, len) where {T}
    buf = unsafe_wrap(Array, ptr, len)
    x, code, pos = Parsers.typeparser(T, buf, 1, len, buf[1], Int16(0), Parsers.OPTIONS)
    if code > 0
        return x
    end
    casterror(T, ptr, len)
end

const DATETIME_OPTIONS = Parsers.Options(dateformat=dateformat"yyyy-mm-dd HH:MM:SS.s")

function cast(::Type{DateTime}, ptr, len)
    buf = unsafe_wrap(Array, ptr, len)
    x, code, pos = Parsers.typeparser(DateTime, buf, 1, len, buf[1], Int16(0), DATETIME_OPTIONS)
    if code > 0
        return x
    end
    casterror(DateTime, ptr, len)
end

function Base.getindex(r::TextRow, i::Int)
    return cast(getcursor(r).types[i], unsafe_load(getrow(r), i), getlengths(r)[i])
end

Base.getindex(r::TextRow, nm::Symbol) = getindex(r, getcursor(r).lookup[nm])
Base.getproperty(r::TextRow, nm::Symbol) = getindex(r, getcursor(r).lookup[nm])

Tables.istable(::Type{<:TextCursor}) = true
Tables.rowaccess(::Type{<:TextCursor}) = true
Tables.rows(q::TextCursor) = q
Tables.schema(c::TextCursor) = Tables.Schema(c.names, c.types)

Base.eltype(c::TextCursor) = TextRow
Base.IteratorSize(::Type{TextCursor{true}}) = Base.HasLength()
Base.IteratorSize(::Type{TextCursor{false}}) = Base.SizeUnknown()
Base.length(c::TextCursor) = c.nrows

function Base.iterate(cursor::TextCursor, i=1)
    rowptr = API.fetchrow(cursor.conn.mysql, cursor.result)
    rowptr == C_NULL && return nothing
    lengths = API.fetchlengths(cursor.result, cursor.nfields)
    return TextRow(cursor, rowptr, lengths), i + 1
end

function DBInterface.lastrowid(c::TextCursor)
    checkconn(c.conn)
    return API.insertid(c.conn.mysql)
end

function DBInterface.execute!(conn::Connection, sql::AbstractString, args...; mysql_store_result::Bool=true, kw...)
    checkconn(conn)
    API.query(conn.mysql, sql)

    buffered = false
    nrows = -1
    rows_affected = nfields = 0
    if mysql_store_result
        buffered = true
        result = API.storeresult(conn.mysql)
    else
        result = API.useresult(conn.mysql)
    end

    if result.ptr != C_NULL
        if buffered
            nrows = API.numrows(result)
        end
        nfields = API.numfields(result)
        fields = API.fetchfields(result, nfields)
        names = [ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Csize_t), x.name, x.name_length) for x in fields]
        types = [juliatype(x.field_type, API.notnullable(x), API.isunsigned(x)) for x in fields]
    elseif API.fieldcount(conn.mysql) == 0
        rows_affected = API.affectedrows(conn.mysql)
        names = Symbol[]
        types = Type[]
    else
        error("error with mysql resultset columns")
    end
    lookup = Dict(x => i for (i, x) in enumerate(names))
    return TextCursor{buffered}(conn, sql, nfields, nrows, Core.bitcast(Int64, rows_affected), result, names, types, lookup)
end