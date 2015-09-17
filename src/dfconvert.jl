# Convert C pointers returned from MySQL C calls to Julia DataFrames

using DataFrames
using Dates

const MYSQL_DEFAULT_DATE_FORMAT = "yyyy-mm-dd"
const MYSQL_DEFAULT_DATETIME_FORMAT = "yyyy-mm-dd HH:MM:SS"

## Can use MYSQL_TYPE_MAP and reduce this to just 1 line of code
## but if conditions retained in case we need to insert code for
## specific cases.
function getType(dataType)
    if (dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONGLONG ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_INT24)
        return Int64
    elseif (dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TINY ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_ENUM  ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_BIT)
        return Int8
    elseif (dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_SHORT ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONG)
        return Int32
    elseif (dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DECIMAL ||
           dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDECIMAL)
        return Float64
    elseif (dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_FLOAT ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DOUBLE)
        return Float64
    elseif (dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NULL ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TIMESTAMP ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TIME ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_SET ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TINY_BLOB ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_MEDIUM_BLOB ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONG_BLOB ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_BLOB ||
        dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_GEOMETRY)
        return String
    elseif (dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_YEAR)
        return Int64
    elseif (dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DATE)
        return Date
    elseif (dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DATETIME ||
           dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDATE)
        return DateTime
    elseif (dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_VARCHAR ||
           dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_VAR_STRING ||
           dataType == MySQL.MYSQL_CONSTS.MYSQL_TYPE_STRING)
        return String
    else
        return String
    end
end

"""
Fill the row indexed by `row` of the dataframe `df` with values from `result`.
"""
function populateRow(numFields::Int8, fieldTypes::Array{Uint32}, result::MySQL.MYSQL_ROW, df, row)
    for i = 1:numFields
        value = ""
        obj = unsafe_load(result.values, i)
        if (obj != C_NULL)
            value = bytestring(unsafe_load(result.values, i))
        end

        if fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONG
            if (!isempty(value))
                df[row, i] = int32(value)
            else
                df[row, i] = NA
            end
        elseif fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONGLONG
            if (!isempty(value))
                df[row, i] = int(value)
            else
                df[row, i] = NA
            end
        elseif fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TINY
            if (!isempty(value))
                df[row, i] = int8(value)
            else
                df[row, i] = NA
            end
        elseif fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_FLOAT
            if (!isempty(value))
                df[row, i] = float64(value)
            else
                df[row, i] = NaN
            end
        elseif fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DOUBLE
            if (!isempty(value))
                df[row, i] = float64(value)
            else
                df[row, i] = NaN
            end
        elseif fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DECIMAL
            if (!isempty(value))
                df[row, i] = float64(value)
            else
                df[row, i] = NaN
            end
        elseif fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDECIMAL
            if (!isempty(value))
                df[row, i] = float64(value)
            else
                df[row, i] = NaN
            end
        elseif fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDATE
            if (!isempty(value))
                df[row, i] = value
            else
                df[row, i] = NA
            end
        elseif fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DATE
            if (!isempty(value))
                df[row, i] = Date(value, MYSQL_DEFAULT_DATE_FORMAT)
            else
                df[row, i] = NA
            end
        elseif fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DATETIME
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

function populateRow(numFields::Int8, fieldTypes::Array{Uint32}, df, row, juBindArray)
    for i = 1:numFields
        value = ""
        if (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_SHORT ||
            fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONG)
            value = int32(juBindArray[i].buffer_int[1])
        elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONGLONG ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_INT24)
            value = int(juBindArray[i].buffer_long[1])
        elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TINY ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_ENUM ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_BIT)
            value = int8(juBindArray[i].buffer_int[1])
        elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DECIMAL ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDECIMAL)
            ### Not supported fully !!! this may work in some cases
            data  = juBindArray[i].buffer_string
            value = 0.0
            if (!isempty(data))
                idx  = findfirst(data, '\0')
                tmp_val = bytestring(data[1:(idx == 0 ? endof(data) : idx-1)])
                if (!isempty(tmp_val))
                    value = float(tmp_val)
                end
            end
        elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_FLOAT ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DOUBLE)
            value = 0.0
            if (juBindArray[i].buffer_double[1] != C_NULL)
                value = float(juBindArray[i].buffer_double[1])
            end    
        elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDATE ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DATETIME)
            mysql_time = juBindArray[i].buffer_datetime[1]
            if (mysql_time.year != 0)   ## to handle invalid data like 0000-00-00T00:00:00
                value = DateTime(mysql_time.year, mysql_time.month, mysql_time.day,
                                 mysql_time.hour, mysql_time.minute, mysql_time.second)
            else
                value = DateTime()
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

"""
Returns a dataframe containing the data in `results`.
"""
function obtainResultsAsDataFrame(results::MYSQL_RES)
    numFields = MySQL.mysql_num_fields(results)
    fields = MySQL.mysql_fetch_fields(results)
    numRows = MySQL.mysql_num_rows(results)
    columnTypes = Array(Any, numFields)
    columnHeaders = Array(Symbol, numFields)
    fieldTypes = Array(Cuint, numFields)
    for i = 1:numFields
        fieldsObj = unsafe_load(fields, i)
        columnTypes[i] = Array(getType(fieldsObj.field_type), numRows)
        columnHeaders[i] = symbol(bytestring(fieldsObj.name))
        fieldTypes[i] = fieldsObj.field_type
        fieldsObj = null
    end

    df = DataFrame(columnTypes, columnHeaders)
    for row = 1:numRows
        result = MySQL.mysql_fetch_row(results)
        populateRow(numFields, fieldTypes, result, df, row)
        result = null
    end
    return df
end

function prepstmt_obtainResultsAsDataFrame(results::Ptr{Cuchar}, preparedStmt::Bool=false,
                                  stmtptr::Ptr{Cuchar}=C_NULL)
    numFields = MySQL.mysql_num_fields(results)
    fields = MySQL.mysql_fetch_fields(results)
    
    if (preparedStmt)
        ## store result is required to get the num_rows, etc ...
        MySQL.mysql_stmt_store_result(stmtptr)
        numRows = MySQL.mysql_stmt_num_rows(stmtptr)
    else
        numRows = MySQL.mysql_num_rows(results)
    end
    
    columnTypes = Array(Any, numFields)
    columnHeaders = Array(Symbol, numFields)
    fieldTypes = Array(Uint32, numFields)
    bindArray = null
    juBindArray = null
    
    if (preparedStmt == true)
        bindArray = MySQL.MYSQL_BIND[]
        juBindArray = MySQL.JU_MYSQL_BIND[]
    end
    
    for i = 1:numFields
        fieldsObj = unsafe_load(fields, i)
        columnTypes[i] = Array(getType(fieldsObj.field_type), numRows)
        columnHeaders[i] = symbol(bytestring(fieldsObj.name))
        fieldTypes[i] = fieldsObj.field_type
        field_length = fieldsObj.field_length
    
        if (preparedStmt)
            tmp_long = Array(Culong)
            tmp_char = Array(Cchar)
            buffer_length::Culong = 0
            buffer_type::Cint = fieldTypes[i]
            my_buff_long = Array(Culong)
            my_buff_int = Array(Cint)
            my_buff_double = Array(Cdouble)
            my_buff_string = Array(Uint8, field_length)
            my_buff_datetime = Array(MySQL.MYSQL_TIME)
            my_buff
    
            if (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONGLONG ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_INT24)
                my_buff_long = Array(Culong)
                buffer_length = sizeof(Culong)
                my_buff = my_buff_long
            elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TINY ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_SHORT ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_ENUM ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONG ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_BIT)
                my_buff_int = Array(Cint)
                buffer_length = sizeof(Cint)
                my_buff = my_buff_int
            elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DECIMAL ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDECIMAL)
                ### TODO ::: This needs to be handled more efficiently !!
                ### there is no direct equivalent for this in Julia
                my_buff_string = zeros(Array(Uint8, field_length))
                buffer_length = field_length
                my_buff = my_buff_string
            elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_FLOAT ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DOUBLE)
                my_buff_double = Array(Cdouble)
                buffer_length = sizeof(Cdouble)
                my_buff = my_buff_double
            elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NULL ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TIMESTAMP ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DATE ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TIME ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_SET ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TINY_BLOB ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_MEDIUM_BLOB ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONG_BLOB ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_BLOB ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_GEOMETRY)
                println("WARNING:::Please handle me !!!!!")
                ### TODO ::: This needs to be handled differently !!!!
                my_buff_string = zeros(Array(Uint8, field_length))
                buffer_length = field_length
                my_buff = my_buff_string
            elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_YEAR)
                my_buff_long = Array(Culong)
                buffer_length = sizeof(Culong)
                my_buff = my_buff_long
            elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DATETIME ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDATE)
                my_buff_datetime = Array(MySQL.MYSQL_TIME)
                buffer_length = sizeof(MySQL.MYSQL_TIME)
                my_buff = my_buff_datetime
            elseif (fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_VARCHAR ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_VAR_STRING ||
                fieldTypes[i] == MySQL.MYSQL_CONSTS.MYSQL_TYPE_STRING)
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
        end
        fieldsObj = null
    end
    
    df = DataFrame(columnTypes, columnHeaders)
    if (preparedStmt == true)
        response = MySQL.mysql_stmt_bind_result(stmtptr, reinterpret(Ptr{Cuchar},
                                                pointer(bindArray)))
        if (response != 0)
            println("the error after bind result is ::: $(bytestring(MySQL.mysql_stmt_error(stmtptr)))")
            return df
        end
    end

    for row = 1:numRows
        result = null
        if (preparedStmt == true)
            result = MySQL.mysql_stmt_fetch_row(stmtptr)
            if (result != 0)
                println("Could not fetch row ::: $(bytestring(MySQL.mysql_stmt_error(stmtptr)))")
                return df
            else
                populateRow(numFields, fieldTypes, df, row, juBindArray)
            end
        else
            result = MySQL.mysql_fetch_row(results)
            if (result != 0)
                populateRow(numFields, fieldTypes, result, df, row)
            else
                println("result is ::: $result  ::: error is ::: $(bytestring(MySQL.mysql_stmt_error(stmtptr)))")
            end
        end
    end
    return df
end
