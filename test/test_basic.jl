# A basic test  that uses `MySQL.mysql_query` to execute  the queries in
# test_common.jl

include("test_common.jl")

function run_query_helper(command, msg)
    response = MySQL.mysql_query(con.ptr, command)

    if (response == 0)
        println("SUCCESS: " * msg)
        return true
    else
        println("FAILED: " * msg)
        return false
    end
end

run_test()
