module MySQL
    using DBI

    include("config.jl")
    include("types.jl")
    include("api.jl")
    include("dbi.jl")

    export MySQL5
    export MySQLDatabaseHandle
    export CLIENT_MULTI_STATEMENTS
    
    include("dfconvert.jl")
        
    ## executesthe query and returns the result set in case of select
    ## and the # of affected rows in case of insert / update / delete .
    ## returns -1 in case of errors
    function execute_query(db::DBI.DatabaseHandle, sql::String, outputFormat::Int64=0)
        response = mysql_query(db.ptr, sql)
    
        if (!bool(response))
            results = mysql_store_result(db.ptr)
    
            if (results == C_NULL)
                affectedRows = MySQL.mysql_affected_rows(db.ptr)
                println("affected rows : ", affectedRows)
                ## in case of update / delete / insert,
                ## between real error case and insert / updates
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
