# Convert C pointers returned from MySQL C calls to Julia Datastructures.

"""
Given a MYSQL type get the corresponding julia type.
"""
function mysql_get_julia_type(mysqltype)
    if (mysqltype == MYSQL_TYPE_BIT)
        return Union{Missings.Missing, Cuchar}

    elseif (mysqltype == MYSQL_TYPE_TINY ||
            mysqltype == MYSQL_TYPE_ENUM)
        return Union{Missings.Missing, Cchar}

    elseif (mysqltype == MYSQL_TYPE_SHORT)
        return Union{Missings.Missing, Cshort}

    elseif (mysqltype == MYSQL_TYPE_LONG ||
            mysqltype == MYSQL_TYPE_INT24)
        return Union{Missings.Missing, Cint}

    elseif (mysqltype == MYSQL_TYPE_LONGLONG)
        return Union{Missings.Missing, Int64}

    elseif (mysqltype == MYSQL_TYPE_FLOAT)
        return Union{Missings.Missing, Cfloat}

    elseif (mysqltype == MYSQL_TYPE_DECIMAL ||
            mysqltype == MYSQL_TYPE_NEWDECIMAL ||
            mysqltype == MYSQL_TYPE_DOUBLE)
        return Union{Missings.Missing, Cdouble}

    elseif (mysqltype == MYSQL_TYPE_NULL ||
            mysqltype == MYSQL_TYPE_SET ||
            mysqltype == MYSQL_TYPE_TINY_BLOB ||
            mysqltype == MYSQL_TYPE_MEDIUM_BLOB ||
            mysqltype == MYSQL_TYPE_LONG_BLOB ||
            mysqltype == MYSQL_TYPE_BLOB ||
            mysqltype == MYSQL_TYPE_GEOMETRY)
        return Union{Missings.Missing, String}

    elseif (mysqltype == MYSQL_TYPE_YEAR)
        return Union{Missings.Missing, Clong}

    elseif (mysqltype == MYSQL_TYPE_TIMESTAMP)
        return Union{Missings.Missing, DateTime}

    elseif (mysqltype == MYSQL_TYPE_DATE)
        return Union{Missings.Missing, Date}

    elseif (mysqltype == MYSQL_TYPE_TIME)
        return Union{Missings.Missing, DateTime}

    elseif (mysqltype == MYSQL_TYPE_DATETIME)
        return Union{Missings.Missing, DateTime}

    elseif (mysqltype == MYSQL_TYPE_VARCHAR ||
            mysqltype == MYSQL_TYPE_VAR_STRING ||
            mysqltype == MYSQL_TYPE_STRING)
        return Union{Missings.Missing, String}

    else
        return Union{Missings.Missing, String}

    end
end

"""
Get the C type that would be needed when using prepared statement.
"""

mysql_get_ctype{T}(jltype::Type{Union{Missings.Missing, T}}) = mysql_get_ctype(T)

function mysql_get_ctype(jtype::DataType)
    if (jtype == Date || jtype == DateTime)
        return MYSQL_TIME
    end

    return jtype
end

mysql_get_ctype(mysqltype::MYSQL_TYPE) =
    mysql_get_ctype(mysql_get_julia_type(mysqltype))

"""
Interpret a string as a julia datatype.
"""

mysql_interpret_field{T}(strval::String, ::Type{Union{Missings.Missing, T}}) = mysql_interpret_field(strval, T)

mysql_interpret_field(strval::String, ::Type{Cuchar}) = UInt8(strval[1])

mysql_interpret_field{T<:Number}(strval::String, ::Type{T}) =
    parse(T, strval)

mysql_interpret_field{T<:String}(strval::String, ::Type{T}) =
    strval

mysql_interpret_field(strval::String, ::Type{Date}) =
    convert(Date, strval)

mysql_interpret_field(strval::String, ::Type{DateTime}) =
    convert(DateTime, strval)

"""
Load a bytestring from `result` pointer given the field index `idx`.
"""
function mysql_load_string_from_resultptr(result, idx)
    deref = unsafe_load(result, idx)
    deref == C_NULL && return nothing
    strval = unsafe_string(deref)
    length(strval) == 0 && return nothing
    return strval
end

function mysql_metadata(result::MYSQL_RES)
    nfields = mysql_num_fields(result)
    rawfields = mysql_fetch_fields(result)
    return unsafe_wrap(Array, rawfields, nfields)
end

function mysql_metadata(stmtptr::Ptr{MYSQL_STMT})
    result = mysql_stmt_result_metadata(stmtptr)
    result == C_NULL && return nothing
    ret = mysql_metadata(result)
    mysql_free_result(result)
    return ret
end

"""
Returns an array of MYSQL_TYPE's corresponding to each field in the table.
"""
function mysql_get_field_types(result::MYSQL_RES)
    mysqlfields = mysql_metadata(result)
    return mysql_get_field_types(mysqlfields)
end

function mysql_get_field_types(mysqlfields::Array{MYSQL_FIELD})
    nfields = length(mysqlfields)
    mysqlfield_types = Array{MYSQL_TYPE}(nfields)
    for i = 1:nfields
        mysqlfield_types[i] = mysqlfields[i].field_type
    end
    return mysqlfield_types
end

"""
Get the result row `result` as a vector given the field types in an
 array `jtypes`.
"""
function mysql_get_row_as_vector(result, jtypes, isnullable)
    retvec = Array{Any}(length(jtypes))
    mysql_get_row_as_vector!(result, retvec, jtypes, isnullable)
    return retvec
end

function mysql_get_row_as_vector!(result, retvec, jtypes, isnullable)
    for i = 1:length(jtypes)
        strval = mysql_load_string_from_resultptr(result, i)
        if strval == nothing
            retvec[i] = missing
        else
            val = mysql_interpret_field(strval, jtypes[i])
            retvec[i] = val
        end
    end
end

function mysql_get_row_as_tuple(result, jtypes, isnullable)
    vec = mysql_get_row_as_vector(result, jtypes, isnullable)
    return tuple(vec...)
end

"""
Convert a mysql field type array to a julia type array.
"""
function mysql_get_jtype_array(mysqlfield_types)
    nfields = length(mysqlfield_types)
    jtypes = Array{Type}(nfields)
    for i = 1:nfields
        jtypes[i] = mysql_get_julia_type(mysqlfield_types[i])
    end
    return jtypes
end

"""
Returns true if `field` is nullable (i.e, it is not declared as `NOT NULL`)
"""
mysql_is_nullable(field) = field.flags & NOT_NULL_FLAG == 0

"""
Get an array of boolean values indicating whether the column is
 declared as `NULL`(true) or `NOT NULL`(false).
"""
mysql_get_nullable(result) = mysql_get_nullable(mysql_metadata(result))

function mysql_get_nullable(meta::Array{MYSQL_FIELD})
    isnullable = Array{Bool}(length(meta))
    for i = 1:length(meta)
        isnullable[i] = mysql_is_nullable(meta[i])
    end
    return isnullable
end

"""
Get the result as an array with each row as a vector.
"""
function mysql_get_result_as_array(result)
    nrows = mysql_num_rows(result)
    meta = mysql_metadata(result)
    retarr = Array{Array{Any}}(nrows)
    for i = 1:nrows
        retarr[i] = Array{Any}(meta.nfields)
        mysql_get_row_as_vector!(mysql_fetch_row(result), retarr[i],
                                 meta.jtypes, meta.is_nullables)
    end
    return retarr
end

function mysql_get_result_as_tuples(result::MySQLResult)
    nrows = mysql_num_rows(result)
    meta = mysql_metadata(result)
    retarr = Array{Tuple}(nrows)
    for i = 1:nrows
        retarr[i] = mysql_get_row_as_tuple(mysql_fetch_row(result), meta.jtypes,
                                           meta.is_nullables)
    end
    return retarr
end

"""
Fill the row indexed by `row` of the dataframe `df` with values from `result`.
"""
function populate_row!(df, nfields, result, row)
    for i = 1:nfields
        strval = mysql_load_string_from_resultptr(result, i)
        if strval == nothing
            df[row, i] = missing
        else
            df[row, i] = mysql_interpret_field(strval, eltype(df[i]))
        end
    end
end

"""
Returns a dataframe containing the data in `result`.
"""
function mysql_result_to_dataframe(result)
    nrows = mysql_num_rows(result)
    df = mysql_init_dataframe(mysql_metadata(result), nrows)
    nfields = length(df)
    for row = 1:nrows
        populate_row!(df, nfields, mysql_fetch_row(result), row)
    end
    return df
end

mysql_binary_interpret_field(buf, mysqltype) =
    mysql_binary_interpret_field(buf, mysql_get_ctype(mysqltype))

mysql_binary_interpret_field(buf, ::Type{String}) =
    unsafe_string(convert(Ptr{Cchar}, buf))

function mysql_binary_interpret_field(buf, T::Type)
    value = unsafe_load(convert(Ptr{T}, buf), 1)

    if typeof(value) == MYSQL_TIME
        if value.timetype == MYSQL_TIMESTAMP_DATE
            return convert(Date, value)

        elseif (value.timetype == MYSQL_TIMESTAMP_TIME
                || value.timetype == MYSQL_TIMESTAMP_DATETIME)
            return convert(DateTime, value)

        else
            throw(MySQLInterfaceError("MySQL Time type not recognized."))
        end
    end

    return value
end

"""
Populate a row in the dataframe `df` indexed by `row` given the number of
 fields `nfields`, the type of each field `mysqlfield_types` and an array
 `bindarr` to which the results are bound.
"""
function stmt_populate_row!(df, row_index, bindarr)
    for i = 1:length(bindarr)
        if bindarr[i].is_null_value != 0
            df[row_index, i] = missing
            continue
        end
        df[row_index, i] = mysql_binary_interpret_field(bindarr[i].buffer,
                                                        convert(MYSQL_TYPE, bindarr[i].buffer_type))
    end
end

"""
Get a bind array for binding to results.
"""
function mysql_bind_array(meta::MySQLMetadata)
    bindarr = Array{MYSQL_BIND}(meta.nfields)
    for i in 1:meta.nfields
        bufflen = zero(Culong)
        bindbuff = C_NULL
        ctype = mysql_get_ctype(meta.mtypes[i])

        if (ctype == String)
            bufflen = meta.lens[i] + 1
            bindbuff = Libc.malloc(meta.lens[i] + 1)
        else
            bufflen = sizeof(ctype)
            bindbuff = Libc.malloc(sizeof(ctype))
        end

        bindarr[i] = MYSQL_BIND(bindbuff, bufflen, meta.mtypes[i])

        # make `is_null pointer` point to `is_null_value` in the MYSQL_BIND struct.
        unsafe_store!(convert(Ptr{Ptr{Cchar}},
                              pointer(bindarr, i) + 8),
                      pointer(bindarr, i) + 8*8 + sizeof(Clong)*3 + 4*3 + 3)

    end # end for

    finalizer(bindarr, x -> begin; for b in x; Libc.free(b.buffer); end; end)
    return bindarr
end

"""
Get a bind array for binding to results.
"""
mysql_bind_array(meta::Vector{MYSQL_FIELD}) = mysql_bind_array(MySQLMetadata(meta))

"""
Initialize a dataframe for prepared statement results.
"""
mysql_init_dataframe(meta::Array{MYSQL_FIELD}, nrows) =
    mysql_init_dataframe(MySQLMetadata(meta), nrows)

function mysql_init_dataframe(meta, nrows)
    df = DataFrame(meta.jtypes, map(Symbol, meta.names), Int64(nrows))
end

function mysql_result_to_dataframe(hndl::MySQLHandle)
    meta = mysql_metadata(hndl.stmtptr)
    bindres = mysql_bind_array(meta)
    mysql_stmt_bind_result(hndl, bindres)
    mysql_stmt_store_result(hndl)
    nrows = mysql_stmt_num_rows(hndl)
    df = mysql_init_dataframe(meta, nrows)
    for ridx = 1:nrows
        mysql_stmt_fetch(hndl)
        stmt_populate_row!(df, ridx, bindres)
    end
    return df
end

function mysql_get_result_as_tuples(hndl::MySQLHandle)
    meta = mysql_metadata(hndl)
    bindres = mysql_bind_array(meta)
    mysql_stmt_bind_result(hndl, bindres)
    mysql_stmt_store_result(hndl)
    nrows = mysql_stmt_num_rows(hndl)
    retarr = Array{Tuple}(nrows)
    for i = 1:nrows
        mysql_stmt_fetch(hndl)
        retarr[i] = mysql_get_row_as_tuple(bindres, meta.jtypes, meta.is_nullables)
    end
    return retarr
end

function mysql_get_row_as_tuple(bindarr::Vector{MYSQL_BIND}, jtypes, isnullable)
    vec = Array{Any}(length(bindarr))
    for i = 1:length(bindarr)
        if bindarr[i].is_null_value != 0
            vec[i] = jtypes[i]()
        else
            val = mysql_binary_interpret_field(bindarr[i].buffer,
                                               convert(MYSQL_TYPE, bindarr[i].buffer_type))
            vec[i] = val
        end
    end
    return tuple(vec...)
end
