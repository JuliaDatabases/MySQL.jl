# Convert C pointers returned from MySQL C calls to Julia Datastructures.

using DataFrames
using Dates
using Compat

const MYSQL_DEFAULT_DATE_FORMAT = "yyyy-mm-dd"
const MYSQL_DEFAULT_DATETIME_FORMAT = "yyyy-mm-dd HH:MM:SS"

"""
Given a MYSQL type get the corresponding julia type.
"""
function mysql_get_julia_type(mysqltype::MYSQL_TYPE)
    if (mysqltype == MYSQL_TYPES.MYSQL_TYPE_BIT)
        return Cuchar

    elseif (mysqltype == MYSQL_TYPES.MYSQL_TYPE_TINY ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_ENUM)
        return Cchar

    elseif (mysqltype == MYSQL_TYPES.MYSQL_TYPE_SHORT)
        return Cshort

    elseif (mysqltype == MYSQL_TYPES.MYSQL_TYPE_LONG ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_INT24)
        return Cint

    elseif (mysqltype == MYSQL_TYPES.MYSQL_TYPE_LONGLONG)
        return Clong

    elseif (mysqltype == MYSQL_TYPES.MYSQL_TYPE_DECIMAL ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_NEWDECIMAL ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_FLOAT ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_DOUBLE)
        return Cdouble

    elseif (mysqltype == MYSQL_TYPES.MYSQL_TYPE_NULL ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_TIMESTAMP ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_TIME ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_SET ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_TINY_BLOB ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_MEDIUM_BLOB ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_LONG_BLOB ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_BLOB ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_GEOMETRY)
        return String

    elseif (mysqltype == MYSQL_TYPES.MYSQL_TYPE_YEAR)
        return Clong

    elseif (mysqltype == MYSQL_TYPES.MYSQL_TYPE_DATE)
        return Date

    elseif (mysqltype == MYSQL_TYPES.MYSQL_TYPE_DATETIME)
        return DateTime

    elseif (mysqltype == MYSQL_TYPES.MYSQL_TYPE_VARCHAR ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_VAR_STRING ||
            mysqltype == MYSQL_TYPES.MYSQL_TYPE_STRING)
        return String

    else
        return String

    end
end

"""
Interpret a string as a julia datatype.
"""
function mysql_interpret_field(strval::String, jtype::DataType)
    if (jtype == Cuchar)
        return convert(Cuchar, strval[1])

    elseif (jtype == Cchar || jtype == Cshort || jtype == Cint ||
            jtype == Clong || jtype == Cdouble)
        return parse(jtype, strval)

    elseif (jtype == Date)
        return Date(strval, MYSQL_DEFAULT_DATE_FORMAT)

    elseif (jtype == DateTime)
        return DateTime(strval, MYSQL_DEFAULT_DATETIME_FORMAT)

    else
        return strval

    end

end

"""
Load a bytestring from `result` pointer given the field index `idx`.
"""
function mysql_load_string_from_resultptr(result::MYSQL_ROW, idx)
    deref = unsafe_load(result, idx)

    if deref == C_NULL
        return Nothing
    end

    strval = bytestring(deref)

    if length(strval) == 0
        return Nothing
    end

    return strval
end

"""
Returns an array of MYSQL_FIELD. This array contains metadata information such as
 field type and field length etc. (see types.jl)
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
Get the result row `result` as a vector given the field types in an array `mysqlfield_types`.
"""
function mysql_get_row_as_vector(result::MYSQL_ROW)
    mysqlfield_types = mysql_get_field_types(result)
    retvec = Vector(Any, length(mysqlfield_types))
    mysql_get_row_as_vector!(result, mysqlfield_types, retvec)
    return retvec
end

function mysql_get_row_as_vector!(result::MYSQL_ROW, mysqlfield_types::Array{MYSQL_TYPE},
                                     retvec::Vector{Any})
    for i = 1:length(mysqlfield_types)
        strval = mysql_load_string_from_resultptr(result, i)

        if strval == Nothing
            retvec[i] = Nothing
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
        mysql_get_row_as_vector!(mysql_fetch_row(result), mysqlfield_types, retarr[i])
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
    mysql_get_row_as_vector!(mysql_fetch_row(itr.result), itr.mysqlfield_types, itr.row)
    itr.rowsleft -= 1
    return (itr.row, state)
end

function Base.done(itr::MySQLRowIterator, state)
    itr.rowsleft == 0
end

"""
Fill the row indexed by `row` of the dataframe `df` with values from `result`.
"""
function populate_row!(df, mysqlfield_types::Array{MYSQL_TYPE}, result::MYSQL_ROW, row)
    for i = 1:length(mysqlfield_types)
        strval = mysql_load_string_from_resultptr(result, i)

        if strval == Nothing
            df[row, i] = NA
        else
            df[row, i] = mysql_interpret_field(strval,
                                               mysql_get_julia_type(mysqlfield_types[i]))
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

    df = DataFrame(jfield_types, field_headers, nrows)

    for row = 1:nrows
        populate_row!(df, mysqlfield_types, mysql_fetch_row(result), row)
    end

    return df
end

"""
Populate a row in the dataframe `df` indexed by `row` given the number of fields `nfields`,
 the type of each field `mysqlfield_types` and an array `jbindarr` to which the results are bound.
"""
function stmt_populate_row!(df, mysqlfield_types::Array{MYSQL_TYPE}, row, jbindarr)
    for i = 1:length(mysqlfield_types)
        if (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_BIT)
            value = unsafe_load(jbindarr[i].buffer_bit, 1)

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_TINY ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_ENUM)
            value = unsafe_load(jbindarr[i].buffer_tiny, 1)

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_SHORT)
            value = unsafe_load(jbindarr[i].buffer_short, 1)

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_LONG ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_INT24)
            value = unsafe_load(jbindarr[i].buffer_int, 1)

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_LONGLONG)
            value = unsafe_load(jbindarr[i].buffer_long, 1)

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_DECIMAL ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_NEWDECIMAL ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_DOUBLE)
            value = unsafe_load(jbindarr[i].buffer_double, 1)

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_FLOAT)
            value = unsafe_load(jbindarr[i].buffer_float, 1)

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_DATETIME)
            mysql_time = unsafe_load(jbindarr[i].buffer_datetime, 1)
            if (mysql_time.year != 0)   ## to handle invalid data like 0000-00-00T00:00:00
                value = DateTime(mysql_time.year, mysql_time.month, mysql_time.day,
                                 mysql_time.hour, mysql_time.minute, mysql_time.second)
            else
                value = DateTime()
            end

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_DATE)
            mysql_date = unsafe_load(jbindarr[i].buffer_date, 1)
            if (mysql_date.year != 0)   ## to handle invalid data like 0000-00-00
                value = Date(mysql_date.year, mysql_date.month, mysql_date.day)
            else
                value = Date()
            end

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_TIME)
            mysql_time = unsafe_load(jbindarr[i].buffer_time, 1)
            value = "$(mysql_time.hour):$(mysql_time.minute):$(mysql_time.second)"

        else
            value = bytestring(jbindarr[i].buffer_string)

        end

        df[row, i] = value
    end    
end

"""
Given the result metadata `metadata` and the prepared statement pointer `stmtptr`,
 get the result as a dataframe.
"""
function mysql_stmt_result_to_dataframe(metadata::MYSQL_RES, stmtptr::Ptr{MYSQL_STMT})
    nfields = mysql_num_fields(metadata)
    fields = mysql_fetch_fields(metadata)
    
    mysql_stmt_store_result(stmtptr)
    nrows = mysql_stmt_num_rows(stmtptr)
    
    jfield_types = Array(DataType, nfields)
    field_headers = Array(Symbol, nfields)
    mysqlfield_types = Array(Uint32, nfields)
    
    mysql_bindarr = Array(MYSQL_BIND, nfields)
    jbindarr = Array(MYSQL_JULIA_BIND, nfields)

    for i = 1:nfields
        mysql_field = unsafe_load(fields, i)
        jfield_types[i] = mysql_get_julia_type(mysql_field.field_type)
        field_headers[i] = symbol(bytestring(mysql_field.name))
        mysqlfield_types[i] = mysql_field.field_type
        field_length = mysql_field.field_length
    
        buffer_length::Culong = 0
        buffer_type::Cint = mysqlfield_types[i]

        jbind = MYSQL_JULIA_BIND(field_length)
        bindbuff = C_NULL
        
        if (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_LONGLONG ||
            mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_INT24)
            buffer_length = sizeof(Clong)
            bindbuff = jbind.buffer_long

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_BIT)
            buffer_length = sizeof(Cuchar)
            bindbuff = jbind.buffer_bit

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_TINY)
            buffer_length = sizeof(Cuchar)
            bindbuff = jbind.buffer_tiny

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_SHORT)
            buffer_length = sizeof(Cshort)
            bindbuff = jbind.buffer_short

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_ENUM ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_LONG)
            buffer_length = sizeof(Cint)
            bindbuff = jbind.buffer_int

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_DECIMAL ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_NEWDECIMAL ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_DOUBLE)
            buffer_length = sizeof(Cdouble)
            bindbuff = jbind.buffer_double

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_FLOAT)
            buffer_length = sizeof(Cfloat)
            bindbuff = jbind.buffer_float

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_DATE)
            buffer_length = sizeof(MYSQL_TIME)
            bindbuff = jbind.buffer_date

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_TIME)
            buffer_length = sizeof(MYSQL_TIME)
            bindbuff = jbind.buffer_time

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_NULL ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_TIMESTAMP ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_SET ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_TINY_BLOB ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_MEDIUM_BLOB ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_LONG_BLOB ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_BLOB ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_GEOMETRY)
            # WARNING:::Please handle me !!!!!
            ### TODO ::: This needs to be handled differently !!!!
            buffer_length = field_length
            bindbuff = jbind.buffer_string

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_YEAR)
            buffer_length = sizeof(Clong)
            bindbuff = jbind.buffer_long

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_DATETIME)
            buffer_length = sizeof(MYSQL_TIME)
            bindbuff = jbind.buffer_datetime

        elseif (mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_VARCHAR ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_VAR_STRING ||
                mysqlfield_types[i] == MYSQL_TYPES.MYSQL_TYPE_STRING)
            buffer_length = field_length
            bindbuff = jbind.buffer_string

        else
            buffer_length = field_length
            bindbuff = jbind.buffer_string

        end
        
        mysqlbind = MYSQL_BIND(reinterpret(Ptr{Void}, bindbuff),
                          buffer_length, buffer_type)

        mysql_bindarr[i] = mysqlbind
        jbindarr[i] = jbind
    end # end for
    
    df = DataFrame(jfield_types, field_headers, nrows)
    response = mysql_stmt_bind_result(stmtptr, reinterpret(Ptr{MYSQL_BIND},
                                                           pointer(mysql_bindarr)))
    if (response != 0)
        println("the error after bind result is ::: $(bytestring(mysql_stmt_error(stmtptr)))")
        return df
    end

    for row = 1:nrows
        result = mysql_stmt_fetch(stmtptr)
        if (result == C_NULL)
            println("Could not fetch row ::: $(bytestring(mysql_stmt_error(stmtptr)))")
            return df
        else
            stmt_populate_row!(df, mysqlfield_types, row, jbindarr)
        end
    end
    return df
end
