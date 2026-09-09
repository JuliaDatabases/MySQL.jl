# `MySQL.load`: create a table from a Tables.jl source and insert its rows in batches through
# prepared multi-row `INSERT` statements inside one transaction.

const VALID_QUOTED_IDENTIFIER = r"^`(?:``|[^`])*`(?:\.`(?:``|[^`])*`)*$"

# Already-quoted identifiers pass through only when they are well formed (embedded backticks
# doubled); anything else is (re)quoted with `escape_identifier`.
function quoteid(str)
    name = String(str)
    wrapped = ncodeunits(name) >= 2 && first(name) == '`' && last(name) == '`'
    wrapped || return escape_identifier(name)
    occursin(VALID_QUOTED_IDENTIFIER, name) && return name
    return escape_identifier(chop(name; head=1, tail=1))
end
quoteid(::Connection, str) = quoteid(str)

const SQLTYPES = Dict{Type, String}(
    Int8 => "TINYINT",
    Int16 => "SMALLINT",
    Int32 => "INTEGER",
    Int64 => "BIGINT",
    UInt8 => "TINYINT UNSIGNED",
    UInt16 => "SMALLINT UNSIGNED",
    UInt32 => "INTEGER UNSIGNED",
    UInt64 => "BIGINT UNSIGNED",
    Float32 => "FLOAT",
    Float64 => "DOUBLE",
    Bool => "BOOL",
    Vector{UInt8} => "BLOB",
    String => "VARCHAR(255)",
    Date => "DATE",
    Time => "TIME",
    DateTime => "DATETIME",
    DateAndTime => "DATETIME(6)",
)

# The column type `MySQL.load` generates for a Julia element type (`Missing` is stripped
# first). Package extensions add methods for their types (see ext/).
function sqltype(T)
    D = nonmissingtype(T)
    D === Union{} && return "VARCHAR(255)"
    return sqltype_nonmissing(D)
end
sqltype(T, coltypes, name) = return haskey(coltypes, name) ? coltypes[name] : sqltype(T)

sqltype_nonmissing(D::Type) = return get(SQLTYPES, D, "VARCHAR(255)")

function sqltype_nonmissing(::Type{D}) where {D <: DataDecimals.Decimal}
    p, s = precision(D), DataDecimals.scale(D)
    p <= 65 && s <= 30 || throw(ArgumentError("MySQL DECIMAL requires precision <= 65 and scale <= 30"))
    return "DECIMAL($p, $s)"
end

sqltype_nonmissing(::Type{<:DataDecimals.DecimalValue}) = return throw(ArgumentError("DecimalValue needs an explicit DECIMAL precision and scale in coltypes"))

checkdupnames(names) = length(unique(map(x->lowercase(String(x)), names))) == length(names) || error("duplicate case-insensitive column names detected; mysql treats column names case insensitive")

function createtable(conn::Connection, nm::AbstractString, sch::Tables.Schema; debug::Bool=false, quoteidentifiers::Bool=true, createtableclause::AbstractString="CREATE TABLE", coltypes=Dict(), columnsuffix=Dict(), auto_increment_primary_key_name::Union{Nothing,AbstractString}=nothing)
    names = sch.names
    checkdupnames(names)
    types = [sqltype(T, coltypes, names[i]) for (i, T) in enumerate(sch.types)]
    columns = (string(quoteidentifiers ? quoteid(conn, String(names[i])) : names[i], ' ', types[i], ' ', get(columnsuffix, names[i], "")) for i = 1:length(names))
    auto_increment_column = if auto_increment_primary_key_name === nothing || isempty(auto_increment_primary_key_name)
        ""
    else
        primary_key_name = quoteidentifiers ? quoteid(conn, auto_increment_primary_key_name) : auto_increment_primary_key_name
        "$primary_key_name INT AUTO_INCREMENT PRIMARY KEY, "
    end
    debug && @info "executing create table statement: `$createtableclause $nm ($(auto_increment_column)$(join(columns, ", ")))`"
    return DBInterface.execute(conn, "$createtableclause $nm ($(auto_increment_column)$(join(columns, ", ")))")
end

# The server accepts at most 65535 `?` markers in one prepared statement.
const MAX_STATEMENT_PARAMS = 65535
const DEFAULT_LOAD_BATCHSIZE = 1000

# Rough wire size of one bound value, used to keep a batch's COM_STMT_EXECUTE packet well
# inside `max_allowed_packet` (large rows shrink the batch; a single row is never split).
load_value_bytes(x::AbstractString) = return ncodeunits(x) + 9
load_value_bytes(x::AbstractVector{UInt8}) = return length(x) + 9
load_value_bytes(x::DataDecimals.AbstractDecimal) = return ncodeunits(string(x)) + 9
load_value_bytes(::Any) = return 16

# Tables sources may reuse mutable byte storage when advancing to the next row.
load_value(x) = return x
load_value(x::AbstractVector{UInt8}) = return Vector{UInt8}(x)

# Keep only the current batch shape. Size-limited batches can have many distinct row
# counts; retaining all their statements also retains all their server-side metadata.
function load_batch!(stmt::Union{Nothing, Statement}, conn::Connection, params::Vector{Any}, nrows::Int, prefix::String, markers::String, debug::Bool)
    if stmt === nothing || stmt.nparams != length(params)
        stmt === nothing || DBInterface.close!(stmt)
        sql = prefix * join(Iterators.repeated(markers, nrows), ", ")
        debug && @info "executing insert statement: `$sql`"
        stmt = DBInterface.prepare(conn, sql)
    end
    try
        DBInterface.execute(stmt, params)
    catch
        DBInterface.close!(stmt)
        rethrow()
    end
    empty!(params)
    return stmt
end

"""
    MySQL.load(table, conn, name; append=true, quoteidentifiers=true, limit=typemax(Int64), batchsize=1000, createtableclause=nothing, coltypes=Dict(), columnsuffix=Dict(), auto_increment_primary_key_name=nothing, debug=false)
    table |> MySQL.load(conn, name; kw...)

Loads a Tables.jl source `table` into the table `name` of the database `conn` is connected
to, and returns the (quoted) table name.

It first detects the `Tables.Schema` of the table source and generates a `CREATE TABLE` statement
with the appropriate column names and types. If no table name is provided, one will be autogenerated, like `mysql_xxxxx`.
The `CREATE TABLE` clause can be provided manually by passing the `createtableclause` keyword argument
(default `"CREATE TABLE IF NOT EXISTS"` with `append=true`, else `"CREATE TABLE"`), which
would allow specifying a temporary table. With `append=false` the existing rows are deleted
before the new ones are inserted.
Column types can be overridden by providing the `coltypes` keyword argument as a `Dict` of
column name (given as a `Symbol`) to a string of the SQL type. This allows, for example, using
a `LONGBLOB` instead of `BLOB` for large binary data by doing `coltypes=Dict(:Photo => "LONGBLOB")`.
Column definitions can also be enhanced by providing arguments to `columnsuffix` as a `Dict` of
column name (given as a `Symbol`) to a string of the enhancement that will come after name and type like
`[column name] [column type] enhancements`. This allows, for example, specifying the charset of a string column
by doing something like `columnsuffix=Dict(:Name => "CHARACTER SET utf8mb4")`.
`auto_increment_primary_key_name` adds an `INT AUTO_INCREMENT PRIMARY KEY` column of that
name in front of the source columns.

Rows are inserted inside one transaction with prepared multi-row `INSERT` statements of up
to `batchsize` rows each (fewer when a batch would approach the packet limit, and at most
65535 bound values per statement, further bounded by `max_columns`); `limit` stops after
that many rows. The packet budget uses the client's `max_allowed_packet` option; set it
no higher than the server's value. Byte vectors are copied before advancing the source.

`debug=true` logs the generated statements without row values; `debug=:values` also logs
each inserted row's values.

Do note that databases vary wildly in requirements for `CREATE TABLE` and column definitions
so it can be extremely difficult to load data generically. You may just need to tweak some of the provided
keyword arguments, but you may also need to execute the `CREATE TABLE` and `INSERT` statements
yourself. If you run into issues, you can [open an issue](https://github.com/JuliaDatabases/MySQL.jl/issues) and
we can see if there's something we can do to make it easier to use this function.
"""
function load end

load(conn::Connection, table::AbstractString="mysql_"*Random.randstring(5); kw...) = return x -> load(x, conn, table; kw...)

function load(itr, conn::Connection, name::AbstractString="mysql_" * Random.randstring(5); append::Bool=true, quoteidentifiers::Bool=true, debug::Union{Bool, Symbol}=false, limit::Integer=typemax(Int64), batchsize::Integer=DEFAULT_LOAD_BATCHSIZE, kw...)
    debug in (false, true, :values) || throw(ArgumentError("debug must be false, true, or :values"))
    batchsize >= 1 || throw(ArgumentError("batchsize must be positive"))
    isopen(conn) || throw(ArgumentError("`MySQL.Connection` is closed"))
    debug_statements = debug !== false
    debug_values = debug === :values
    # get data
    rows = Tables.rows(itr)
    sch = Tables.schema(rows)
    if sch === nothing
        # we want to ensure we always have a schema, so materialize if needed
        rows = Tables.rows(Tables.columntable(rows))
        sch = Tables.schema(rows)
    end
    ncols = length(sch.names)
    maxparams = min(MAX_STATEMENT_PARAMS, conn.options.limits.max_columns)
    1 <= ncols <= maxparams || throw(ArgumentError("source must have 1:$maxparams columns"))
    # ensure table exists
    if quoteidentifiers
        name = quoteid(conn, name)
    end
    # Use IF NOT EXISTS when appending to avoid warnings on subsequent loads
    createclause = append ? "CREATE TABLE IF NOT EXISTS" : "CREATE TABLE"
    try
        createtable(conn, name, sch; quoteidentifiers=quoteidentifiers, debug=debug_statements, createtableclause=createclause, kw...)
    catch e
        @warn "error creating table" (e, catch_backtrace())
    end
    if !append
        debug_statements && @info "executing delete statement: `DELETE FROM $name`"
        DBInterface.execute(conn, "DELETE FROM $name")
    end
    # rows per statement: the requested batch, the marker limit, and the packet budget
    maxrows = Int(min(batchsize, maxparams ÷ ncols))
    maxbytes = conn.options.limits.max_packet ÷ 4
    columns = join((quoteid(conn, string(column)) for column in sch.names), ", ")
    rowmarkers = "(" * join(Iterators.repeated("?", ncols), ", ") * ")"
    insert_prefix = "INSERT INTO $name ($columns) VALUES "
    # start a transaction for inserting rows
    DBInterface.transaction(conn) do
        stmt = nothing
        params = Any[]
        rowvals = Vector{Any}(undef, ncols)
        nbuffered = 0
        nbytes = 0
        try
            for (i, row) in enumerate(rows)
                i > limit && break
                r = Tables.Row(row)
                debug_values && @info "inserting row $i; $r"
                rowbytes = 0
                for j in 1:ncols
                    x = Tables.getcolumn(r, j)
                    rowvals[j] = load_value(x)
                    rowbytes += load_value_bytes(x)
                end
                # a row that would push the batch over the packet budget starts the next one
                if nbuffered > 0 && nbytes + rowbytes > maxbytes
                    stmt = load_batch!(stmt, conn, params, nbuffered, insert_prefix, rowmarkers, debug_statements)
                    nbuffered = 0
                    nbytes = 0
                end
                append!(params, rowvals)
                nbuffered += 1
                nbytes += rowbytes
                if nbuffered == maxrows
                    stmt = load_batch!(stmt, conn, params, nbuffered, insert_prefix, rowmarkers, debug_statements)
                    nbuffered = 0
                    nbytes = 0
                end
            end
            nbuffered > 0 && (stmt = load_batch!(stmt, conn, params, nbuffered, insert_prefix, rowmarkers, debug_statements))
        finally
            stmt === nothing || DBInterface.close!(stmt)
        end
    end

    return name
end
