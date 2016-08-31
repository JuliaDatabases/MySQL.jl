MySQL.jl
======

[![Build Status](https://travis-ci.org/JuliaDB/MySQL.jl.svg?branch=master)](https://travis-ci.org/JuliaDB/MySQL.jl)

Julia bindings and helper functions for [MariaDB](https://mariadb.org/)/MySQL C library.

# Installation

Install [MySQL](http://dev.mysql.com/doc/refman/5.7/en/installing.html).

Then in the julia prompt enter:
```julia
Pkg.add("MySQL")
```

# Examples

The following example connects to a database, creates a table, inserts values,
 retrieves the results and diconnects:

```julia
using MySQL
con = mysql_connect("192.168.23.24", "username", "password", "db_name")
command = """CREATE TABLE Employee
             (
                 ID INT NOT NULL AUTO_INCREMENT,
                 Name VARCHAR(255),
                 Salary FLOAT,
                 JoinDate DATE,
                 PRIMARY KEY (ID)
             );"""
mysql_execute(con, command)

# Insert some values
mysql_execute(con, "INSERT INTO Employee (Name, Salary, JoinDate) values ('John', 25000.00, '2015-12-12'), ('Sam', 35000.00, '2012-18-17), ('Tom', 50000.00, '2013-12-14');")

# Get SELECT results
command = "SELECT * FROM Employee;"
dframe = mysql_execute(con, command)

# Close connection
mysql_disconnect(con)
```

## Getting the result set

By default, `mysql_execute` returns a DataFrame.  To obtain each row as a tuple use `mysql_execute(con, command; opformat=MYSQL_TUPLES)`.  The same can also be done with the `MySQLRowIterator`, example:

```julia
for row in MySQLRowIterator(con, command)
    # do stuff with row
end
```

# Extended example: Prepared Statements

Prepared statements are used to optimize queries.  Queries that are run repeatedly can be
 prepared once and then executed many times.  The query can take parameters, these are
 indicated by '?'s. Using the `mysql_stmt_bind_param` the values can be bound to the query.
 An Example:

```julia
mysql_stmt_prepare(conn, "INSERT INTO Employee (Name, Salary, JoinDate) values (?, ?, ?);")

values = [("John", 10000.50, "2015-8-3"),
          ("Tom", 20000.25, "2015-8-4"),
          ("Jim", 30000.00, "2015-6-2")]

for val in values
    mysql_execute(conn, [MYSQL_TYPE_VARCHAR, MYSQL_TYPE_FLOAT, MYSQL_TYPE_DATE], val)
end

mysql_stmt_prepare(conn, "SELECT * from Employee WHERE ID = ? AND Salary > ?")
dframe = mysql_execute(conn, [MYSQL_TYPE_LONG, MYSQL_TYPE_FLOAT], [5, 35000.00])

# To iterate over the result and get each row as a tuple
for row in MySQLRowIterator(conn, [MYSQL_TYPE_LONG, MYSQL_TYPE_FLOAT], [5, 35000.00])
    # do stuff with row
end
```

# Metadata

```julia
mysql_query(con, "SELECT * FROM some_table;")
result = mysql_store_result(con)          # result set can be used later to retrieve values.
meta = mysql_metadata(result)
for i in 1:meta.nfields
    println("Field name is: ", meta.names[i])
    println("Field length is: ", meta.lens[i])
    println("MySQL type is: ", meta.mtypes[i])
    println("Julia type is: ", meta.jtypes[i])
    println("Is nullable: ", meta.is_nullables[i])
end
```

The same function `mysql_metadata` can be called for prepared statements with the statement
 handle as the argument after preparing the query.

# Multi-Query

`mysql_execute` handles multi-query.  It returns an array of DataFrames and integers.
 The DataFrames correspond to the SELECT queries and the integers respresent the number of
 affected rows corresponding to non-SELECT queries in the multi statement.

If `MYSQL_TUPLES` are passed as the last argument, then tuples will be returned instead
 of DataFrames.

# Error types

* `MySQLInterfaceError`: This error is thrown for exceptions that occur in the MySQL julia interface, such as when calling functions with a null connection.
* `MySQLInternalError`: This error is thrown for exceptions that occur in the underlying C library.
* `MySQLStatementError`: This error is thrown for exceptions that occur in the underlying C library when using prepared statements.

# How to solve MySQL library not found error

This error may occur during `using MySQL`. To resolve this-
* Ubuntu: Just add the MariaDB/MySQL .so file to lib_choices array in src/config.jl. If it is already there
make sure LD_LIBRARY_PATH contains the MariaDB/MySQL .so file directory path. Usually this is something like
`/usr/local/lib/mariadb/`.
* OSX: Same as above. In this case the file will be something like libmysqlclient.dylib.
* Windows: The file will be picked up automatically if MySQL is installed correctly.  If you still get the error add the location of libmysql.dll to PATH.

# Tests

To run the tests you must have MySQL server running on the host. Set the constants HOST and ROOTPASS 
in test/runtests.jl to the host and root password on your test setup. Run the tests using:
```
Pkg.test("MySQL")
```

# Acknowledgement

We acknowledge the contributions of [JustDial](http://www.justdial.com) towards this work.
