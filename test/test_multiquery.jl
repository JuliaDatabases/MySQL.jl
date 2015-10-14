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
    DROP TABLE test_table
    DROP DATABASE test_db"""

    mysql_execute_multi_query(con, query)
    affrows, data = mysql_execute_multi_query(con, query)    # Run twice.

    @show affrows
    @show data

    mysql_disconnect(con)
end

run_test()
