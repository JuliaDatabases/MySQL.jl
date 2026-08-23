
# MySQL

[![docs](https://img.shields.io/badge/docs-latest-blue&logo=julia)](https://mysql.juliadatabases.org/dev/)
[![CI](https://github.com/JuliaDatabases/MySQL.jl/workflows/CI/badge.svg)](https://github.com/JuliaDatabases/MySQL.jl/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/JuliaDatabases/MySQL.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaDatabases/MySQL.jl)

[![deps](https://juliahub.com/docs/MySQL/deps.svg)](https://juliahub.com/ui/Packages/MySQL/xeTdU?t=2)
[![version](https://juliahub.com/docs/MySQL/version.svg)](https://juliahub.com/ui/Packages/MySQL/xeTdU)
[![pkgeval](https://juliahub.com/docs/MySQL/pkgeval.svg)](https://juliahub.com/ui/Packages/MySQL/xeTdU)

Package for interfacing with MySQL databases from Julia via the MariaDB C connector library, version 3.1.6.

## Documentation

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://mysql.juliadatabases.org/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://mysql.juliadatabases.org/dev)

## Native wire-protocol backend (preview)

MySQL.jl 1.7 ships an opt-in implementation of the MySQL client/server protocol in Julia
(`MySQL.Native`, built on [Reseau.jl](https://github.com/JuliaServices/Reseau.jl) for
TCP/TLS) next to the existing MariaDB Connector/C backend. `MySQL.Connection` is unchanged;
to try the native backend, connect with `MySQL.Native.Connection` instead:

```julia
conn = DBInterface.connect(MySQL.Native.Connection, host, user, passwd; db="mydb", port=3306)
```

`DBInterface.execute`/`prepare`/`executemany`, Tables.jl cursors, `MySQL.load` and
transactions all work the same way. The native backend is planned to become the default
`MySQL.Connection` in 2.0; the [migration guide](https://mysql.juliadatabases.org/dev/migration/)
lists the option and behavior differences (TCP/TLS only in the preview: no Unix sockets,
named pipes, or compression yet).

## Contributing

The test suite manages its own temporary MySQL container via Harbor.jl. The only prerequisite is a working Docker daemon:

```sh
julia --project -e 'using Pkg; Pkg.test()'
```
