using MySQL

const HOST = "127.0.0.1"
const USER = "root"
const PASSWD = "root"
const DBNAME = "mysqltest"
const PREPARE = false

function run_query_helper(command, successmsg, failmsg)
    response = MySQL.mysql_query(con.ptr, command)

    if (!bool(response))
        println(successmsg)
    else
        println(failmsg)
    end
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
    run_query_helper(command, "Create table succeeded", "Create table failed")
end

function drop_table()
    command = """DROP TABLE Employee;"""
    run_query_helper(command, "Drop table succeeded", "Drop table failed")
end

function insert_values()
    command = """INSERT INTO Employee (Name, Salary, JoinDate, LastLogin, LunchTime)
                 VALUES
                 ('John', 10000.50, '2015-8-3', '2015-9-5 12:31:30', '12:00:00'),
                 ('Tom', 20000.25, '2015-8-4', '2015-10-12 13:12:14', '13:00:00'),
                 ('Jim', 30000.00, '2015-6-2', '2015-9-5 10:05:10', '12:30:00'),
                 ('Tim', 15000.50, '2015-7-25', '2015-10-10 12:12:25', '12:30:00');
              """
    run_query_helper(command, "Insert succeeded", "Insert failed")
end

function update_values()
    command = """UPDATE Employee SET Salary = 25000.00 WHERE ID > 2;"""
    run_query_helper(command, "Update success", "Update failed")
end 

function show_as_dataframe()
    command = """SELECT * FROM Employee;"""

    if (PREPARE)
        stmt_ptr = MySQL.stmt_init(con)
        dframe = MySQL.prepare_and_execute(stmt_ptr, command)
        MySQL.stmt_close(stmt_ptr)
    else
        dframe = MySQL.execute_query(con, command)
    end

    println(dframe)
end

function run_test()
    global con = MySQL.connect(HOST, USER, PASSWD, DBNAME)
    create_table()
    insert_values()
    show_as_dataframe()
    update_values()
    show_as_dataframe()
    drop_table()
    MySQL.disconnect(con)
end

run_test()
