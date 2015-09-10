MySQL.jl
======

Julia functions to convert database tables to [Data Frames](https://github.com/JuliaStats/DataFrames.jl)
and wrappers to MySQL C functions. (uses [DBI.jl](https://github.com/JuliaDB/DBI.jl))

# Types (Derived from DBI.jl)

* `MySQL5`: An abstract subtype of DBI.DatabaseSystem
* `MySQLDatabaseHandle`: A subtype of DBI.DatabaseHandle
* `MySQLStatementHandle`: A subtype of DBI.StatementHandle

# Functions

## Direct wrappers for C functions
* `connect`/`disconnect`: Set up and shut down connections to database
* `stmt_init`: Initialize SQL statement
* `prepare`: Ask the database to prepare, but not execute, a SQL statement
* `execute`: Execute an SQL statement
* `stmt_error`: Get the MySQL error statement
* `stmt_close`: Close the MySQL statement
## Other functions
* `prepare_and_execute`: Wrapper to call prepare and execute and show appropriate error messages
* `execute_query`: Obtain result of a query as a DataFrame
