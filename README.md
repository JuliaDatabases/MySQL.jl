
# MySQL

[![docs](https://img.shields.io/badge/docs-latest-blue&logo=julia)](https://mysql.juliadatabases.org/dev/)
[![CI](https://github.com/JuliaDatabases/MySQL.jl/workflows/CI/badge.svg)](https://github.com/JuliaDatabases/MySQL.jl/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/JuliaDatabases/MySQL.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaDatabases/MySQL.jl)

[![deps](https://juliahub.com/docs/MySQL/deps.svg)](https://juliahub.com/ui/Packages/MySQL/xeTdU?t=2)
[![version](https://juliahub.com/docs/MySQL/version.svg)](https://juliahub.com/ui/Packages/MySQL/xeTdU)
[![pkgeval](https://juliahub.com/docs/MySQL/pkgeval.svg)](https://juliahub.com/ui/Packages/MySQL/xeTdU)

Package for interfacing with MySQL databases from Julia.

Since 2.0, MySQL.jl implements the MySQL client/server wire protocol natively in Julia
(built on [Reseau.jl](https://github.com/JuliaServices/Reseau.jl) for TCP/TLS) — no C
client library. 1.x used the MariaDB Connector/C library; see the
[migration guide](https://mysql.juliadatabases.org/dev/migration/) for the differences.

## Documentation

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://mysql.juliadatabases.org/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://mysql.juliadatabases.org/dev)

## Usage

```julia
conn = DBInterface.connect(MySQL.Connection, host, user, passwd; db="mydb", port=3306)
cursor = DBInterface.execute(conn, "SELECT * FROM mytable")   # a Tables.jl-compatible cursor
stmt = DBInterface.prepare(conn, "INSERT INTO mytable (a, b) VALUES (?, ?)")
DBInterface.execute(stmt, (1, "two"))
DBInterface.close!(conn)
```

`DBInterface.execute`/`prepare`/`executemany`/`executemultiple`, Tables.jl cursors,
`MySQL.load`, and transactions are all supported; see the
[documentation](https://mysql.juliadatabases.org/dev/). The transport is TCP or TLS
(no Unix sockets, named pipes, or compression yet — these raise clear errors).

## Contributing

The test suite manages its own temporary MySQL container via Harbor.jl. The only prerequisite is a working Docker daemon:

```sh
julia --project -e 'using Pkg; Pkg.test()'
```
