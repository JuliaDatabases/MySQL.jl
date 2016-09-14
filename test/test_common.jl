# A test  that performs  some basic SQL  queries. It creates  a database
# called  `mysqltest` a  user called  `test`  and a  table in  mysqltest
# called  `Employee`.  It then  inserts some  data, performs  an update,
# then retrieves the data using  a select query and converts the results
# to a julia datastructure.

using DataFrames
using Compat

function run_query_helper(command, msg)
    error("API not implemented: `run_query_helper`")
end

function connect_as_root()
    global hndl = mysql_connect(HOST, USER, PASS, "")
end

function create_test_database()
    command = """CREATE DATABASE mysqltest;"""
    run_query_helper(command, "Create database")
end

function create_test_user()
    command = "CREATE USER test@$HOST IDENTIFIED BY 'test';"
    run_query_helper(command, "Create user")
end

function grant_test_user_privilege()
    command = "GRANT ALL ON mysqltest.* TO test@$HOST;"
    run_query_helper(command, "Grant privilege")
end

function connect_as_test_user()
    global hndl = mysql_connect(HOST, "test", "test", "mysqltest";
                                opts=@compat Dict(MYSQL_OPT_RECONNECT => 1))
end

function create_table()
    command = """CREATE TABLE Employee
                 (
                     ID INT NOT NULL AUTO_INCREMENT,
                     Name VARCHAR(255),
                     Salary FLOAT(7,2),
                     JoinDate DATE,
                     LastLogin DATETIME,
                     LunchTime TIME,
                     OfficeNo TINYINT,
                     JobType ENUM('HR', 'Management', 'Accounts'),
                     Senior BIT(1),
                     empno SMALLINT,
                     PRIMARY KEY (ID)
                 );"""
    run_query_helper(command, "Create table")
end

function insert_values()
    command = """INSERT INTO Employee (Name, Salary, JoinDate, LastLogin, LunchTime, OfficeNo, JobType, Senior, empno)
                 VALUES
                 ('John', 10000.50, '2015-8-3', '2015-9-5 12:31:30', '12:00:00', 1, 'HR', b'1', 1301),
                 ('Tom', 20000.25, '2015-8-4', '2015-10-12 13:12:14', '13:00:00', 12, 'HR', b'1', 1422),
                 ('Jim', 30000.00, '2015-6-2', '2015-9-5 10:05:10', '12:30:00', 45, 'Management', b'0', 1567),
                 ('Tim', 15000.50, '2015-7-25', '2015-10-10 12:12:25', '12:30:00', 56, 'Accounts', b'1', 3200);
              """
    run_query_helper(command, "Insert")
end

function last_insert_id_test()
    id = mysql_insert_id(hndl)
    println("Last insert id was $id")
end

function update_values()
    command = """UPDATE Employee SET Salary = 25000.00 WHERE ID > 2;"""
    run_query_helper(command, "Update")
end

function drop_table()
    command = """DROP TABLE Employee;"""
    run_query_helper(command, "Drop table")
end

function insert_nullrow()
    command = """INSERT INTO Employee () VALUES ();"""
    run_query_helper(command, "Insert Null row")
end

function show_results()
    error("API not implemented: `run_query_helper`")
end

function drop_test_user()
    command = """DROP USER test@$HOST;"""
    run_query_helper(command, "Drop user")
end

function drop_test_database()
    command = """DROP DATABASE mysqltest;"""
    run_query_helper(command, "Drop database")
end

function init_test()
    mysql_execute(hndl, "DROP DATABASE IF EXISTS mysqltest;")
    # There seems to be a bug in MySQL that prevents you
    # from saying "DROP USER IF EXISTS test@127.0.0.1;"
    # So here we create a user with a harmless privilege and drop the user.
    mysql_execute(hndl, "GRANT USAGE ON *.* TO 'test'@'127.0.0.1';")
    mysql_execute(hndl, "DROP USER 'test'@'127.0.0.1';")
end

function run_test()
    # Connect as root and setup database, user and privilege
    # for the user.
    connect_as_root()
    init_test()
    @test create_test_database()
    @test create_test_user()
    @test grant_test_user_privilege()
    mysql_disconnect(hndl)

    # Connect as test user and do insert, update etc.
    # and finally drop the table.
    connect_as_test_user()
    @test create_table()
    @test insert_values()
    last_insert_id_test()
    @test update_values()
    @test insert_nullrow()

    show_results()
    @test drop_table()
    mysql_disconnect(hndl)

    # Drop the test user and database.
    connect_as_root()
    @test drop_test_user()
    @test drop_test_database()
    mysql_disconnect(hndl)
end

"""
A function to check if two dataframes are equal
"""
function dfisequal(dfa, dfb)
    if size(dfa) != size(dfb)
        return false
    end

    row, col = size(dfa)

    for i = 1:col
        for j = 1:row
            if isna(dfa[col][row]) && isna(dfb[col][row])
                continue
            elseif isna(dfa[col][row]) || isna(dfb[col][row])
                return false
            elseif dfa[col][row] != dfb[col][row]
                return false
            end
        end
    end

    return true
end

@compat function compare_values(u::Nullable, v::Nullable)
    if !isnull(u) && !isnull(v)
        return u.value == v.value
    elseif isnull(u) && isnull(v)
        return typeof(u) == typeof(v)
    else
        println("*** ALERT: Non null value being compared with null.")
        return false
    end
end

compare_values(u, v) = u == v

function compare_rows(rowu, rowv)
    length(rowu) == length(rowv) || return false
    for i = 1:length(rowu)
        compare_values(rowu[i], rowv[i]) || return false
    end
    return true
end
