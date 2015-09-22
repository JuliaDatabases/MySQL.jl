# Same as test_basic.jl but with prepare statements.

function run_query_helper(command, msg)
    stmt = MySQL.mysql_stmt_init(con.ptr)
    
    if (stmt == C_NULL)
        error("Error in initialization of statement.")
    end

    response = MySQL.mysql_stmt_prepare(stmt, command)
    if (response != 0)
        err_string = "Error occured while preparing statement for query \"$command\""
        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
        error(err_string)
    end

    response = MySQL.mysql_stmt_bind_result(stmt, result)

    response = MySQL.mysql_stmt_execute(stmt)
    if (response != 0)
        err_string = "Error occured while executing prepared statement for query \"$command\""
        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
        error(err_string)
    end

    response = MySQL.mysql_stmt_close(stmt)
    if (response != 0)
        err_string = "Error occured while closing prepared statement for query \"$command\""
        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
        error(err_string)
    end

    if (response == 0)
        println("SUCCESS: " * msg)
        return true
    else
        println("FAILED: " * msg)
        return false
    end
end

function connect_as_root()
    global con = MySQL.mysql_init_and_connect(HOST, "root", ROOTPASS, "")
end

function create_test_database()
    command = """CREATE DATABASE mysqltest;"""
    @test run_query_helper(command, "Create database")
end

function create_test_user()
    command = "CREATE USER test@$HOST IDENTIFIED BY 'test';"
    @test run_query_helper(command, "Create user")
end

function grant_test_user_privilege()
    command = "GRANT ALL ON mysqltest.* TO test@$HOST;"
    @test run_query_helper(command, "Grant privilege")
end

function connect_as_test_user()
    global con = MySQL.mysql_init_and_connect(HOST, "test", "test", "mysqltest")
end

function create_table()
    command = """CREATE TABLE Employee
                 (
                     ID INT NOT NULL AUTO_INCREMENT,
                     Name VARCHAR(255),
                     Salary FLOAT,
                     JoinDate DATE,
                     LastLogin DATETIME,
                     LunchTime TIME,
                     PRIMARY KEY (ID)
                 );"""
    @test run_query_helper(command, "Create table")
end

function insert_values()
    command = """INSERT INTO Employee (Name, Salary, JoinDate, LastLogin, LunchTime)
                 VALUES
                 ('John', 10000.50, '2015-8-3', '2015-9-5 12:31:30', '12:00:00'),
                 ('Tom', 20000.25, '2015-8-4', '2015-10-12 13:12:14', '13:00:00'),
                 ('Jim', 30000.00, '2015-6-2', '2015-9-5 10:05:10', '12:30:00'),
                 ('Tim', 15000.50, '2015-7-25', '2015-10-10 12:12:25', '12:30:00');
              """
    @test run_query_helper(command, "Insert")
end

function update_values()
    command = """UPDATE Employee SET Salary = 25000.00 WHERE ID > 2;"""
    @test run_query_helper(command, "Update")
end

function drop_table()
    command = """DROP TABLE Employee;"""
    @test run_query_helper(command, "Drop table")
end

function do_multi_statement()
    command = """INSERT INTO Employee (Name, Salary, JoinDate, LastLogin, LunchTime)
                 VALUES
                 ('Donald', 30000.00, '2014-2-2', '2015-8-8 13:14:15', '14:01:02');
                 UPDATE Employee SET LunchTime = '15:00:00' WHERE LENGTH(Name) > 5;"""
    @test run_query_helper(command, "Multi statement")
end

function show_as_dataframe()
    command = """SELECT * FROM Employee;"""
    dframe = MySQL.execute_query(con, command)
#    response = MySQL.mysql_query(con.ptr, command)
#
#    if (response != 0)
#        err_string = "Error occured while executing mysql_query on \"$command\""
#        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
#        error(err_string)
#    end
#
#    results = MySQL.mysql_store_result(con.ptr)
#    if (results == C_NULL)
#        err_string = "Error occured while executing mysql_store_result on \"$command\""
#        err_string = err_string * "\nMySQL ERROR: " * bytestring(MySQL.mysql_error(con.ptr))
#        error(err_string)
#    end
#
#    dframe = MySQL.obtainResultsAsDataFrame(results)
#    MySQL.mysql_free_result(results)
    println(dframe)
end

function drop_test_user()
    command = """DROP USER test@$HOST;"""
    @test run_query_helper(command, "Drop user")
end

function drop_test_database()
    command = """DROP DATABASE mysqltest;"""
    @test run_query_helper(command, "Drop database")
end

function run_test()

    # Connect as root and setup database, user and privilege
    # for the user.
    connect_as_root()
    create_test_database()
    create_test_user()
    grant_test_user_privilege()
    MySQL.mysql_disconnect(con)

    # Connect as test user and do insert, update etc.
    # and finally drop the table.
    connect_as_test_user()
    create_table()
    insert_values()
    update_values()
#   Subsequent queries fail after multi statement, need to debug.
#    do_multi_statement()
    show_as_dataframe()
    drop_table()
    MySQL.mysql_disconnect(con)

    # Drop the test user and database.
    connect_as_root()
    drop_test_user()
    drop_test_database()
    MySQL.mysql_disconnect(con)
end

run_test()
