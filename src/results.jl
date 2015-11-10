# Convert C pointers returned from MySQL C calls to Julia Datastructures.

using DataFrames
using Compat

const MYSQL_DEFAULT_DATE_FORMAT = "yyyy-mm-dd"
const MYSQL_DEFAULT_DATETIME_FORMAT = "yyyy-mm-dd HH:MM:SS"

if VERSION > v"0.3.11"
    c_malloc = Libc.malloc
    c_free = Libc.free
end

"""
Given a MYSQL type get the corresponding julia type.
"""
function mysql_get_julia_type(mysqltype::MYSQL_TYPE)
    if (mysqltype == MYSQL_TYPE_BIT)
        return Cuchar

    elseif (mysqltype == MYSQL_TYPE_TINY ||
            mysqltype == MYSQL_TYPE_ENUM)
        return Cchar

    elseif (mysqltype == MYSQL_TYPE_SHORT)
        return Cshort

    elseif (mysqltype == MYSQL_TYPE_LONG ||
            mysqltype == MYSQL_TYPE_INT24)
        return Cint

    elseif (mysqltype == MYSQL_TYPE_LONGLONG)
        return Int64

    elseif (mysqltype == MYSQL_TYPE_FLOAT)
        return Cfloat

    elseif (mysqltype == MYSQL_TYPE_DECIMAL ||
            mysqltype == MYSQL_TYPE_NEWDECIMAL ||
            mysqltype == MYSQL_TYPE_DOUBLE)
        return Cdouble

    elseif (mysqltype == MYSQL_TYPE_NULL ||
            mysqltype == MYSQL_TYPE_SET ||
            mysqltype == MYSQL_TYPE_TINY_BLOB ||
            mysqltype == MYSQL_TYPE_MEDIUM_BLOB ||
            mysqltype == MYSQL_TYPE_LONG_BLOB ||
            mysqltype == MYSQL_TYPE_BLOB ||
            mysqltype == MYSQL_TYPE_GEOMETRY)
        return AbstractString

    elseif (mysqltype == MYSQL_TYPE_YEAR)
        return Clong

    elseif (mysqltype == MYSQL_TYPE_TIMESTAMP)
        return Cint

    elseif (mysqltype == MYSQL_TYPE_DATE)
        return MySQLDate

    elseif (mysqltype == MYSQL_TYPE_TIME)
        return MySQLTime

    elseif (mysqltype == MYSQL_TYPE_DATETIME)
        return MySQLDateTime

    elseif (mysqltype == MYSQL_TYPE_VARCHAR ||
            mysqltype == MYSQL_TYPE_VAR_STRING ||
            mysqltype == MYSQL_TYPE_STRING)
        return AbstractString

    else
        return AbstractString

    end
end

"""
Get the C type that would be needed when using prepared statement.
"""
function mysql_get_ctype(jtype::DataType)
    if (jtype == MySQLDate || jtype == MySQLTime || jtype == MySQLDateTime)
        return MYSQL_TIME
    end

    return jtype
end

mysql_get_ctype(mysqltype::MYSQL_TYPE) = 
    mysql_get_ctype(mysql_get_julia_type(mysqltype))

"""
Interpret a string as a julia datatype.
"""
mysql_interpret_field(strval::AbstractString,
                      jtype::Type{Cuchar}) = strval[1]

mysql_interpret_field{T<:Number}(strval::AbstractString,
                                 jtype::Type{T}) = parse(T, strval)

mysql_interpret_field{T<:AbstractString}(strval::AbstractString,
                                         jtype::Type{T}) = strval

mysql_interpret_field(strval::AbstractString,
                      jtype::Type{MySQLDate}) = MySQLDate(strval)

mysql_interpret_field(strval::AbstractString,
                      jtype::Type{MySQLTime}) = MySQLTime(strval)

mysql_interpret_field(strval::AbstractString,
                      jtype::Type{MySQLDateTime}) = MySQLDateTime(strval)

"""
Load a bytestring from `result` pointer given the field index `idx`.
"""
function mysql_load_string_from_resultptr(result::MYSQL_ROW, idx)
    deref = unsafe_load(result, idx)

    if deref == C_NULL
        return Void
    end

    strval = bytestring(deref)

    if length(strval) == 0
        return Void
    end

    return strval
end

"""
Returns an array of MYSQL_FIELD. This array contains metadata information such
 as field type and field length etc. (see types.jl)
"""
function mysql_get_field_metadata(result::MYSQL_RES)
    nfields = mysql_num_fields(result)
    rawfields = mysql_fetch_fields(result)

    mysqlfields = Array(MYSQL_FIELD, nfields)

    for i = 1:nfields
        mysqlfields[i] = unsafe_load(rawfields, i)
    end

    return mysqlfields
end

"""
Returns an array of MYSQL_TYPE's corresponding to each field in the table.
"""
function mysql_get_field_types(result::MYSQL_RES)
    mysqlfields = mysql_get_field_metadata(result)
    return mysql_get_field_types(mysqlfields)
end

function mysql_get_field_types(mysqlfields::Array{MYSQL_FIELD})
    nfields = length(mysqlfields)
    mysqlfield_types = Array(MYSQL_TYPE, nfields)

    for i = 1:nfields
        mysqlfield_types[i] = mysqlfields[i].field_type
    end

    return mysqlfield_types
end

"""
Get the result row `result` as a vector given the field types in an
 array `mysqlfield_types`.
"""
function mysql_get_row_as_vector(result::MYSQL_ROW)
    mysqlfield_types = mysql_get_field_types(result)
    retvec = Vector(Any, length(mysqlfield_types))
    mysql_get_row_as_vector!(result, mysqlfield_types, retvec)
    return retvec
end

function mysql_get_row_as_vector!(result::MYSQL_ROW,
                                  mysqlfield_types::Array{MYSQL_TYPE},
                                  retvec::Vector{Any})
    for i = 1:length(mysqlfield_types)
        strval = mysql_load_string_from_resultptr(result, i)

        if strval == Void
            retvec[i] = Void
        else
            retvec[i] = mysql_interpret_field(strval,
                                     mysql_get_julia_type(mysqlfield_types[i]))
        end
    end
end

"""
Get the result as an array with each row as a vector.
"""
function mysql_get_result_as_array(result::MYSQL_RES)
    nrows = mysql_num_rows(result)
    nfields = mysql_num_fields(result)

    retarr = Array(Array{Any}, nrows)
    mysqlfield_types = mysql_get_field_types(result)

    for i = 1:nrows
        retarr[i] = Array(Any, nfields)
        mysql_get_row_as_vector!(mysql_fetch_row(result),
                                 mysqlfield_types, retarr[i])
    end

    return retarr
end

function MySQLRowIterator(result)
    nfields = mysql_num_fields(result)
    mysqlfield_types = mysql_get_field_types(result)
    nrows = mysql_num_rows(result)
    MySQLRowIterator(result, Array(Any, nfields), mysqlfield_types, nrows)
end

function Base.start(itr::MySQLRowIterator)
    true
end

function Base.next(itr::MySQLRowIterator, state)
    mysql_get_row_as_vector!(mysql_fetch_row(itr.result), itr.mysqlfield_types,
                             itr.row)
    itr.rowsleft -= 1
    return (itr.row, state)
end

function Base.done(itr::MySQLRowIterator, state)
    itr.rowsleft == 0
end

"""
Fill the row indexed by `row` of the dataframe `df` with values from `result`.
"""
function populate_row!(df, nfields, result::MYSQL_ROW, row, jfield_types)
    for i = 1:nfields
        strval = mysql_load_string_from_resultptr(result, i)
        if strval == Void
            df[row, i] = NA
        else
            df[row, i] = mysql_interpret_field(strval, jfield_types[i])
        end
    end
end

"""
Returns a dataframe containing the data in `result`.
"""
function mysql_result_to_dataframe(result::MYSQL_RES)
    nfields = mysql_num_fields(result)
    fields = mysql_fetch_fields(result)
    nrows = mysql_num_rows(result)

    jfield_types = Array(DataType, nfields)
    field_headers = Array(Symbol, nfields)
    mysqlfield_types = Array(Cuint, nfields)

    for i = 1:nfields
        mysql_field = unsafe_load(fields, i)
        jfield_types[i] = mysql_get_julia_type(mysql_field.field_type)
        field_headers[i] = symbol(bytestring(mysql_field.name))
        mysqlfield_types[i] = mysql_field.field_type
    end

    df = DataFrame(jfield_types, field_headers, @compat Int64(nrows))
    for row = 1:nrows
        populate_row!(df, nfields, mysql_fetch_row(result), row, jfield_types)
    end
    return df
end

mysql_binary_interpret_field(buf, mysqltype) =
    mysql_binary_interpret_field(buf, mysql_get_ctype(mysqltype))

mysql_binary_interpret_field(buf, ::Type{AbstractString}) =
    bytestring(convert(Ptr{Cchar}, buf))

function mysql_binary_interpret_field(buf, T::Type)
    value = unsafe_load(convert(Ptr{T}, buf), 1)

    if (typeof(value) == MYSQL_TIME)
        if (value.timetype == MYSQL_TIMESTAMP_DATE)
            return MySQLDate(value)

        elseif (value.timetype == MYSQL_TIMESTAMP_TIME)
            return MySQLTime(value)

        elseif (value.timetype == MYSQL_TIMESTAMP_DATETIME)
            return MySQLDateTime(value)

        else
            error("MySQL Time type not recognized.")
        end
    end

    return value
end

"""
Populate a row in the dataframe `df` indexed by `row` given the number of
 fields `nfields`, the type of each field `mysqlfield_types` and an array
 `bindarr` to which the results are bound.
"""
function stmt_populate_row!(df, mysqlfield_types::Array{MYSQL_TYPE}, row,
                            bindarr)
    for i = 1:length(mysqlfield_types)
        if bindarr[i].is_null_value != 0
            df[row, i] = NA
            continue
        end

        buffer = bindarr[i].buffer
        df[row, i] = mysql_binary_interpret_field(buffer, mysqlfield_types[i])
    end
end

"""
Given the result metadata `metadata` and the prepared statement pointer
 `stmtptr`, get the result as a dataframe.
"""
function mysql_stmt_result_to_dataframe(metadata::MYSQL_RES,
                                        stmtptr::Ptr{MYSQL_STMT})
    nfields = mysql_num_fields(metadata)
    fields = mysql_fetch_fields(metadata)
    
    mysql_stmt_store_result(stmtptr)
    nrows = mysql_stmt_num_rows(stmtptr)
    
    jfield_types = Array(DataType, nfields)
    field_headers = Array(Symbol, nfields)
    mysqlfield_types = Array(MYSQL_TYPE, nfields)
    
    mysql_bindarr = Array(MYSQL_BIND, nfields)

    for i = 1:nfields
        mysql_field = unsafe_load(fields, i)
        jfield_types[i] = mysql_get_julia_type(mysql_field.field_type)
        field_headers[i] = symbol(bytestring(mysql_field.name))
        mysqlfield_types[i] = mysql_field.field_type
        field_length = mysql_field.field_length
    
        buffer_length::Culong = zero(Culong)
        buffer_type = convert(Cint, mysqlfield_types[i])
        bindbuff = C_NULL
        ctype = mysql_get_ctype(jfield_types[i])

        if (ctype == AbstractString)
            buffer_length = field_length + 1
            bindbuff = c_malloc(field_length + 1)
        else
            buffer_length = sizeof(ctype)
            bindbuff = c_malloc(sizeof(ctype))
        end

        mysql_bindarr[i] = MYSQL_BIND(bindbuff, buffer_length, buffer_type)

        # now we have to make the is_null pointer point
        # to is_null_value in the MYSQL_BIND struct.
        unsafe_store!(convert(Ptr{Ptr{Cchar}},
                              pointer(mysql_bindarr, i) + 8),
                      pointer(mysql_bindarr, i) + 103)

    end # end for
    
    df = DataFrame(jfield_types, field_headers, @compat Int64(nrows))
    response = mysql_stmt_bind_result(stmtptr, pointer(mysql_bindarr))

    if (response != 0)
        error("Failed to bind results")
    end

    for row = 1:nrows
        result = mysql_stmt_fetch(stmtptr)
        stmt_populate_row!(df, mysqlfield_types, row, mysql_bindarr)
    end

    for i = 1:nfields
        c_free(mysql_bindarr[i].buffer)
    end

    return df
end
