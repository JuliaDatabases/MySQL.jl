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
    elseif (mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATETIME ||
           mysqltype == MySQL.MYSQL_TYPES.MYSQL_TYPE_NEWDATE)
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
function populate_row(numFields::Int8, mysqlfield_types::Array{Uint32}, result::MySQL.MYSQL_ROW, df, row)
    for i = 1:numFields
        value = ""
        obj = unsafe_load(result.values, i)
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
        mysql_field = null
    end

    df = DataFrame(jfield_types, field_headers, n_rows)

    for row = 1:n_rows
        result = MySQL.mysql_fetch_row(results)
        populate_row(n_fields, mysqlfield_types, result, df, row)
        result = null
    end

    return df
end

function stmt_populate_row(n_fields::Int8, mysqlfield_types::Array{Uint32}, df, row, juBindArray)
    for i = 1:n_fields
        value = ""
        if (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TINY ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_ENUM ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_BIT)
            @compat value = parse(Int8, juBindArray[i].buffer_int[1])
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_SHORT)
            @compat value = parse(Int16, juBindArray[i].buffer_int[1])
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONG ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_INT24)
            @compat value = parse(Int32, juBindArray[i].buffer_int[1])
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONGLONG)
            @compat value = parse(Int64, juBindArray[i].buffer_long[1])
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DECIMAL ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_NEWDECIMAL)
            ### Not supported fully !!! this may work in some cases
            data  = juBindArray[i].buffer_string
            value = 0.0
            if (!isempty(data))
                idx  = findfirst(data, '\0')
                tmp_val = bytestring(data[1:(idx == 0 ? endof(data) : idx-1)])
                if (!isempty(tmp_val))
                    @compat value = parse(Float64, tmp_val)
                end
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_FLOAT ||
                mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DOUBLE)
            value = 0.0
            if (juBindArray[i].buffer_double[1] != C_NULL)
                @compat value = parse(Float64, juBindArray[i].buffer_double[1])
            end    
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATETIME)
            mysql_time = juBindArray[i].buffer_datetime[1]
            if (mysql_time.year != 0)   ## to handle invalid data like 0000-00-00T00:00:00
                value = DateTime(mysql_time.year, mysql_time.month, mysql_time.day,
                                 mysql_time.hour, mysql_time.minute, mysql_time.second)
            else
                value = DateTime()
            end
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATE)
            mysql_date = juBindArray[i].buffer_date[1]
            if (mysql_date.year != 0)   ## to handle invalid data like 0000-00-00
                value = Date(mysql_date.year, mysql_date.month, mysql_date.day)
            else
                value = Date()
            end
        else
            data  = juBindArray[i].buffer_string
            if (!isempty(data))
                idx  = findfirst(data, '\0')
                value = bytestring(data[1:(idx == 0 ? endof(data) : idx-1)])
            end
        end
        df[row, i] = value
    end    
end

function stmt_results_to_dataframe(results::Ptr{Cuchar}, stmtptr::Ptr{Cuchar}=C_NULL)
    n_fields = MySQL.mysql_num_fields(results)
    fields = MySQL.mysql_fetch_fields(results)
    
    MySQL.mysql_stmt_store_result(stmtptr)
    n_rows = MySQL.mysql_stmt_num_rows(stmtptr)
    
    jfield_types = Array(DataType, n_fields)
    field_headers = Array(Symbol, n_fields)
    mysqlfield_types = Array(Uint32, n_fields)
    bindArray = null
    juBindArray = null
    
    bindArray = MySQL.MYSQL_BIND[]
    juBindArray = MySQL.JU_MYSQL_BIND[]
    
    for i = 1:n_fields
        mysql_field = unsafe_load(fields, i)
        jfield_types[i] = Array(mysql_to_julia_type(mysql_field.field_type), n_rows)
        field_headers[i] = symbol(bytestring(mysql_field.name))
        mysqlfield_types[i] = mysql_field.field_type
        field_length = mysql_field.field_length
    
        tmp_long = Array(Culong)
        tmp_char = Array(Cchar)
        buffer_length::Culong = 0
        buffer_type::Cint = mysqlfield_types[i]
        my_buff_long = Array(Culong)
        my_buff_int = Array(Cint)
        my_buff_double = Array(Cdouble)
        my_buff_string = Array(Uint8, field_length)
        my_buff_datetime = Array(MySQL.MYSQL_TIME)
        my_buff
        
        if (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONGLONG ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_INT24)
            my_buff_long = Array(Culong)
            buffer_length = sizeof(Culong)
            my_buff = my_buff_long
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TINY ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_SHORT ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_ENUM ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONG ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_BIT)
            my_buff_int = Array(Cint)
            buffer_length = sizeof(Cint)
            my_buff = my_buff_int
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DECIMAL ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_NEWDECIMAL)
            ### TODO ::: This needs to be handled more efficiently !!
            ### there is no direct equivalent for this in Julia
            my_buff_string = zeros(Array(Uint8, field_length))
            buffer_length = field_length
            my_buff = my_buff_string
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_FLOAT ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DOUBLE)
            my_buff_double = Array(Cdouble)
            buffer_length = sizeof(Cdouble)
            my_buff = my_buff_double
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_NULL ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TIMESTAMP ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATE ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TIME ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_SET ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_TINY_BLOB ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_MEDIUM_BLOB ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_LONG_BLOB ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_BLOB ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_GEOMETRY)
            println("WARNING:::Please handle me !!!!!")
            ### TODO ::: This needs to be handled differently !!!!
            my_buff_string = zeros(Array(Uint8, field_length))
            buffer_length = field_length
            my_buff = my_buff_string
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_YEAR)
            my_buff_long = Array(Culong)
            buffer_length = sizeof(Culong)
            my_buff = my_buff_long
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_DATETIME ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_NEWDATE)
            my_buff_datetime = Array(MySQL.MYSQL_TIME)
            buffer_length = sizeof(MySQL.MYSQL_TIME)
            my_buff = my_buff_datetime
        elseif (mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_VARCHAR ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_VAR_STRING ||
            mysqlfield_types[i] == MySQL.MYSQL_TYPES.MYSQL_TYPE_STRING)
            my_buff_string = zeros(Array(Uint8, field_length))
            buffer_length = field_length
            my_buff = my_buff_string
        else
            my_buff_string = zeros(Array(Uint8, field_length))
            buffer_length = field_length
            my_buff = my_buff_string
        end
        
        bind = MySQL.MYSQL_BIND(buffer_type, pointer(tmp_long), pointer(tmp_char),
                reinterpret(Ptr{Void}, pointer(my_buff)), buffer_length)
        juBind = MySQL.JU_MYSQL_BIND(tmp_long, tmp_char, my_buff_long, my_buff_int,
                                        my_buff_double, my_buff_string, my_buff_datetime)
        push!(bindArray, bind)
        push!(juBindArray, juBind)
        mysql_field = null
    end
    
    df = DataFrame(jfield_types, field_headers, n_rows)
    response = MySQL.mysql_stmt_bind_result(stmtptr, reinterpret(Ptr{Cuchar},
                                            pointer(bindArray)))
    if (response != 0)
        println("the error after bind result is ::: $(bytestring(MySQL.mysql_stmt_error(stmtptr)))")
        return df
    end

    for row = 1:n_rows
        result = null
        result = MySQL.mysql_stmt_fetch_row(stmtptr)
        if (result != 0)
            println("Could not fetch row ::: $(bytestring(MySQL.mysql_stmt_error(stmtptr)))")
            return df
        else
            stmt_populate_row(n_fields, mysqlfield_types, df, row, juBindArray)
        end
    end
    return df
end
