# Test for multi statements.

include("test_common.jl")

function run_test()
    println("*** Running multi query test ***\n")
    connect_as_root()

    query = """CREATE DATABASE test_db;
    USE test_db;
    DROP TABLE IF EXISTS test_table;
    CREATE TABLE test_table(id INT);
    INSERT INTO test_table VALUES(10);
    UPDATE test_table SET id=20 WHERE id=10;
    SELECT * FROM test_table;
    DROP TABLE test_table;
    DROP DATABASE test_db"""

    # Run twice: Related to an earlier bug where 2nd run was failing.
    mysql_execute(hndl, query)
    data = mysql_execute(hndl, query)

    @show data

    mysql_disconnect(hndl)
end

run_test()
