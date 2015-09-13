module MySQL
    using DBI
    using Docile

    include("config.jl")
    include("types.jl")
    include("api.jl")
    include("dbi.jl")

    export MySQL5
    export MySQLDatabaseHandle
    export CLIENT_MULTI_STATEMENTS
    
    include("dfconvert.jl")
        
    """
Executes the query `sql` and returns the result set as a dataframe in case of select
and the number of affected rows in case of insert / update / delete. Returns -1 in case of errors.
    """
    function execute_query(db::DBI.DatabaseHandle, sql::String, outputFormat::Int64=0)
        response = mysql_query(db.ptr, sql)
    
        if (!bool(response))
            results = mysql_store_result(db.ptr)
    
            if (results == C_NULL) # `sql` was not select statement
                affectedRows = MySQL.mysql_affected_rows(db.ptr)
                println("affected rows : ", affectedRows)
                return affectedRows
            end
    
            numFields = mysql_num_fields(results)
    
            ### Returns C type MYSQL_FIELD
            fields = mysql_fetch_fields(results)
            returnObj = null
    
            if (outputFormat == 0) ## DataFrame
                returnObj = obtainResultsAsDataFrame(numFields, fields, results)
            else
                println("No format specified for return !!!")
            end
    
            mysql_free_result(results)
            return returnObj
        else
            println("response is :: $response")
            println("Query Execution Failed !!!!")
        end
    
        return -1
    end
end
