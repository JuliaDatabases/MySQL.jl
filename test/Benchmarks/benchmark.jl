# A performance test, since we are using Faker this only works on v0.4

using MySQL
using DataFrames

include("create_datasets.jl")

const NUMDATASETS = 10000
const HOST = "127.0.0.1"
const USER = "root"
const ROOTPASS = ""
const DBNAME = ""

function mysql_benchmarks(queries; use_prepare=0, use_multiquery = 0, operation=" ")
    println("\n*** Operation $operation Time:\n")
    if use_prepare == 1
        println("*** Prepare statement test ")
        stmt = mysql_stmt_init(conn)
        @time for i = 1:size(queries, 1)
            mysql_stmt_prepare(stmt, queries[i])
            mysql_stmt_execute(stmt)
        end
        mysql_stmt_close(stmt)
    elseif use_multiquery == 1
        println("*** Multi query test ")
        temp = join(queries)
        @time mysql_execute_multi_query(conn, temp)
    else
        println("*** Normal test ")
        @time for i = 1:size(queries, 1)
            mysql_execute_query(conn, queries[i])
        end
    end
end

function init_test()
    println("*** Initializing test")
    global conn = mysql_connect(HOST, USER, ROOTPASS, DBNAME)
    if conn == C_NULL
        error("mysql_connect failed")
    end

    # Cleanup leftovers from previous test and create table.
    query = """DROP DATABASE IF EXISTS mysqltest;
    CREATE DATABASE mysqltest;
    USE mysqltest;
    CREATE TABLE Employee(
        ID INT NOT NULL AUTO_INCREMENT,
        Name VARCHAR(4000),
        Salary FLOAT,
        LastLogin DATETIME,
        OfficeNo TINYINT,
        JobType ENUM('HR', 'Management', 'Accounts'),
        h MEDIUMINT,
        n INTEGER,
        z BIGINT,
        z1 DOUBLE,
        z2 DOUBLE PRECISION,
        cha CHAR,
        empno SMALLINT,
        PRIMARY KEY (ID));"""

    mysql_execute_multi_query(conn, query)
    println("*** Done initializing test.")
end

function cleanup_test()
    println("*** Cleaning up")
    response = mysql_query(conn, "DROP DATABASE mysqltest;")
    mysql_display_error(conn, response, "Cleanup failed.")
    mysql_disconnect(conn)
    println("*** Done cleanup")
end

function retrieve_test()
    @time mysql_execute_query(conn, "select ID, Name, Salary, OfficeNo, JobType, h, n, z, z1, z2, cha, empno from Employee")
end

function run_test(num_datasets)
    init_test()

    println("Benchmark without using Prepare functionality")
    mysql_benchmarks(insert_queries(num_datasets),
                     use_prepare=0, use_multiquery=0, operation="Insert")
    mysql_benchmarks(update_queries(num_datasets),
                     use_prepare=0, use_multiquery=0, operation="Update")
    retrieve_test()

    println("Benchmark using Prepare functionality")
    mysql_benchmarks(insert_queries(num_datasets),
                     use_prepare=1, use_multiquery=0, operation="Insert")
    mysql_benchmarks(update_queries(num_datasets),
                     use_prepare=1, use_multiquery=0, operation="Update")
    retrieve_test()

    println("Benchmark using Multiquery functionality")
    mysql_benchmarks(insert_queries(num_datasets),
                     use_prepare=0, use_multiquery=1, operation="Insert")
    mysql_benchmarks(update_queries(num_datasets),
                     use_prepare=0, use_multiquery=1, operation="Update")
    retrieve_test()

    cleanup_test()
end

function create_large_table(num_datasets)
    init_test()

    mysql_benchmarks(insert_queries(num_datasets),
                     use_prepare=0, use_multiquery=0, operation="Insert")
end
