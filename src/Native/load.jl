# Native-only MySQL.load fixes. The shared fallback keeps Connector/C 1.x behavior.

function MySQL.quoteid(::Connection, str)
    name = String(str)
    (ncodeunits(name) >= 2 && first(name) == '`' && last(name) == '`') && return name
    return escape_identifier(name)
end

function MySQL.load(itr, conn::Connection, name::AbstractString="mysql_" * Random.randstring(5); append::Bool=true, quoteidentifiers::Bool=true, debug::Union{Bool, Symbol}=false, limit::Integer=typemax(Int64), kw...)
    debug in (false, true, :values) || throw(ArgumentError("debug must be false, true, or :values"))
    return MySQL._load(
        itr,
        conn,
        name;
        append=append,
        quoteidentifiers=quoteidentifiers,
        debug_statements=debug !== false,
        debug_values=debug === :values,
        debug_all_statements=debug !== false,
        limit=limit,
        kw...,
    )
end
