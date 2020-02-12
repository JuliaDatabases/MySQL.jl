mutable struct Statement <: DBInterface.Statement
    conn::Connection
    stmt::API.MYSQL_STMT
    sql::String
    nparams::Int
    nfields::Int
    bindhelpers::Vector{API.BindHelper}
    binds::Vector{API.MYSQL_BIND}
    names::Vector{Symbol}
    types::Vector{Type}
    lookup::Dict{Symbol, Int}
    valuehelpers::Vector{API.BindHelper}
    values::Vector{API.MYSQL_BIND}

    function Statement(conn::Connection, stmt::API.MYSQL_STMT, sql::AbstractString, nparams::Integer, nfields::Integer, bindhelpers, binds, names, types, valuehelpers, values)
        lookup = Dict(x => i for (i, x) in enumerate(names))
        s = new(conn, stmt, sql, nparams, nfields, bindhelpers, binds, names, types, lookup, valuehelpers, values)
        return s
    end
end

@noinline checkstmt(stmt::Statement) = checkstmt(stmt.stmt)
@noinline checkstmt(stmt::API.MYSQL_STMT) = stmt.ptr == C_NULL && error("prepared mysql statement has been closed")

"""
    DBInterface.close!(stmt)

Close a prepared statement and free any underlying resources. The statement should not be used in any way afterwards.
"""
DBInterface.close!(stmt::Statement) = finalize(stmt.stmt)

"""
    DBInterface.prepare(conn::MySQL.Connection, sql) => MySQL.Statement

Send a `sql` SQL string to the database to be prepared, returning a `MySQL.Statement` object
that can be passed to `DBInterface.execute(stmt, args...)` to be repeatedly executed,
optionally passing `args` for parameters to be bound on each execution.

Note that `DBInterface.close!(stmt)` should be called once statement executions are finished. Apart from
freeing resources, it has been noted that too many unclosed statements and resultsets, used in conjunction
with streaming queries (i.e. `mysql_store_result=false`) has led to occasional resultset corruption.
"""
function DBInterface.prepare(conn::Connection, sql::AbstractString)
    stmt = API.stmtinit(conn.mysql)
    API.prepare(stmt, sql)
    nparams = API.paramcount(stmt)
    bindhelpers = [API.BindHelper() for i = 1:nparams]
    binds = [API.MYSQL_BIND(bindhelpers[i].length, bindhelpers[i].is_null) for i = 1:nparams]
    nfields = API.fieldcount(stmt)
    result = API.resultmetadata(stmt)
    if result.ptr != C_NULL
        fields = API.fetchfields(result, nfields)
        names = [ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Csize_t), x.name, x.name_length) for x in fields]
        types = [juliatype(x.field_type, API.notnullable(x), API.isunsigned(x)) for x in fields]
        valuehelpers = [API.BindHelper() for i = 1:nfields]
        values = [API.MYSQL_BIND(valuehelpers[i].length, valuehelpers[i].is_null) for i = 1:nfields]
        foreach(1:nfields) do i
            returnbind!(valuehelpers[i], values, i, fields[i].field_type, types[i])
        end
        API.bindresult(stmt, values)
    else
        fields = API.MYSQL_FIELD[]
        names = Symbol[]
        types = Type[]
        valuehelpers = API.BindHelper[]
        values = API.MYSQL_BIND[]
    end
    return Statement(conn, stmt, sql, nparams, nfields, bindhelpers, binds, names, types, valuehelpers, values)
end

struct Cursor{buffered} <: DBInterface.Cursor
    stmt::API.MYSQL_STMT
    nfields::Int
    names::Vector{Symbol}
    types::Vector{Type}
    lookup::Dict{Symbol, Int}
    valuehelpers::Vector{API.BindHelper}
    values::Vector{API.MYSQL_BIND}
    rows_affected::Int64
    rows::Int
end

struct Row <: Tables.AbstractRow
    cursor::Cursor
end

getcursor(r::Row) = getfield(r, :cursor)

Tables.columnnames(r::Row) = getcursor(r).names

function Tables.getcolumn(r::Row, ::Type{T}, i::Int, nm::Symbol) where {T}
    cursor = getcursor(r)
    return getvalue(cursor.stmt, cursor.valuehelpers[i], cursor.values, i, T)
end

Tables.getcolumn(r::Row, i::Int) = Tables.getcolumn(r, getcursor(r).types[i], i, getcursor(r).names[i])
Tables.getcolumn(r::Row, nm::Symbol) = Tables.getcolumn(r, getcursor(r).lookup[nm])

Tables.isrowtable(::Type{<:Cursor}) = true
Tables.schema(c::Cursor) = Tables.Schema(c.names, c.types)

Base.eltype(c::Cursor) = Row
Base.IteratorSize(::Type{Cursor{true}}) = Base.HasLength()
Base.IteratorSize(::Type{Cursor{false}}) = Base.SizeUnknown()
Base.length(c::Cursor) = c.rows

function Base.iterate(cursor::Cursor, i=1)
    cursor.stmt.ptr == C_NULL && return nothing
    status = API.fetch(cursor.stmt)
    status == API.MYSQL_NO_DATA && return nothing
    status == 1 && throw(API.StmtError(cursor.stmt))
    return Row(cursor), i + 1
end

"""
    DBInterface.lastrowid(c::MySQL.Cursor)

Return the last inserted row id.
"""
function DBInterface.lastrowid(c::Cursor)
    checkstmt(c.stmt)
    return API.insertid(c.stmt)
end

"""
    DBInterface.close!(cursor)

Close a cursor. No more results will be available.
"""
DBInterface.close!(c::Cursor) = clear!(c.conn)

@noinline paramcheck(stmt, args) = length(args) == stmt.nparams || throw(MySQLInterfaceError("stmt requires $(stmt.nparams) params, only $(length(args)) provided"))

"""
    DBInterface.execute(stmt, params; mysql_store_result=true) => MySQL.Cursor

Execute a prepared statement, optionally passing `params` to be bound as parameters (like `?` in the sql).
Returns a `Cursor` object, which iterates resultset rows and satisfies the `Tables.jl` interface, meaning
results can be sent to any valid sink function (`DataFrame(cursor)`, `CSV.write("results.csv", cursor)`, etc.).
Specifying `mysql_store_result=false` will avoid buffering the full resultset to the client after executing
the query, which has memory use advantages, though ties up the database server since resultset rows must be
fetched one at a time.
"""
function DBInterface.execute(stmt::Statement, params=(); mysql_store_result::Bool=true)
    checkstmt(stmt)
    paramcheck(stmt, params)
    clear!(stmt.conn)
    if length(params) > 0
        foreach(1:stmt.nparams) do i
            bind!(stmt.bindhelpers[i], stmt.binds, i, params[i])
        end
        API.bindparam(stmt.stmt, stmt.binds)
    end
    API.execute(stmt.stmt)
    stmt.conn.lastexecute = stmt.stmt
    rows_affected = Core.bitcast(Int64, API.affectedrows(stmt.stmt))
    buffered = false
    rows = -1
    if mysql_store_result
        API.storeresult(stmt.stmt)
        buffered = true
        rows = API.numrows(stmt.stmt)
    end
    return Cursor{buffered}(stmt.stmt, stmt.nfields, stmt.names, stmt.types, stmt.lookup, stmt.valuehelpers, stmt.values, rows_affected, rows)
end

inithelper!(helper, x::Missing) = nothing
ptrhelper(helper, x::Missing) = C_NULL

function getvalue(stmt, helper, values, i, ::Type{Union{T, Missing}}) where {T}
    helper.is_null[1] == 1 && return missing
    return getvalue(stmt, helper, values, i, T)
end

inithelper!(helper, x::API.Bit) = nothing
ptrhelper(helper, x::API.Bit) = C_NULL
sethelper!(helper, x::API.Bit) = nothing

function getvalue(stmt, helper, values, i, ::Type{API.Bit})
    len = helper.length[1]
    val = UInt64[0]
    ptr = pointer(values, i)
    API.setbuffer!(ptr, pointer(val))
    API.setbufferlength!(ptr, len)
    API.mysql_stmt_fetch_column(stmt.ptr, convert(Ptr{Cvoid}, ptr), i - 1, 0)
    x = val[1]
    return API.Bit(x >> (8 * (len - 1)))
end

inithelper!(helper, x::Union{Bool, UInt8, Int8}) = helper.uint8 = UInt8[x]
ptrhelper(helper, x::Union{Bool, UInt8, Int8}) = pointer(helper.uint8)
sethelper!(helper, x::Union{Bool, UInt8, Int8}) = helper.uint8[1] = x
getvalue(stmt, helper, values, i, ::Type{T}) where {T <: Union{Bool, UInt8, Int8}} = Core.bitcast(T, helper.uint8[1])

inithelper!(helper, x::Union{UInt16, Int16}) = helper.uint16 = UInt16[x]
ptrhelper(helper, x::Union{UInt16, Int16}) = pointer(helper.uint16)
sethelper!(helper, x::Union{UInt16, Int16}) = helper.uint16[1] = x
getvalue(stmt, helper, values, i, ::Type{T}) where {T <: Union{UInt16, Int16}} = Core.bitcast(T, helper.uint16[1])

inithelper!(helper, x::Union{UInt32, Int32}) = helper.uint32 = UInt32[x]
ptrhelper(helper, x::Union{UInt32, Int32}) = pointer(helper.uint32)
sethelper!(helper, x::Union{UInt32, Int32}) = helper.uint32[1] = x
getvalue(stmt, helper, values, i, ::Type{T}) where {T <: Union{UInt32, Int32}} = Core.bitcast(T, helper.uint32[1])

inithelper!(helper, x::Union{UInt64, Int64}) = helper.uint64 = UInt64[x]
ptrhelper(helper, x::Union{UInt64, Int64}) = pointer(helper.uint64)
sethelper!(helper, x::Union{UInt64, Int64}) = helper.uint64[1] = x
getvalue(stmt, helper, values, i, ::Type{T}) where {T <: Union{UInt64, Int64}} = Core.bitcast(T, helper.uint64[1])

inithelper!(helper, x::Float32) = helper.float = Float32[x]
ptrhelper(helper, x::Float32) = pointer(helper.float)
sethelper!(helper, x::Float32) = helper.float[1] = x
getvalue(stmt, helper, values, i, ::Type{Float32}) = helper.float[1]

inithelper!(helper, x::Float64) = helper.double = Float64[x]
ptrhelper(helper, x::Float64) = pointer(helper.double)
sethelper!(helper, x::Float64) = helper.double[1] = x
getvalue(stmt, helper, values, i, ::Type{Float64}) = helper.double[1]

inithelper!(helper, x::API.MYSQL_TIME) = helper.time = API.MYSQL_TIME[x]
ptrhelper(helper, x::API.MYSQL_TIME) = pointer(helper.time)
getvalue(stmt, helper, values, i, ::Type{Time}) = convert(Time, helper.time[1])
getvalue(stmt, helper, values, i, ::Type{Date}) = convert(Date, helper.time[1])
getvalue(stmt, helper, values, i, ::Type{DateTime}) = convert(DateTime, helper.time[1])

inithelper!(helper, x::String) = nothing
ptrhelper(helper, x::String) = C_NULL
sethelper!(helper, x::String) = helper.string = x

function getvalue(stmt, helper, values, i, ::Type{String})
    len = helper.length[1]
    str = Base._string_n(len)
    ptr = pointer(values, i)
    API.setbuffer!(ptr, pointer(str))
    API.setbufferlength!(ptr, len)
    API.mysql_stmt_fetch_column(stmt.ptr, convert(Ptr{Cvoid}, ptr), i - 1, 0)
    return str
end

inithelper!(helper, x::Vector{UInt8}) = nothing
ptrhelper(helper, x::Vector{UInt8}) = C_NULL
sethelper!(helper, x::Vector{UInt8}) = helper.blob = x

function getvalue(stmt, helper, values, i, ::Type{Vector{UInt8}})
    len = helper.length[1]
    blob = Vector{UInt8}(undef, len)
    ptr = pointer(values, i)
    API.setbuffer!(ptr, pointer(blob))
    API.setbufferlength!(ptr, len)
    API.mysql_stmt_fetch_column(stmt.ptr, convert(Ptr{Cvoid}, ptr), i - 1, 0)
    return blob
end

inithelper!(helper, x::Dec64) = nothing
ptrhelper(helper, x::Dec64) = C_NULL

function getvalue(stmt, helper, values, i, ::Type{Dec64})
    len = helper.length[1]
    str = Base._string_n(len)
    ptr = pointer(values, i)
    API.setbuffer!(ptr, pointer(str))
    API.setbufferlength!(ptr, len)
    API.mysql_stmt_fetch_column(stmt.ptr, convert(Ptr{Cvoid}, ptr), i - 1, 0)
    return parse(Dec64, str)
end

defaultvalue(T) = zero(T)
defaultvalue(::Type{Union{Missing, T}}) where {T} = defaultvalue(T)
defaultvalue(::Type{API.Bit}) = API.Bit(0)
defaultvalue(::Type{T}) where {T <: Dates.TimeType} = convert(API.MYSQL_TIME, Date(2000))
defaultvalue(::Type{String}) = ""
defaultvalue(::Type{Vector{UInt8}}) = UInt8[]

function returnbind!(helper, binds, i, type, ::Type{T}) where {T}
    x = defaultvalue(T)
    inithelper!(helper, x)
    ptr = pointer(binds, i)
    API.setbuffer!(ptr, ptrhelper(helper, x))
    API.setbuffertype!(ptr, type)
    helper.typeset = true
    return
end

function bind!(helper, binds, i, x::Missing)
    helper.is_null[1] = true
    return
end

function bind!(helper, binds, i, x::Real)
    if !helper.typeset
        inithelper!(helper, x)
        # set buffer address
        ptr = pointer(binds, i)
        API.setbuffer!(ptr, ptrhelper(helper, x))
        # set buffer_type
        API.setbuffertype!(ptr, API.mysqltype(x))
        typeof(x) <: Unsigned && API.setisunsigned!(ptr, true)
        helper.typeset = true
    end
    sethelper!(helper, x)
    helper.is_null[1] = false
    return
end

function bind!(helper, binds, i, x::Dates.TimeType)
    t = convert(API.MYSQL_TIME, x)
    if !helper.typeset
        helper.time = API.MYSQL_TIME[t]
        # set buffer address
        ptr = pointer(binds, i)
        API.setbuffer!(ptr, pointer(helper.time))
        # set buffer_type
        API.setbuffertype!(ptr, API.mysqltype(x))
        helper.typeset = true
    end
    helper.time[1] = t
    helper.is_null[1] = false
    return
end

val(x) = x
val(x::API.Bit) = API.bitvalue(x)
val(x::DecFP.DecimalFloatingPoint) = string(x)

len(x::String) = sizeof(x)
len(x::Vector{UInt8}) = length(x)

function bind!(helper, binds, i, x::Union{Vector{UInt8}, String, API.Bit, DecFP.DecimalFloatingPoint})
    ptr = pointer(binds, i)
    y = val(x)
    if !helper.typeset
        # set buffer_type
        API.setbuffertype!(ptr, API.mysqltype(y))
        helper.typeset = true
    end
    sethelper!(helper, y)
    API.setbuffer!(ptr, pointer(y))
    API.setbufferlength!(ptr, len(y))
    helper.is_null[1] = false
    helper.length[1] = len(y)
    return
end
