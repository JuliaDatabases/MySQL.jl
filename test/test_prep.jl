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
    LunchTime=@data([convert(DateTime, "12:0:0"), convert(DateTime, "13:0:0"),
               convert(DateTime, "12:30:0"), convert(DateTime, "12:30:0"), NA]),
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

    salaryparam = mysql_bind_init(MYSQL_TYPE_FLOAT, 25000)
    idparam = mysql_bind_init(MYSQL_TYPE_LONG, 2)

    push!(bindarr, salaryparam)
    push!(bindarr, idparam)

    response = mysql_stmt_bind_param(stmt, bindarr)
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

    values = [("John", 10000.50, "2015-8-3", "2015-9-5 12:31:30", "12:00:00", 1, 1301),
              ("Tom", 20000.25, "2015-8-4", "2015-10-12 13:12:14", "13:00:00", 12, 1422),
              ("Jim", 30000.00, "2015-6-2", "2015-9-5 10:05:10", "12:30:00", 45, 1567),
              ("Tim", 15000.50, "2015-7-25", "2015-10-10 12:12:25", "12:30:00", 56, 3200)]

    typs = [MYSQL_TYPE_VARCHAR, MYSQL_TYPE_FLOAT, MYSQL_TYPE_DATE,
            MYSQL_TYPE_DATETIME, MYSQL_TYPE_TIME, MYSQL_TYPE_TINY,
            MYSQL_TYPE_SHORT]

    affrows = 0
    for value in values
        bindarr = MYSQL_BIND[]
        for i in 1:length(typs)
            push!(bindarr, mysql_bind_init(typs[i], value[i]))
        end

        response = mysql_stmt_bind_param(stmt, bindarr)
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
