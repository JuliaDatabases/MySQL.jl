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
    current_rownumber::Int
    current_resultsetnumber::Int
end

struct TextRow{buffered} <: Tables.AbstractRow
    cursor::TextCursor{buffered}
    row::Ptr{Ptr{UInt8}}
    lengths::Vector{Culong}
    rownumber::Int
    resultsetnumber::Int
end

getcursor(r::TextRow) = getfield(r, :cursor)
getrow(r::TextRow) = getfield(r, :row)
getlengths(r::TextRow) = getfield(r, :lengths)
getrownumber(r::TextRow) = getfield(r, :rownumber)
getresultsetnumber(r::TextRow) = getfield(r, :resultsetnumber)

Tables.columnnames(r::TextRow) = getcursor(r).names

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

@noinline wrongrow(i) = throw(ArgumentError("row $i is no longer valid; mysql results are forward-only iterators where each row is only valid when iterated"))

function Tables.getcolumn(r::TextRow, ::Type{T}, i::Int, nm::Symbol) where {T}
    (getrownumber(r) == getcursor(r).current_rownumber && getresultsetnumber(r) == getcursor(r).current_resultsetnumber) || wrongrow(getrownumber(r))
    return cast(T, unsafe_load(getrow(r), i), getlengths(r)[i])
end

Tables.getcolumn(r::TextRow, i::Int) = Tables.getcolumn(r, getcursor(r).types[i], i, getcursor(r).names[i])
Tables.getcolumn(r::TextRow, nm::Symbol) = Tables.getcolumn(r, getcursor(r).lookup[nm])

Tables.isrowtable(::Type{<:TextCursor}) = true
Tables.schema(c::TextCursor) = Tables.Schema(c.names, c.types)

Base.eltype(c::TextCursor) = TextRow
Base.IteratorSize(::Type{TextCursor{true}}) = Base.HasLength()
Base.IteratorSize(::Type{TextCursor{false}}) = Base.SizeUnknown()
Base.length(c::TextCursor) = c.nrows

function Base.iterate(cursor::TextCursor{buffered}, i=1) where {buffered}
    cursor.result.ptr == C_NULL && return nothing
    rowptr = API.fetchrow(cursor.conn.mysql, cursor.result)
    if rowptr == C_NULL
        !buffered && API.errno(cursor.conn.mysql) != 0 && throw(API.Error(cursor.conn.mysql))
        return nothing
    end
    lengths = API.fetchlengths(cursor.result, cursor.nfields)
    cursor.current_rownumber = i
    return TextRow(cursor, rowptr, lengths, i, cursor.current_resultsetnumber), i + 1
end

"""
    DBInterface.lastrowid(c::MySQL.TextCursor)

Return the last inserted row id.
"""
function DBInterface.lastrowid(c::TextCursor)
    checkconn(c.conn)
    return API.insertid(c.conn.mysql)
end

"""
    DBInterface.close!(cursor)

Close a cursor. No more results will be available.
"""
DBInterface.close!(c::TextCursor) = clear!(c.conn)

"""
    DBInterface.execute(conn::MySQL.Connection, sql) => MySQL.TextCursor

Execute the SQL `sql` statement with the database connection `conn`. Parameter binding is
only supported via prepared statements, see `?DBInterface.prepare(conn, sql)`.
Returns a `Cursor` object, which iterates resultset rows and satisfies the `Tables.jl` interface, meaning
results can be sent to any valid sink function (`DataFrame(cursor)`, `CSV.write("results.csv", cursor)`, etc.).
Specifying `mysql_store_result=false` will avoid buffering the full resultset to the client after executing
the query, which has memory use advantages, though ties up the database server since resultset rows must be
fetched one at a time.
"""
function DBInterface.execute(conn::Connection, sql::AbstractString, params=(); mysql_store_result::Bool=true)
    checkconn(conn)
    params != () && error("`DBInterface.execute(conn, sql)` does not support parameter binding; see `?DBInterface.prepare(conn, sql)`")
    clear!(conn)
    API.query(conn.mysql, sql)

    buffered = false
    nrows = -1
    rows_affected = UInt64(0)
    nfields = 0
    if mysql_store_result
        buffered = true
        result = API.storeresult(conn.mysql)
    else
        result = API.useresult(conn.mysql)
    end
    conn.lastexecute = result

    if result.ptr != C_NULL
        if buffered
            nrows = API.numrows(result)
        end
        nfields = API.numfields(result)
        fields = API.fetchfields(result, nfields)
        names = [ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Csize_t), x.name, x.name_length) for x in fields]
        types = [juliatype(x.field_type, API.notnullable(x), API.isunsigned(x), API.isbinary(x)) for x in fields]
    elseif API.fieldcount(conn.mysql) == 0
        rows_affected = API.affectedrows(conn.mysql)
        names = Symbol[]
        types = Type[]
    else
        error("error with mysql resultset columns")
    end
    lookup = Dict(x => i for (i, x) in enumerate(names))
    return TextCursor{buffered}(conn, sql, nfields, nrows, Core.bitcast(Int64, rows_affected), result, names, types, lookup, 0, 1)
end

struct TextCursors{T}
    cursor::TextCursor{T}
end

Base.eltype(c::TextCursors{T}) where {T} = TextCursor{T}
Base.IteratorSize(::Type{<:TextCursors}) = Base.SizeUnknown()

function Base.iterate(cursor::TextCursors{buffered}, first=true) where {buffered}
    cursor.cursor.result.ptr == C_NULL && return nothing
    if !first
        finalize(cursor.cursor.result)
        if API.moreresults(cursor.cursor.conn.mysql)
            @assert API.nextresult(cursor.cursor.conn.mysql) !== nothing
            cursor.cursor.result = buffered ? API.storeresult(cursor.cursor.conn.mysql) : API.useresult(cursor.cursor.conn.mysql)
            if buffered
                cursor.cursor.nrows = API.numrows(cursor.cursor.result)
            end
            cursor.cursor.nfields = API.numfields(cursor.cursor.result)
            fields = API.fetchfields(cursor.cursor.result, cursor.cursor.nfields)
            cursor.cursor.names = [ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Csize_t), x.name, x.name_length) for x in fields]
            cursor.cursor.types = [juliatype(x.field_type, API.notnullable(x), API.isunsigned(x), API.isbinary(x)) for x in fields]
        else
            return nothing
        end
    end
    return cursor.cursor, false
end

DBInterface.executemultiple(conn::Connection, sql::AbstractString, params=(); kw...) =
    TextCursors(DBInterface.execute(conn, sql, params; kw...))