# MySQL.jl Documentation

```@contents
```

## Getting started

MySQL.jl is a client for MySQL and MariaDB servers. Since 2.0 it speaks the MySQL
client/server wire protocol natively in Julia (on [Reseau.jl](https://github.com/JuliaServices/Reseau.jl)
TCP/TLS transports) — no C library is involved. If you are upgrading from 1.x, see
[Migrating from 1.x](migration.md). Install it with:

```julia
] add MySQL
```

Connect through the [DBInterface.jl](https://github.com/JuliaDatabases/DBInterface.jl) API,
which the rest of this page uses:

```julia
using MySQL, DBInterface

conn = DBInterface.connect(MySQL.Connection, "localhost", "user", "password"; db="mydb")
```

Every host, `"localhost"` included, is dialed over TCP (port 3306 unless `port` is given).
TLS is used whenever the server offers it (`ssl_mode=:preferred`); see
[Connection options](@ref) for the full keyword list.

### Queries and results

There are two ways to run SQL:

  * `DBInterface.execute(conn, sql)` runs a statement over the text protocol.
  * `stmt = DBInterface.prepare(conn, sql); DBInterface.execute(stmt, params)` prepares a
    statement once and executes it any number of times with parameters bound to its `?`
    markers over the binary protocol. `DBInterface.execute(conn, sql, params)` is the
    one-shot form (prepare, execute, close).

Both return a `MySQL.Cursor`, a [Tables.jl](https://juliadata.github.io/Tables.jl/stable/)
row source, so a result can be materialized as `DataFrame(cursor)`, `Tables.columntable(cursor)`,
`CSV.write("out.csv", cursor)`, or iterated row by row:

```julia
for row in DBInterface.execute(conn, "SELECT id, name FROM users")
    println(row.id, ": ", row.name)   # row.name, row[:name], row[2]
end
```

A row is valid only while it is the cursor's current row (the cursor is a forward-only
iterator); collect the values you need before advancing. By default the whole result set is
read at execute time (`mysql_store_result=true`); `mysql_store_result=false` streams rows as
they are iterated, which keeps memory flat for large results but keeps the connection busy
until the cursor is exhausted or closed. `cursor.rows_affected` and
`DBInterface.lastrowid(cursor)` report a DML statement's outcome.

Parameters are bound by their Julia type: integers, floats, `String`s, `Vector{UInt8}`
(binary), `Date`/`DateTime`/`Time`/`MySQL.DateAndTime`, `MySQL.Bit`, DataDecimals
decimals, `Bool`, and `missing`/`nothing` for NULL.

```julia
stmt = DBInterface.prepare(conn, "INSERT INTO users (name, joined) VALUES (?, ?)")
DBInterface.execute(stmt, ("alice", Date(2026, 1, 2)))
DBInterface.executemany(stmt, (name=["bob", "carol"], joined=[Date(2026, 1, 3), Date(2026, 1, 4)]))
DBInterface.close!(stmt)
```

`DBInterface.transaction(conn) do ... end` wraps the block in `START TRANSACTION`/`COMMIT`
(`ROLLBACK` on an exception). `DBInterface.executemultiple` iterates the result sets of a
`CALL` or of a multi-statement string (`multi_statements=true`) as distinct cursors.
`MySQL.load(table, conn, name)` creates a table from a Tables.jl source's schema and
inserts its rows in batches. Close the connection with `DBInterface.close!(conn)`.

## Connection options

`DBInterface.connect(MySQL.Connection, host, user, password; kw...)` accepts the keywords
below (`password=nothing` can use an option-file password; `""` overrides it with an empty
password). Unknown
keywords, removed 1.x keywords, and keywords that are not available yet all raise an
`ArgumentError` that explains the situation.

**Where and how to connect**

| keyword | default | meaning |
|---|---|---|
| `db` | `""` | default database (`USE`) |
| `port` | `3306` | TCP port; `0`/`nothing` means the default (option files can supply it) |
| `protocol` | `:default` | `:tcp`, or the deferred `:socket`/`:pipe` (they raise a clear error) |
| `bind` | `nothing` | local interface/address to connect from |
| `connect_timeout` | `nothing` | seconds for the whole establishment (dial, TLS, authentication, charset bootstrap) |
| `read_timeout`, `write_timeout` | `nothing` | seconds per transport read/write; expiry closes the connection |
| `reconnect` | `false` | after a command fails on a dead connection, the next command reconnects (never inside a transaction) |
| `init_command` | `nothing` | SQL run right after authentication |
| `charset_name` | `"utf8mb4"` | the only supported character set; the session is bootstrapped to utf8mb4 |
| `attrs` | client name/version/OS/pid | `Vector{Pair{String, String}}` of connection attributes sent in the handshake |
| `option_file`, `option_group` | `nothing` | a my.cnf/my.ini file (and group besides `[client]`) supplying host/user/password/port/database/TLS settings |
| `read_default_file`, `read_default_group` | `false` | also read the standard option-file locations |
| `read_env` | `false` | let `MYSQL_TCP_PORT` fill an omitted port (`MYSQL_PWD` is never read) |
| `debug` | `false` | log every packet at `@debug` level |

**Server-side behaviour flags**

| keyword | default | meaning |
|---|---|---|
| `multi_statements` | `false` | allow `"stmt1; stmt2"` (consume the results with `DBInterface.executemultiple`) |
| `found_rows` | `false` | `rows_affected` counts matched rows instead of changed rows |
| `no_schema`, `ignore_space` | `false` | the corresponding server flags |
| `local_files` | `false` | allow `LOAD DATA LOCAL INFILE`; requires `local_infile_handler` |
| `local_infile_handler` | `nothing` | `filename -> IO` (or `nothing` to refuse) called when the server requests a local file |
| `max_local_infile_bytes` | 1 GiB | cap on one upload |
| `can_handle_expired_passwords` | `false` | advertise expired-password support; the required charset bootstrap can still fail with error 1820, so this does not yet provide a password-reset connection |

**TLS**

| keyword | default | meaning |
|---|---|---|
| `ssl_mode` | `:preferred` | `:disabled`, `:preferred` (TLS when offered, no fallback after a failed handshake), `:required`, `:verify_ca`, `:verify_identity`; only the last two authenticate the server |
| `ssl_ca` / `ssl_capath` | `nothing` | CA bundle file / hashed CA directory (one of them); supplying one raises the default mode to `:verify_ca` |
| `ssl_cert`, `ssl_key` | `nothing` | client certificate and key (mutual TLS) |
| `ssl_server_name` | host | the name used for SNI and certificate verification |
| `tls_version` | TLS 1.2 and 1.3 | e.g. `"TLSv1.3"` |
| `ssl_enforce`, `ssl_verify_server_cert` | `nothing` | 1.x spellings of `:required` / `:verify_identity`; an explicit `ssl_mode` wins and contradictions are errors |

**Authentication** (`mysql_native_password`, `caching_sha2_password`, `sha256_password`, and
`mysql_clear_password` are supported)

| keyword | default | meaning |
|---|---|---|
| `default_auth` | supported server default, else `caching_sha2_password` | plugin to answer the handshake with; an auth switch selects the account's plugin |
| `get_server_public_key` | `false` | fetch the server's RSA key for `caching_sha2`/`sha256` full authentication over plain TCP |
| `server_public_key` | `nothing` | path of that key in PEM form |
| `enable_cleartext_plugin` | `false` | allow `mysql_clear_password` (PAM/LDAP accounts) |
| `insecure_cleartext_auth` | `false` | allow cleartext authentication without `:verify_identity` |

**Result decoding**

| keyword | default | meaning |
|---|---|---|
| `zero_dates` | `:sentinel` | `0000-00-00` values: `:sentinel` (`Date(0)`/`DateTime(0)`), `:missing` (dates become `Union{Missing, T}`), `:error` |
| `time_type` | `Dates.Time` | `TIME` columns as `Dates.Time` (`0 ≤ t < 24h`) or `Dates.Microsecond` (signed, up to ±838 h) |

`mysql_date_and_time=true` on `execute`/`prepare` decodes DATETIME/TIMESTAMP to
`MySQL.DateAndTime` with microsecond precision.

**Limits** (received lengths are checked before growing their payload buffers; outgoing
commands are checked after encoding and before sending)

| keyword | default | meaning |
|---|---|---|
| `max_allowed_packet` | 16 MiB | largest packet sent or accepted |
| `max_buffered_bytes` | 256 MiB | retained bytes of one buffered command (`nothing` = unlimited) |
| `max_response_bytes` | `nothing` | cap on a whole response, streamed rows included |
| `max_columns`, `max_result_sets`, `max_metadata_bytes` | 4096, 1024, 16 MiB | columns per result or parameters per prepared statement; result sets and metadata bytes per command |
| `max_preauth_packet`, `max_auth_rounds`, `max_auth_bytes` | 1 MiB, 8, 64 KiB | connection-phase bounds |
| `max_session_state_bytes` | 1 MiB | session-state blocks in an OK packet, including command responses |

Deprecated 1.x keywords (`data_truncation`, `net_buffer_length`, `secure_auth`,
`multi_results`) are accepted with a warning and have no effect; see the
[migration guide](migration.md) for removed and not-yet-available ones.

## Types

Result columns decode to the Julia types below (`Union{Missing, T}` unless the column is
`NOT NULL`; `UNSIGNED` integer columns map to the unsigned counterpart):

| MySQL | Julia |
|---|---|
| `TINYINT`, `SMALLINT`, `MEDIUMINT`/`INT`, `BIGINT` | `Int8`, `Int16`, `Int32`, `Int64` |
| `FLOAT`, `DOUBLE` | `Float32`, `Float64` |
| `DECIMAL`/`NUMERIC` | `MySQL.DecimalResult` (exact, all 65 digits) |
| `BIT(n)` | `MySQL.Bit` |
| `DATE`, `TIME`, `DATETIME`/`TIMESTAMP` | `Date`, `Time` (or `Microsecond`), `DateTime` (or `MySQL.DateAndTime`) |
| `YEAR` | `Clong` (unsigned) |
| `CHAR`/`VARCHAR`/`TEXT`, `ENUM`, `SET`, `JSON` | `String` |
| `BINARY`/`VARBINARY`/`BLOB`, `GEOMETRY` | `Vector{UInt8}` |

`MySQL.juliatype` computes the mapping for a wire type and its flags.

## Errors

Server errors are thrown as `MySQL.Error` (or `MySQL.StmtError` from prepared-statement
operations) with `errno`, `msg`, and `sqlstate` fields. A connection the server dropped
reports the classic client codes 2006 ("MySQL server has gone away") and 2013 ("Lost
connection to MySQL server during query"). Every exception the package raises is a
`MySQL.MySQLError`: besides the server errors there are `ProtocolError` (the byte stream
violated the protocol or a limit; the connection is closed), `TimeoutError`, `AuthError`,
`TLSNegotiationError`, `ConversionError` (a value cannot be represented by the column's
Julia type), and `LocalInfileRefused`.

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
MySQL.connection_id
MySQL.server_version
MySQL.server_kind
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
MySQL.DecimalResult
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
