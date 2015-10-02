# Convert C pointers returned from MySQL C calls to Julia DataFrames

using DataFrames
using Dates
using Compat

const MYSQL_DEFAULT_DATE_FORMAT = "yyyy-mm-dd"
const MYSQL_DEFAULT_DATETIME_FORMAT = "yyyy-mm-dd HH:MM:SS"

function mysql_to_julia_type(mysqltype)
    if (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_BIT)
        @compat rettype = UInt8
        return rettype
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_TINY ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_ENUM)
        return Int8
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_SHORT)
        return Int16
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONG ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_INT24)
        return Int32
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONGLONG)
        return Int64
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_DECIMAL ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_NEWDECIMAL ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_FLOAT ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_DOUBLE)
        return Float64
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_NULL ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_TIMESTAMP ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_TIME ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_SET ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_TINY_BLOB ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_MEDIUM_BLOB ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONG_BLOB ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_BLOB ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_GEOMETRY)
        return String
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_YEAR)
        return Int64
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATE)
        return Date
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATETIME)
        return DateTime
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_VARCHAR ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_VAR_STRING ||
            mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_STRING)
        return String
    else
        return String
    end
end

"""
Fill the row indexed by `row` of the dataframe `df` with values from `result`.
"""
function populate_row!(df, numFields, mysqlfield_types::Array{Uint32}, result::MySQL.MYSQL_ROW, row)
    for i = 1:numFields
        value = ""
        obj = unsafe_load(result, i)
        if (obj != C_NULL)
            value = bytestring(obj)
        end

        if (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_BIT)
            if (!isempty(value))
                @compat df[row, i] = convert(UInt8, value[1])
            else
                @compat df[row, i] = UInt8(0)
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TINY ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_ENUM)
            if (!isempty(value))
                @compat df[row, i] = parse(Int8, value)
            else
                df[row, i] = NA
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_SHORT)
            if (!isempty(value))
                @compat df[row, i] = parse(Int16, value)
            else
                df[row, i] = NA
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONG ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_INT24)
            if (!isempty(value))
                @compat df[row, i] = parse(Int32, value)
            else
                df[row, i] = NA
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONGLONG)
            if (!isempty(value))
                @compat df[row, i] = parse(Int64, value)
            else
                df[row, i] = NA
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_FLOAT ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DOUBLE ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DECIMAL ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_NEWDECIMAL)
            if (!isempty(value))
                @compat df[row, i] = parse(Float64, value)
            else
                df[row, i] = NaN
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATE)
            if (!isempty(value))
                df[row, i] = Date(value, MYSQL_DEFAULT_DATE_FORMAT)
            else
                df[row, i] = NA
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATETIME)
            if (!isempty(value))
                df[row, i] = DateTime(value, MYSQL_DEFAULT_DATETIME_FORMAT)
            else
                df[row, i] = NA
            end
        else
            if (!isempty(value))
                df[row, i] = value
            else
                df[row, i] = ""
            end
        end
    end
end

"""
Returns a dataframe containing the data in `results`.
"""
function results_to_dataframe(results::MYSQL_RES)
    n_fields = MySQL.mysql_num_fields(results)
    fields = MySQL.mysql_fetch_fields(results)
    n_rows = MySQL.mysql_num_rows(results)
    jfield_types = Array(DataType, n_fields)
    field_headers = Array(Symbol, n_fields)
    mysqlfield_types = Array(Cuint, n_fields)

    for i = 1:n_fields
        mysql_field = unsafe_load(fields, i)
        jfield_types[i] = mysql_to_julia_type(mysql_field.field_type)
        field_headers[i] = symbol(bytestring(mysql_field.name))
        mysqlfield_types[i] = mysql_field.field_type
    end

    df = DataFrame(jfield_types, field_headers, n_rows)

    for row = 1:n_rows
        result = MySQL.mysql_fetch_row(results)
        populate_row!(df, n_fields, mysqlfield_types, result, row)
    end

    return df
end

"""
Populate a row in the dataframe `df` indexed by `row` given the number of fields `n_fields`,
 the type of each field `mysqlfield_types` and an array `jbindarr` to which the results are bound.
"""
function stmt_populate_row!(df, n_fields, mysqlfield_types::Array{Uint32}, row, jbindarr)
    for i = 1:n_fields
        value = ""

        if (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_BIT)
            value = unsafe_load(jbindarr[i].buffer_bit, 1)
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TINY ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_ENUM)
            value = unsafe_load(jbindarr[i].buffer_tiny, 1)
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_SHORT)
            value = unsafe_load(jbindarr[i].buffer_short, 1)
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONG ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_INT24)
            value = unsafe_load(jbindarr[i].buffer_int, 1)
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONGLONG)
            value = unsafe_load(jbindarr[i].buffer_long, 1)
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DECIMAL ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_NEWDECIMAL ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DOUBLE)
            value = unsafe_load(jbindarr[i].buffer_double, 1)
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_FLOAT)
            value = unsafe_load(jbindarr[i].buffer_float, 1)
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATETIME)
            mysql_time = unsafe_load(jbindarr[i].buffer_datetime, 1)
            if (mysql_time.year != 0)   ## to handle invalid data like 0000-00-00T00:00:00
                value = DateTime(mysql_time.year, mysql_time.month, mysql_time.day,
                                 mysql_time.hour, mysql_time.minute, mysql_time.second)
            else
                value = DateTime()
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATE)
            mysql_date = unsafe_load(jbindarr[i].buffer_date, 1)
            if (mysql_date.year != 0)   ## to handle invalid data like 0000-00-00
                value = Date(mysql_date.year, mysql_date.month, mysql_date.day)
            else
                value = Date()
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TIME)
            mysql_time = unsafe_load(jbindarr[i].buffer_time, 1)
            value = "$(mysql_time.hour):$(mysql_time.minute):$(mysql_time.second)"
        else
            data  = bytestring(jbindarr[i].buffer_string)

            if (!isempty(data))
                idx  = findfirst(data, '\0')
                value = bytestring(data[1:(idx == 0 ? endof(data) : idx-1)])
            end
        end

        df[row, i] = value
    end    
end

"""
Given the results metadata `metadata` and the prepared statement pointer `stmtptr`,
 get the results as a dataframe.
"""
function stmt_results_to_dataframe(metadata::MYSQL_RES, stmtptr::Ptr{MYSQL_STMT})
    n_fields = MySQL.mysql_num_fields(metadata)
    fields = MySQL.mysql_fetch_fields(metadata)
    
    MySQL.mysql_stmt_store_result(stmtptr)
    n_rows = MySQL.mysql_stmt_num_rows(stmtptr)
    
    jfield_types = Array(DataType, n_fields)
    field_headers = Array(Symbol, n_fields)
    mysqlfield_types = Array(Uint32, n_fields)
    
    mysql_bindarr = Array(MySQL.MYSQL_BIND, n_fields)
    jbindarr = Array(MySQL.JULIA_MYSQL_BIND, n_fields)

    for i = 1:n_fields
        mysql_field = unsafe_load(fields, i)
        jfield_types[i] = mysql_to_julia_type(mysql_field.field_type)
        field_headers[i] = symbol(bytestring(mysql_field.name))
        mysqlfield_types[i] = mysql_field.field_type
        field_length = mysql_field.field_length
    
        buffer_length::Culong = 0
        buffer_type::Cint = mysqlfield_types[i]

        jbind = MySQL.JULIA_MYSQL_BIND(field_length)
        bindbuff = C_NULL
        
        if (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONGLONG ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_INT24)
            buffer_length = sizeof(Clong)
            bindbuff = jbind.buffer_long
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_BIT)
            buffer_length = sizeof(Cuchar)
            bindbuff = jbind.buffer_bit
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TINY)
            buffer_length = sizeof(Cuchar)
            bindbuff = jbind.buffer_tiny
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_SHORT)
            buffer_length = sizeof(Cshort)
            bindbuff = jbind.buffer_short
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_ENUM ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONG)
            buffer_length = sizeof(Cint)
            bindbuff = jbind.buffer_int
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DECIMAL ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_NEWDECIMAL ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DOUBLE)
            buffer_length = sizeof(Cdouble)
            bindbuff = jbind.buffer_double
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_FLOAT)
            buffer_length = sizeof(Cfloat)
            bindbuff = jbind.buffer_float
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATE)
            buffer_length = sizeof(MySQL.MYSQL_TIME)
            bindbuff = jbind.buffer_date
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TIME)
            buffer_length = sizeof(MySQL.MYSQL_TIME)
            bindbuff = jbind.buffer_time
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_NULL ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TIMESTAMP ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_SET ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TINY_BLOB ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_MEDIUM_BLOB ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONG_BLOB ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_BLOB ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_GEOMETRY)
            # WARNING:::Please handle me !!!!!
            ### TODO ::: This needs to be handled differently !!!!
            buffer_length = field_length
            bindbuff = jbind.buffer_string
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_YEAR)
            buffer_length = sizeof(Clong)
            bindbuff = jbind.buffer_long
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATETIME)
            buffer_length = sizeof(MySQL.MYSQL_TIME)
            bindbuff = jbind.buffer_datetime
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_VARCHAR ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_VAR_STRING ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_STRING)
            buffer_length = field_length
            bindbuff = jbind.buffer_string
        else
            buffer_length = field_length
            bindbuff = jbind.buffer_string
        end
        
        bind = MySQL.MYSQL_BIND(reinterpret(Ptr{Void}, bindbuff),
                                buffer_length, buffer_type)

        mysql_bindarr[i] = bind
        jbindarr[i] = jbind
    end # end for
    
    df = DataFrame(jfield_types, field_headers, n_rows)
    response = MySQL.mysql_stmt_bind_result(stmtptr, reinterpret(Ptr{MYSQL_BIND}, pointer(mysql_bindarr)))
    if (response != 0)
        println("the error after bind result is ::: $(bytestring(MySQL.mysql_stmt_error(stmtptr)))")
        return df
    end

    for row = 1:n_rows
        result = MySQL.mysql_stmt_fetch_row(stmtptr)
        if (result == C_NULL)
            println("Could not fetch row ::: $(bytestring(MySQL.mysql_stmt_error(stmtptr)))")
            return df
        else
            stmt_populate_row!(df, n_fields, mysqlfield_types, row, jbindarr)
        end
    end
    return df
end
