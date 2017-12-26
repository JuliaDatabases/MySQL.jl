
# MySQL

*Package for interfacing with MySQL databases from Julia*

| **PackageEvaluator**                                            | **Build Status**                                                                                |
|:---------------------------------------------------------------:|:-----------------------------------------------------------------------------------------------:|
|[![][pkg-0.6-img]][pkg-0.6-url] | [![][travis-img]][travis-url] [![][codecov-img]][codecov-url] |


## Installation

The package is registered in `METADATA.jl` and so can be installed with `Pkg.add`.

```julia
julia> Pkg.add("MySQL")
```

## Project Status

The package is tested against the current Julia `0.6` release and nightly on Linux and OS X.

## Contributing and Questions

Contributions are very welcome, as are feature requests and suggestions. Please open an
[issue][issues-url] if you encounter any problems or would just like to ask a question.


<!-- [docs-latest-img]: https://img.shields.io/badge/docs-latest-blue.svg
[docs-latest-url]: https://JuliaData.github.io/MySQL.jl/latest -->

[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://JuliaData.github.io/MySQL.jl/stable

[travis-img]: https://travis-ci.org/JuliaData/MySQL.jl.svg?branch=master
[travis-url]: https://travis-ci.org/JuliaData/MySQL.jl

[codecov-img]: https://codecov.io/gh/JuliaData/MySQL.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaData/MySQL.jl

[issues-url]: https://github.com/JuliaData/MySQL.jl/issues

[pkg-0.6-img]: http://pkg.julialang.org/badges/MySQL_0.6.svg
[pkg-0.6-url]: http://pkg.julialang.org/?pkg=MySQL

## Documentation

```julia
MySQL.connect(host::String, user::String, passwd::String; db::String = "", port = "3306", socket::String = MySQL.API.MYSQL_DEFAULT_SOCKET, opts = Dict())
```
Connect to a mysql database, returns a `MySQL.Connection` object to be passed to other API functions

```julia
MySQL.disconnect(conn::MySQL.Connection)
```
Disconnect a `MySQL.Connection` object from the remote database:

```julia
MYSQL.insertid(conn::Connection)
```
Get the insert id of the most recently executed SQL statement:

```julia
MySQL.escape(conn::MySQL.Connection, str::String) -> String
```
Escape an SQL statement

```julia
MySQL.execute!(conn, sql) => # of affected rows
```
Execute an SQL statement without returning results (useful for DDL statements, update, delete, etc.)

```julia
MySQL.query(conn, sql, sink=Data.Table; append::Bool=false) => sink
```
Execute an SQL statement and return the results in `sink`, which can be any valid `Data.Sink` (interface from DataStreams.jl). By default, a NamedTuple of Vectors are returned.

Passing `append=true` as a keyword argument will cause the resultset to be _appended_ to the sink instead of replacing.

To get the results as a `DataFrame`, you can just do `MySQL.query(conn, sql, DataFrame)`.

```julia
MySQL.Query(conn, sql, sink=Data.Table; append::Bool=false) => MySQL.Query
```
execute an sql statement and return a `MySQL.Query` object. Result rows can be iterated as NamedTuples via `Data.rows(query)` where `query` is the `MySQL.Query` object. Results can also be streamed to any valid `Data.Sink` via `Data.stream!(query, sink)`.

```julia
MySQL.Stmt(conn, sql) => MySQL.Stmt
```
Prepare an SQL statement that may contain `?` parameter placeholders.

A `MySQL.Stmt` may then be executed by calling `MySQL.execute!(stmt, params)` where `params` are the values to be bound to the `?` placeholders in the original SQL statement. Params must be provided for every `?` and will be matched in the same order they appeared in the original SQL statement.

Bulk statement execution can be accomplished by "streaming" a param source like:

```julia
Data.stream!(source, stmt)
```

where `source` is any valid `Data.Source` (from DataStreams.jl). As with `MySQL.execute!`, the `source` must provide enough params and will be matched in the same order.