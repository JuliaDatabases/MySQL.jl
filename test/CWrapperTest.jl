using MySQL

const DB_JDS = "d_jds_mumbai"
db = connect(MySQL5, "127.0.0.1", "julia_all", "julia", DB_JDS)

sql = "CREATE TABLE users (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(255))"

response = MySQL.mysql_query(db.ptr, sql)
println("The response after create is $response")

sql = "select * from c2s_nonpaid limit 10"

response = MySQL.mysql_query(db.ptr, sql)
println("The response after select query is $response")

if (response == 0)
    println("Success !!!")
    results = MySQL.mysql_store_result(db.ptr)

    if (results == C_NULL)
        affectedRows = MySQL.mysql_affected_rows(db.ptr)
        println("affected rows : ", affectedRows)
        return affectedRows
    end

    numFields = MySQL.mysql_num_fields(results)

    ### Returns C type MYSQL_FIELD
    fields = MySQL.mysql_fetch_fields(results)

    ## Create the return obj from the results
    ## 
    numRows = MySQL.mysql_num_rows(results)
    println("The # of rows is :: $numRows")

    for row = 1:numRows
        result = MySQL.mysql_fetch_row(results)

        for i = 1:numFields
            fieldsObj = unsafe_load(fields, i)
            value = null
            obj = unsafe_load(result.values, i)

            if (obj != C_NULL)
                value = bytestring(unsafe_load(result.values, i))
            end

            print("The value is ::")

	    if value == null
                println(NaN)
            elseif fieldsObj.field_type == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONG
                println("Long ", parse(Int, value))
            elseif fieldsObj.field_type == MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONGLONG 
                println("Long Long ", parse(Int, value))
            elseif fieldsObj.field_type == MySQL.MYSQL_CONSTS.MYSQL_TYPE_TINY
                println("Tiny ", parse(Int8, value))
            elseif fieldsObj.field_type == MySQL.MYSQL_CONSTS.MYSQL_TYPE_FLOAT 
                println("Float ", parse(Float64, value))
            elseif fieldsObj.field_type == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DOUBLE 
                println("Double ", parse(Float64, value))
            elseif fieldsObj.field_type == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DECIMAL
                println("Decimal ", parse(Float64, value))
            elseif fieldsObj.field_type == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDECIMAL
                println("New decimal ", parse(Float64, value))
            elseif fieldsObj.field_type == MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDATE
                println("New date ", value)
            elseif fieldsObj.field_type == MySQL.MYSQL_CONSTS.MYSQL_TYPE_DATETIME
                println("Date time ", value)
            else
                println("Something else ", value)
            end
        end
    end
    MySQL.mysql_free_result(results)
else
    println("Failed !!!")
end

