
# MySQL

*Package for interfacing with MySQL databases from Julia*

| **PackageEvaluator**                                            | **Build Status**                                                                                |
|:---------------------------------------------------------------:|:-----------------------------------------------------------------------------------------------:|
|[![][pkg-0.6-img]][pkg-0.6-url] | [![][travis-img]][travis-url] [![][codecov-img]][codecov-url] |


## Table of Contents

- [Installation](#installation)
- [Project Status](#project-status)
- [Contributing and Questions](#contributing-and-questions)
- [Documentation](#documentation)
  - [Functions](#functions)
  - [Types](#types)
  - [Example](#example)

## Installation

The package is registered in `METADATA.jl` and so can be installed with `Pkg.add`.

```julia
julia> Pkg.add("MySQL")
```

## Project Status

The package is tested against the current Julia `1.0` release and nightly on Linux and OS X.

## Contributing and Questions

Contributions are very welcome, as are feature requests and suggestions. Please open an
[issue][issues-url] if you encounter any problems or would just like to ask a question.


<!-- [docs-latest-img]: https://img.shields.io/badge/docs-latest-blue.svg
[docs-latest-url]: https://JuliaData.github.io/MySQL.jl/latest -->

[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://JuliaData.github.io/MySQL.jl/stable

[travis-img]: https://travis-ci.org/JuliaDatabases/MySQL.jl.svg?branch=master
[travis-url]: https://travis-ci.org/JuliaDatabases/MySQL.jl

[codecov-img]: https://codecov.io/gh/JuliaDatabases/MySQL.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaDatabases/MySQL.jl

[issues-url]: https://github.com/JuliaDatabases/MySQL.jl/issues

[pkg-0.6-img]: http://pkg.julialang.org/badges/MySQL_0.6.svg
[pkg-0.6-url]: http://pkg.julialang.org/?pkg=MySQL

## Documentation

### Functions

#### MySQL.connect

```julia
MySQL.connect(host::String, user::String, passwd::String; db::String="", port::Integer=3306, unix_socket::String=API.MYSQL_DEFAULT_SOCKET, client_flag=API.CLIENT_MULTI_STATEMENTS, opts = Dict())
```
Connect to a mysql database. Returns a [`MySQL.Connection`](#mysqlconnection) object to be passed to other API functions.

Options are passed via dictionary. The available keys are below and a description of the options can be found in the [MySQL documentation](https://dev.mysql.com/doc/refman/8.0/en/mysql-options.html).

```
MySQL.API.MYSQL_OPT_CONNECT_TIMEOUT
MySQL.API.MYSQL_OPT_COMPRESS
MySQL.API.MYSQL_OPT_NAMED_PIPE
MySQL.API.MYSQL_INIT_COMMAND
MySQL.API.MYSQL_READ_DEFAULT_FILE
MySQL.API.MYSQL_READ_DEFAULT_GROUP
MySQL.API.MYSQL_SET_CHARSET_DIR
MySQL.API.MYSQL_SET_CHARSET_NAME
MySQL.API.MYSQL_OPT_LOCAL_INFILE
MySQL.API.MYSQL_OPT_PROTOCOL
MySQL.API.MYSQL_SHARED_MEMORY_BASE_NAME
MySQL.API.MYSQL_OPT_READ_TIMEOUT
MySQL.API.MYSQL_OPT_WRITE_TIMEOUT
MySQL.API.MYSQL_OPT_USE_RESULT
MySQL.API.MYSQL_OPT_USE_REMOTE_CONNECTION
MySQL.API.MYSQL_OPT_USE_EMBEDDED_CONNECTION
MySQL.API.MYSQL_OPT_GUESS_CONNECTION
MySQL.API.MYSQL_SET_CLIENT_IP
MySQL.API.MYSQL_SECURE_AUTH
MySQL.API.MYSQL_REPORT_DATA_TRUNCATION
MySQL.API.MYSQL_OPT_RECONNECT
MySQL.API.MYSQL_OPT_SSL_VERIFY_SERVER_CERT
MySQL.API.MYSQL_PLUGIN_DIR
MySQL.API.MYSQL_DEFAULT_AUTH
MySQL.API.MYSQL_OPT_BIND
MySQL.API.MYSQL_OPT_SSL_KEY
MySQL.API.MYSQL_OPT_SSL_CERT
MySQL.API.MYSQL_OPT_SSL_CA
MySQL.API.MYSQL_OPT_SSL_CAPATH
MySQL.API.MYSQL_OPT_SSL_CIPHER
MySQL.API.MYSQL_OPT_SSL_CRL
MySQL.API.MYSQL_OPT_SSL_CRLPATH
MySQL.API.MYSQL_OPT_CONNECT_ATTR_RESET
MySQL.API.MYSQL_OPT_CONNECT_ATTR_ADD
MySQL.API.MYSQL_OPT_CONNECT_ATTR_DELETE
MySQL.API.MYSQL_SERVER_PUBLIC_KEY
MySQL.API.MYSQL_ENABLE_CLEARTEXT_PLUGIN
MySQL.API.MYSQL_OPT_CAN_HANDLE_EXPIRED_PASSWORDS
```

#### MySQL.disconnect

```julia
MySQL.disconnect(conn::MySQL.Connection)
```
Disconnect a `MySQL.Connection` object from the remote database.

#### MySQL.escape

```julia
MySQL.escape(conn::MySQL.Connection, str::String) -> String
```
Escape an SQL statement

#### MySQL.Query (previously MySQL.query)

```julia
MySQL.Query(conn::MySQL.Connection, sql::String; append::Bool=false) => sink
```
Execute an SQL statement and return the results as a MySQL.Query object (see [MySQL.Query](#mysqlquery)).

The results can be materialized as a data sink that implements the Tables.jl interface.
E.g. `MySQL.Query(conn, sql) |> DataFrame` or `MySQL.Query(conn, sql) |> columntable`

#### MySQL.execute!

```julia
MySQL.execute!(conn::MySQL.Connection, sql::String)
MySQL.execute!(stmt::MySQL.Stmt, params)
```
Execute an SQL statement without returning results (useful for DDL statements, update, delete, etc.)

The SQL can either be passed as either a string or a prepared MySQL statement (see [MySQL.Stmt](#mysqlstmt)).

#### MySQL.insertid

```julia
MYSQL.insertid(conn::Connection)
```
Get the insert id of the most recently executed SQL statement.

### Types

#### MySQL.Connection

```julia
MySQL.connect(host::String, user::String, passwd::String; db::String="", port::Integer=3306, unix_socket::String=API.MYSQL_DEFAULT_SOCKET, client_flag=API.CLIENT_MULTI_STATEMENTS, opts = Dict())
```
A connection to a MySQL database.

#### MySQL.Stmt

```julia
MySQL.Stmt(conn::MySQL.Connection, sql::String) => MySQL.Stmt
```
A prepared SQL statement that may contain `?` parameter placeholders.

A `MySQL.Stmt` may then be executed by calling `MySQL.execute!(stmt, params)` where
`params` is a vector with the values to be bound to the `?` placeholders in the
original SQL statement. Params must be provided for every `?` and will be matched in the same order they
appeared in the original SQL statement.

Alternately, a source implementing the Tables.jl interface can be streamed by executing
`MySQL.execute!(itr, stmt)`. Each row must have a value for each param.

#### MySQL.Query

```julia
MySQL.Query(conn, sql, sink=Data.Table; append::Bool=false) => MySQL.Query
```

Execute an SQL statement and return a `MySQL.Query` object. Result rows can be iterated.

### Example

Connect to a database, query a table, write to a table, then close the database connection.
```julia
using MySQL
using DataFrames

conn = MySQL.connect("localhost", "root", "password", db = "test_db")

foo = MySQL.query(conn, """SELECT COUNT(*) FROM my_first_table;""") |> DataFrame
num_foo = foo[1,1]

my_stmt = MySQL.Stmt(conn, """INSERT INTO my_second_table ('foo_id','foo_name') VALUES (?,?);""")

for i = 1:num_foo
  MySQL.execute!(my_stmt, [i, "foo_$i"])
end

MySQL.disconnect(conn)
```
