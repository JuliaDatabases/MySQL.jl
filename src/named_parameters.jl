# Named parameters for prepared statements. The server's prepared statements take positional
# `?` markers only, so `DBInterface.prepare` rewrites each `:name` to `?` and keeps the names,
# and `DBInterface.execute` looks each value up by name in a NamedTuple or AbstractDict.

"""
    MySQL.NamedSQL

The SQL of a statement with named parameters as the server prepares it: `sql` has each
`:name` replaced by `?`, and `names[i]` is the name of the `i`-th `?` (a reused name repeats).
"""
struct NamedSQL
    sql::String
    names::Vector{Symbol}
end

is_name_start(b::UInt8) = return (UInt8('a') <= b <= UInt8('z')) | (UInt8('A') <= b <= UInt8('Z')) | (b == UInt8('_')) | (b >= 0x80)
is_name_char(b::UInt8) = return is_name_start(b) | (UInt8('0') <= b <= UInt8('9'))

"""
    MySQL.named_sql(sql, no_backslash_escapes) -> Union{Nothing, NamedSQL}

Finds the `:name` parameters of `sql` the way the server's lexer reads the text, and returns
the rewritten SQL, or `nothing` when `sql` has none. A name starts with a letter, `_`, or a
non-ASCII character, and continues with those or digits; `:=` and `:1` are not parameters.
String literals (`'...'` and `"..."`, where a backslash escapes the next byte unless
`no_backslash_escapes`), backtick identifiers, and comments (`#`, `-- `, `/* */`) are skipped.
Executable comments (`/*! */`, `/*M! */`) are skipped too: the server runs or ignores them
depending on its version, so their text is never changed.
"""
function named_sql(sql::AbstractString, no_backslash_escapes::Bool)
    # Positional SQL usually has no colon at all: one memchr.
    findfirst(==(UInt8(':')), codeunits(sql)) === nothing && return nothing
    str = String(sql)
    bytes = codeunits(str)
    span = next_name(bytes, 1, no_backslash_escapes)
    span === nothing && return nothing
    names = Symbol[]
    out = UInt8[]
    copied = 0   # bytes[1:copied] are already in `out`
    while span !== nothing
        colon, stop = span
        push!(names, Symbol(SubString(str, colon + 1, prevind(str, stop + 1))))
        append!(out, view(bytes, (copied + 1):(colon - 1)))
        push!(out, UInt8('?'))
        copied = stop
        span = next_name(bytes, stop + 1, no_backslash_escapes)
    end
    append!(out, view(bytes, (copied + 1):length(bytes)))
    return NamedSQL(String(out), names)
end

# `(colon, stop)`: the byte range of the next `:name` at or after `i`, or `nothing`.
function next_name(bytes::Base.CodeUnits{UInt8, String}, i::Int, no_backslash_escapes::Bool)
    n = length(bytes)
    while i <= n
        b = bytes[i]
        if b == UInt8('\'') || b == UInt8('"')
            i = skip_quoted(bytes, i, !no_backslash_escapes)
        elseif b == UInt8('`')
            i = skip_quoted(bytes, i, false)
        elseif b == UInt8('#') || (b == UInt8('-') && i < n && bytes[i + 1] == UInt8('-') &&
                                   (i + 2 > n || bytes[i + 2] <= 0x20 || bytes[i + 2] == 0x7f))
            newline = findnext(==(UInt8('\n')), bytes, i)
            i = newline === nothing ? n + 1 : newline + 1
        elseif b == UInt8('/') && i < n && bytes[i + 1] == UInt8('*')
            i += 2
            while i < n && !(bytes[i] == UInt8('*') && bytes[i + 1] == UInt8('/'))
                i += 1
            end
            i += 2
        elseif b == UInt8(':') && i < n && is_name_start(bytes[i + 1])
            stop = i + 1
            while stop < n && is_name_char(bytes[stop + 1])
                stop += 1
            end
            return (i, stop)
        else
            i += 1
        end
    end
    return nothing
end

# Index just past the quoted run that starts at `bytes[i]`. A doubled quote (`''`) ends one
# run and starts the next, which skips the same bytes.
function skip_quoted(bytes::Base.CodeUnits{UInt8, String}, i::Int, backslash_escapes::Bool)
    q = bytes[i]
    i += 1
    while i <= length(bytes)
        b = bytes[i]
        b == q && return i + 1
        i += (backslash_escapes && b == UInt8('\\')) ? 2 : 1
    end
    return i
end

# The values of a named statement's `?` markers, looked up by name in a NamedTuple or
# AbstractDict; the positional encoder iterates it like a tuple.
struct NamedValues{T}
    names::Vector{Symbol}
    params::T
end

Base.length(v::NamedValues) = return length(v.names)
Base.getindex(v::NamedValues, i::Int) = return param_value(v.params, v.names[i])
Base.iterate(v::NamedValues, i::Int=1) = return i > length(v.names) ? nothing : (v[i], i + 1)

has_param(p::NamedTuple, name::Symbol) = return haskey(p, name)
param_value(p::NamedTuple, name::Symbol) = return getfield(p, name)
has_param(p::AbstractDict, name::Symbol) = return haskey(p, name) || haskey(p, String(name))
param_value(p::AbstractDict, name::Symbol) = return haskey(p, name) ? p[name] : p[String(name)]

function named_values(names::Vector{Symbol}, params::Union{NamedTuple, AbstractDict})
    for name in names
        has_param(params, name) || missing_param(name)
    end
    return NamedValues(names, params)
end

# A tuple or vector binds one value per marker in marker order, the way MariaDB binds its own
# `:name` markers under sql_mode=ORACLE.
named_values(names::Vector{Symbol}, params::Union{Tuple, AbstractVector}) = return params

# A row has names but iterates in column order, which need not match the markers.
named_values(names::Vector{Symbol}, params) = throw(MySQLInterfaceError(
    "a statement with named parameters takes a NamedTuple or AbstractDict (bound by name) or a tuple or vector (bound in marker order), not a $(typeof(params))",
))

@noinline missing_param(name::Symbol) = throw(MySQLInterfaceError("no value for named parameter :$name"))
