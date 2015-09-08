module MySQL
    using DBI

    include("consts.jl")
    include("types.jl")
    include("api.jl")
    include("dbi.jl")

    export MySQL5
    export MySQLDatabaseHandle
    export CLIENT_MULTI_STATEMENTS
    
    include("dfconvert.jl")
    
    function connect(hostName::String, userName::String, password::String, db::String)
        return Base.connect(MySQL5, hostName, userName, password, db, 0,
                            C_NULL, MySQL.CLIENT_MULTI_STATEMENTS)
    end
    
#    function disconnect(db::DBI.DatabaseHandle)
#        disconnect(db)
#    end
    
    ### Support for prepare statements
    
    function stmt_init(db::DBI.DatabaseHandle)
        return mysql_stmt_init(db.ptr)
    end
    
    function prepare(stmtptr::Ptr{Cuchar}, sql::String)
        return mysql_stmt_prepare(stmtptr, sql)
    end
    
    function prepare_and_execute(stmtptr::Ptr{Cuchar}, sql::String)
        response = mysql_stmt_prepare(stmtptr, sql)
    
        if (response == 0)
            results = mysql_stmt_result_metadata(stmtptr)
            response = execute(stmtptr)
    
            if (response == 0)
                println("Query executed successfully !!!")
                return obtainResultsAsDataFrame(results, true, stmtptr)
            else
                println("Query execution failed !!!")
                error = bytestring(stmt_error(stmtptr))
                println("The error is ::: $error")
            end
    
        else
            println("Error in preparing the query !!!")
            stmt_error(stmtptr)
        end
    
    end
    
    function execute(stmtptr::Ptr{Cuchar})
        return mysql_stmt_execute(stmtptr)
    end
    
    function stmt_error(stmtptr::Ptr{Cuchar})
        return mysql_stmt_error(stmtptr)
    end
    
    function stmt_close(stmtptr::Ptr{Cuchar})
        return mysql_stmt_close(stmtptr)
    end
    
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
