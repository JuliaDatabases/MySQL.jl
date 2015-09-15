MySQL.jl
======

Julia bindings and helper functions for [MariaDB](https://mariadb.org/)/MySQL C library. 
Query results can be recieved as raw C pointers or as [Data Frames](https://github.com/JuliaStats/DataFrames.jl).

# Installation

To get the master version:
```
Pkg.clone("https://github.com/JuliaComputing/MySQL.jl")
Pkg.build("MySQL")
```

# Example usage

Connect to the MySQL server:
```
using MySQL
con = MySQL.connect(HOST, USER, PASSWD, DBNAME)
```

Create/Insert etc:
```
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
response = MySQL.mysql_query(con, command)
if (response == 0)
    println("Create table succeeded.")
else
    println("Create table failed.")
end
```

Obtain SELECT statement results as dataframe:
```
command = """SELECT * FROM Employee;"""
dframe = MySQL.getResultsAsDataFrame(con, command)
```

Obtain SELECT statement results as dataframe using prepared statement:
```
command = """SELECT * FROM Employee;"""
stmt_ptr = MySQL.stmt_init(con)
dframe = MySQL.prepstmt_getResultsAsDataFrame(stmt_ptr, command)
MySQL.stmt_close(stmt_ptr)
```

Close the connection:
```
MySQL.disconnect(con)
```

# How to solve MySQL library not found error

This error may occur during `using MySQL`. To resolve this-
* Ubuntu: Just add the MariaDB/MySQL .so file to lib_choices array in src/config.jl. If it is already there 
make sure LD_LIBRARY_PATH contains the MariaDB/MySQL .so file directory path. Usually this is something like 
`/usr/local/lib/mariadb/`.
* OSX: Same as above. In this case the file will be something like libmysqlclient.dylib.
* Windows: There is no `@windows_only lib_choices` currently. Please add one and send a pull request.

# Types (Derived from [DBI.jl](https://github.com/JuliaDB/DBI.jl))

* `MySQL5`: An abstract subtype of DBI.DatabaseSystem
* `MySQLDatabaseHandle`: A subtype of DBI.DatabaseHandle
* `MySQLStatementHandle`: A subtype of DBI.StatementHandle
