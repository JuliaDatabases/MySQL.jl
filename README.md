MySQL.jl
======

[![Build Status](https://travis-ci.org/JuliaDB/MySQL.jl.svg?branch=master)](https://travis-ci.org/JuliaDB/MySQL.jl)

Julia bindings and helper functions for [MariaDB](https://mariadb.org/)/MySQL C library.
Query results can be received as julia arrays or as [Data Frames](https://github.com/JuliaStats/DataFrames.jl).

# Installation

To get the master version:
```julia
Pkg.clone("https://github.com/JuliaComputing/MySQL.jl")
```

# Example usage

## Using DBAPI

[DBAPI.jl](https://github.com/JuliaDB/DBAPI.jl) is an abstract interface designed to be a common interface for all julia database drivers.  Example:

```julia
conn = connect(MySQLInterface, "127.0.0.1", "root", "rootbeer", "mydb")
csr = cursor(conn)
execute!(csr, "CREATE TABLE mydb.mytable (id int not null auto_increment, name varchar(50) not null, age int, birthday date, primary key (id));")
execute!(csr, "SELECT * from mydb.mytable;")

# SELECT queries produce result, to retrieve results:
r = rows(csr)    # Returns an iterator
for row in r
    # do stuff with row
end
close(csr)
close(conn)
```

## Internal API's

Using internal API's gives you more control over low level features.

Connect to the MySQL server:
```julia
using MySQL
con = mysql_connect(HOST, USER, PASSWD, DBNAME)
```

Create/Insert/Update etc:
```julia
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
response = mysql_query(con, command)
if (response == 0)
    println("Create table succeeded.")
else
    println("Create table failed.")
end
```

Obtain SELECT results as dataframe:

```julia
command = """SELECT * FROM Employee;"""
dframe = execute_query(con, command)
```
The `mysql_execute_query()` API will take care of handling errors and freeing the memory allocated to the results.

Obtain SELECT results as julia Array:

```julia
command = """SELECT * FROM Employee;"""
retarr = mysql_execute_query(con, command, opformat=MYSQL_ARRAY)
```

Obtain SELECT results as julia Array with each row as a tuple:

```julia
command = """SELECT * FROM Employee;"""
retarr = mysql_execute_query(con, command, opformat=MYSQL_TUPLES)
```

Iterate over rows (get each row as a tuple):

```julia
response = mysql_query(con, "SELECT * FROM some_table;")
mysql_display_error(con, response != 0,
                    "Error occured while executing mysql_query on \"$command\"")

result = mysql_store_result(con)

for row in MySQLRowIterator(result)
    println(row)
end

mysql_free_result(result)
```

Get metadata of fields:

```julia
response = mysql_query(con, "SELECT * FROM some_table;")
mysql_display_error(con, response != 0,
                    "Error occured while executing mysql_query on \"$command\"")

result = mysql_store_result(con)
mysqlfields = mysql_get_field_metadata(result)
for i = 1:length(mysqlfields)
    field = mysqlfields[i]
    println("Field name is: ", bytestring(field.name))
    println("Field length is: ", field_length)
    println("Field type is: ", field_type)
end
```

Execute a multi query:

```julia
command = """INSERT INTO Employee (Name) VALUES ('');
             UPDATE Employee SET LunchTime = '15:00:00' WHERE LENGTH(Name) > 5;"""
data = mysql_execute_query(con, command)
```

`data` contains an array of dataframes (or arrays if MYSQL_ARRAY was specified as the
 3rd argument to the above API) corresponding to the SELECT queries and number of
 affected rows corresponding to the non-SELECT queries in the multi statement.

Get dataframes using prepared statements:

```julia
command = """SELECT * FROM Employee;"""

stmt = mysql_stmt_init(con)

if (stmt == C_NULL)
    error("Error in initialization of statement.")
end

response = mysql_stmt_prepare(stmt, command)
mysql_display_error(con, response != 0,
                    "Error occured while preparing statement for query \"$command\"")

dframe = mysql_stmt_result_to_dataframe(stmt)
mysql_stmt_close(stmt)
```

Close the connection:

```julia
mysql_disconnect(con)
```

# How to solve MySQL library not found error

This error may occur during `using MySQL`. To resolve this-
* Ubuntu: Just add the MariaDB/MySQL .so file to lib_choices array in src/config.jl. If it is already there
make sure LD_LIBRARY_PATH contains the MariaDB/MySQL .so file directory path. Usually this is something like
`/usr/local/lib/mariadb/`.
* OSX: Same as above. In this case the file will be something like libmysqlclient.dylib.
* Windows: There is no `@windows_only lib_choices` currently. Please add one and send a pull request.

# Tests

To run the tests you must have MySQL server running on the host. Set the constants HOST and ROOTPASS 
in test/runtests.jl to the host and root password on your test setup. Run the tests using:
```julia
Pkg.test("MySQL")
```

# Acknowledgement

We acknowledge the contributions of [JustDial](http://www.justdial.com) towards this work.
