# MySQL.jl Documentation

```@contents
```

## Getting started

The MySQL.jl package provides a client library for Julia to interface with a mysql server. The package can be installed by doing:

```julia
] add MySQL
```

Once installed, you start using the package by making a connection to the mysql database by doing something like:

```julia
conn = DBInterface.connect(MySQL.Connection, host, user, passwd)
```

The first argument selects the database driver. Since 2.0 the connection speaks the MySQL wire protocol natively in Julia — no C library is involved. If you are upgrading from 1.x, see [Migrating from 1.x](migration.md). `DBInterface.connect` accepts many connection options, such as `port`, `db`, `ssl_mode`, and `option_file`; the [migration guide](migration.md) lists the 2.0 additions and changes.

Once connected, there are two ways to submit queries to the server:

  * `stmt = DBInterface.prepare(conn, sql); DBInterface.execute(stmt, params)`: first prepare a SQL statement against the database, then execute it with optional params. This allows re-executing the same statement repeatedly in an efficient way.
  * `DBInterface.execute(conn, sql, params)`: directly execute a SQL statement against the database, optionally passing params to be bound to markers.

Both execution methods return a `Cursor` object that supports the [Tables.jl](https://juliadata.github.io/Tables.jl/stable/) interface, which allows materializing a query resultset in a number of ways, like `DataFrame(x)`, `CSV.write("results.csv", x)`, etc.

`MySQL.load(table, conn, table_name)` loads a Tables.jl-compatible source into a database table. It generates the `CREATE TABLE` statement from the table schema. Column types often need manual control; use the `coltypes` and `columnsuffix` options (see the `MySQL.load` docstring).

## API reference

### Connections and results

```@docs
MySQL.Connection
MySQL.Statement
MySQL.Cursor
MySQL.ConnectOptions
DBInterface.connect
DBInterface.close!
DBInterface.execute
DBInterface.executemultiple
DBInterface.prepare
DBInterface.transaction
DBInterface.lastrowid
```

### Driver helpers

```@docs
MySQL.ping
MySQL.escape
MySQL.escape_identifier
MySQL.send_long_data!
MySQL.reset_statement!
MySQL.load
MySQL.juliatype
```

### Value types

```@docs
MySQL.Bit
MySQL.DateAndTime
```

### Errors

```@docs
MySQL.MySQLError
MySQL.Error
MySQL.StmtError
```

## Internal implementation

`MySQL.Protocol` is documented for maintainers. It is not part of the stable user API.

```@docs
MySQL.Protocol
```
