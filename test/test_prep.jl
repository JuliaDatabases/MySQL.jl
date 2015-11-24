# Same as test_basic.jl but uses prepare statements instead of `mysql_query`.

include("test_common.jl")

const DataFrameResultsPrep = DataFrame(
    ID=[1, 2, 3, 4, 5], 
    Name=@data(["John", "Tom", "Jim", "Tim", NA]),
    Salary=@data([10000.5, 20000.5, 25000.0, 25000.0, NA]),
    JoinDate=@data([convert(Date, "2015-8-3"), convert(Date, "2015-8-4"),
              convert(Date, "2015-6-2"), convert(Date, "2015-7-25"), NA]),
    LastLogin=@data([convert(DateTime, "2015-9-5 12:31:30"),
               convert(DateTime, "2015-10-12 13:12:14"),
               convert(DateTime, "2015-9-5 10:5:10"),
               convert(DateTime, "2015-10-10 12:12:25"), NA]),
    LunchTime=@data([MySQLTime("12:0:0"), MySQLTime("13:0:0"),
               MySQLTime("12:30:0"), MySQLTime("12:30:0"), NA]),
    OfficeNo=@data([1, 12, 45, 56, NA]),
    JobType=@data([NA, NA, NA, NA, NA]),
    Senior=@data([NA, NA, NA, NA, NA]),
    empno=@data([1301, 1422, 1567, 3200, NA]))


function run_query_helper(command, msg)
    stmt = mysql_stmt_init(hndl)
 
    if (stmt == C_NULL)
        error("Error in initialization of statement.")
    end

    response = mysql_stmt_prepare(stmt, command)
    mysql_display_error(hndl, response,
                        "Error occured while preparing statement for query \"$command\"")

    response = mysql_stmt_execute(stmt)
    mysql_display_error(hndl, response,
                        "Error occured while executing prepared statement for query \"$command\"")

    response = mysql_stmt_close(stmt)
    mysql_display_error(hndl, response,
                        "Error occured while closing prepared statement for query \"$command\"")

    println("Success: " * msg)
    return true
end

function update_values()
    command = """UPDATE Employee SET Salary = ? WHERE ID > ?;"""

    stmt = mysql_stmt_init(hndl)
    mysql_display_error(hndl, stmt == C_NULL)
    response = mysql_stmt_prepare(stmt, command)
    mysql_display_error(hndl, response)

    bindarr = MYSQL_BIND[]

    salaryparam = [convert(Float32, 25000.0)]
    idparam = [convert(Int32, 2)]

    push!(bindarr, MYSQL_BIND(salaryparam, MYSQL_TYPE_FLOAT))
    push!(bindarr, MYSQL_BIND(idparam, MYSQL_TYPE_LONG))

    response = mysql_stmt_bind_param(stmt, pointer(bindarr))
    mysql_display_error(hndl, response)

    response = mysql_stmt_execute(stmt)
    mysql_display_error(hndl, response)
    
    affrows = mysql_stmt_affected_rows(stmt)
    println("Affected rows after update_values(): $affrows")

    response = mysql_stmt_close(stmt)
    mysql_display_error(hndl, response)

    return true
end

function insert_values()
    command = """INSERT INTO Employee (Name, Salary, JoinDate, LastLogin, LunchTime, OfficeNo, empno) VALUES (?, ?, ?, ?, ?, ?, ?);"""

    stmt = mysql_stmt_init(hndl)
    mysql_display_error(hndl, stmt == C_NULL)
    response = mysql_stmt_prepare(stmt, command)
    mysql_display_error(hndl, response)

    values = [("John", [convert(Float32, 10000.50)], [convert(MYSQL_TIME, convert(Date, "2015-8-3"))],
               [convert(MYSQL_TIME, convert(DateTime, "2015-9-5 12:31:30"))],
               [convert(MYSQL_TIME, MySQLTime("12:00:00"))], [convert(Cchar, 1)],
               # [convert(Culong, 1)],
               [convert(Cshort, 1301)]),

              ("Tom", [convert(Float32, 20000.25)], [convert(MYSQL_TIME, convert(Date, "2015-8-4"))],
               [convert(MYSQL_TIME, convert(DateTime, "2015-10-12 13:12:14"))],
               [convert(MYSQL_TIME, MySQLTime("13:00:00"))], [convert(Cchar, 12)],
               # [convert(Culong, 1)],
               [convert(Cshort, 1422)]),

              ("Jim", [convert(Float32, 30000.00)], [convert(MYSQL_TIME, convert(Date, "2015-6-2"))],
               [convert(MYSQL_TIME, convert(DateTime, "2015-9-5 10:05:10"))],
               [convert(MYSQL_TIME, MySQLTime("12:30:00"))], [convert(Cchar, 45)],
               # [convert(Culong, 0)], 
               [convert(Cshort, 1567)]),

              ("Tim", [convert(Float32, 15000.50)], [convert(MYSQL_TIME, convert(Date, "2015-7-25"))],
               [convert(MYSQL_TIME, convert(DateTime, "2015-10-10 12:12:25"))],
               [convert(MYSQL_TIME, MySQLTime("12:30:00"))], [convert(Cchar, 56)],
               # [convert(Culong, 0)],
               [convert(Cshort, 3200)])]

    affrows = 0
    for value in values
        bindarr = MYSQL_BIND[]
        push!(bindarr, MYSQL_BIND(value[1], MYSQL_TYPE_VARCHAR))
        push!(bindarr, MYSQL_BIND(value[2], MYSQL_TYPE_FLOAT))
        push!(bindarr, MYSQL_BIND(value[3], MYSQL_TYPE_DATE))
        push!(bindarr, MYSQL_BIND(value[4], MYSQL_TYPE_DATETIME))
        push!(bindarr, MYSQL_BIND(value[5], MYSQL_TYPE_TIME))
        push!(bindarr, MYSQL_BIND(value[6], MYSQL_TYPE_TINY))
        push!(bindarr, MYSQL_BIND(value[7], MYSQL_TYPE_SHORT))

        response = mysql_stmt_bind_param(stmt, pointer(bindarr))
        mysql_display_error(hndl, response)
        
        response = mysql_stmt_execute(stmt)
        mysql_display_error(hndl, response)

        affrows += mysql_stmt_affected_rows(stmt)
    end

    println("Affected rows after insert_values(): $affrows")

    response = mysql_stmt_close(stmt)
    mysql_display_error(hndl, response)
    true
end


function show_results()
    command = """SELECT * FROM Employee;"""

    stmt = mysql_stmt_init(hndl)

    if (stmt == C_NULL)
        error("Error in initialization of statement.")
    end

    response = mysql_stmt_prepare(stmt, command)
    mysql_display_error(hndl, response,
                        "Error occured while preparing statement for query \"$command\"")

    dframe = mysql_stmt_result_to_dataframe(stmt)
    mysql_stmt_close(stmt)
    println("\n *** Results as dataframe: \n", dframe)
    println("\n *** Expected result: \n", DataFrameResultsPrep)
    @test dfisequal(dframe, DataFrameResultsPrep)
end

println("\n*** Running Prepared Statement Test ***\n")
run_test()
