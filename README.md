
# MySQL

[![docs](https://img.shields.io/badge/docs-latest-blue&logo=julia)](https://mysql.juliadatabases.org/dev/)
[![CI](https://github.com/JuliaDatabases/MySQL.jl/workflows/CI/badge.svg)](https://github.com/JuliaDatabases/MySQL.jl/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/JuliaDatabases/MySQL.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaDatabases/MySQL.jl)

[![deps](https://juliahub.com/docs/MySQL/deps.svg)](https://juliahub.com/ui/Packages/MySQL/xeTdU?t=2)
[![version](https://juliahub.com/docs/MySQL/version.svg)](https://juliahub.com/ui/Packages/MySQL/xeTdU)
[![pkgeval](https://juliahub.com/docs/MySQL/pkgeval.svg)](https://juliahub.com/ui/Packages/MySQL/xeTdU)

Package for interfacing with MySQL and MariaDB databases from Julia.

Since 2.0, MySQL.jl implements the MySQL client/server wire protocol natively in Julia
(built on [Reseau.jl](https://github.com/JuliaServices/Reseau.jl) for TCP/TLS) — no C
client library. 1.x used the MariaDB Connector/C library; see the
[migration guide](https://mysql.juliadatabases.org/dev/migration/) for the differences.

## Documentation

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://mysql.juliadatabases.org/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://mysql.juliadatabases.org/dev)

## Usage

```julia
using MySQL, DBInterface, Tables, Dates

conn = DBInterface.connect(MySQL.Connection, "localhost", "user", "password"; db="mydb", port=3306)

# text protocol: the cursor is a Tables.jl row source
cursor = DBInterface.execute(conn, "SELECT id, name FROM users WHERE active = 1")
for row in cursor
    println(row.id, " ", row.name)   # a row is valid only while it is the cursor's current row
end
table = Tables.columntable(DBInterface.execute(conn, "SELECT * FROM users"))
# With DataFrames or CSV loaded, DataFrame(cursor) and CSV.write("out.csv", cursor) also work.

# prepared statements (binary protocol) with bound parameters
stmt = DBInterface.prepare(conn, "INSERT INTO users (name, joined) VALUES (?, ?)")
DBInterface.execute(stmt, ("alice", Date(2026, 1, 2)))
DBInterface.executemany(stmt, (name=["bob", "carol"], joined=[Date(2026, 1, 3), Date(2026, 1, 4)]))
DBInterface.close!(stmt)
cursor = DBInterface.execute(conn, "SELECT * FROM users WHERE id = ?", (17,))   # one-shot prepare + execute
DBInterface.lastrowid(DBInterface.execute(conn, "INSERT INTO users (name) VALUES ('dave')"))

# transactions, streaming, bulk loading
DBInterface.transaction(conn) do
    DBInterface.execute(conn, "UPDATE accounts SET balance = balance - 10 WHERE id = 1")
    DBInterface.execute(conn, "UPDATE accounts SET balance = balance + 10 WHERE id = 2")
end
for row in DBInterface.execute(conn, "SELECT * FROM big_table"; mysql_store_result=false)   # stream rows
    # ...
end
MySQL.load(table, conn, "users_copy")   # CREATE TABLE from the schema, then batched INSERTs

DBInterface.close!(conn)
```

Connection options cover TLS (`ssl_mode=:required`, `:verify_ca`, `:verify_identity`, CA and
client certificates), option files (`option_file`, `read_default_file`), timeouts
(`connect_timeout`, `read_timeout`, `write_timeout`), `reconnect`, `multi_statements`,
`init_command`, decoding policies (`zero_dates`, `time_type`), and
memory limits (`max_buffered_bytes`); see the
[documentation](https://mysql.juliadatabases.org/dev/). The transport is TCP or TLS
(Unix sockets, named pipes, and compression are not supported yet and raise clear errors).

Results use the JuliaData value types: text and BLOB columns are zero-copy
[DataStrings.jl](https://github.com/JuliaData/DataStrings.jl) `DataString`/`DataBytes`
views, DATETIME/TIMESTAMP columns decode to `Timestamp{P}`
([Durations.jl](https://github.com/JuliaData/Durations.jl), re-exported) at the column's
fractional precision, and DECIMAL to exact
[DataDecimals.jl](https://github.com/JuliaData/DataDecimals.jl) values.

## Contributing

The test suite manages its own temporary MySQL container via Harbor.jl. The only prerequisite is a working Docker daemon:

```sh
julia --project -e 'using Pkg; Pkg.test()'
```

Without Docker the serverless wire-protocol suite still runs (it drives the client against a scripted in-process peer).
