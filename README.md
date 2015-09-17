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

Create/Insert/Update etc:
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
response = MySQL.mysql_query(con.ptr, command)
results = MySQL.mysql_store_result(con.ptr)
dframe = MySQL.obtainResultsAsDataFrame(results) # The dataframes.
MySQL.mysql_free_result(results)
# See test/test.jl to see how to check return values and handle errors.
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

# Performance

A total of 67,000 insert queries were executed batch wise in batch sizes of 50, 100, 150 ... so on.
 The time taken for all the queries to complete is plotted on the y axis and the batch sizes on x axis.

![alt tag](https://raw.githubusercontent.com/nkottary/nishanth.github.io/master/plot.png)

# Acknowledgement

We acknowledge the contributions of [JustDial](http://www.justdial.com) towards this work.
