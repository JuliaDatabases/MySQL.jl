# A basic test  that uses `MySQL.mysql_query` to execute  the queries in
# test_common.jl

include("test_common.jl")

function run_query_helper(command, msg)
    response = MySQL.mysql_query(con, command)

    if (response == 0)
        println("SUCCESS: " * msg)
        return true
    else
        println("FAILED: " * msg)
        return false
    end
end

function show_as_dataframe()
    command = """SELECT * FROM Employee;"""
    dframe = MySQL.execute_query(con, command)
    println(dframe)
end

println("\n*** Running Basic Test ***\n")
run_test()
