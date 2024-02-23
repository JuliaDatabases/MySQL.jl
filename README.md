
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

## Contributing

The tests require a MySQL DB to be running, which is provided by Docker:

```sh
docker compose up -d
julia --project -e 'using Pkg; Pkg.test()'
docker compose down
```
