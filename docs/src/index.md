# MySQL.jl Documentation

```@contents
```

## Getting started

MySQL.jl is a client for MySQL and MariaDB servers. Since 2.0 it speaks the MySQL
client/server wire protocol natively in Julia (on [Reseau.jl](https://github.com/JuliaServices/Reseau.jl)
TCP/TLS transports) — no C database connector is involved. If you are upgrading from 1.x, see
[Migrating from 1.x](migration.md). Install it with:

```julia
] add MySQL
```

Connect through the [DBInterface.jl](https://github.com/JuliaDatabases/DBInterface.jl) API,
which the rest of this page uses:

```julia
using MySQL, DBInterface, Dates   # MySQL re-exports Durations.Timestamp

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

Parameters are bound by their Julia type: integers, floats, strings (`String`,
`DataString`, any `AbstractString`), bytes (`Vector{UInt8}`, `DataBytes`),
`Date`/`Time`/`Timestamp`/`DateTime`, `MySQL.Bit`, DataDecimals decimals, `Bool`, and
`missing`/`nothing` for NULL.

Pass a tuple, named tuple, vector, or `Tables.AbstractRow` for multiple parameters.
Values bind to `?` markers in iteration order; names do not change that order. Named SQL
markers such as `:name` are not supported. A bare scalar binds one parameter; use
`(bytes,)` to bind a byte vector as one binary value. `executemany` takes one collection
per parameter, as in the example below.

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
password). Unknown keywords raise `ArgumentError`. Removed and unavailable keywords also
raise `ArgumentError` unless their value is `nothing` or `false`.

**Where and how to connect**

| keyword | default | meaning |
|---|---|---|
| `db` | `""` | default database (`USE`) |
| `port` | `3306` | TCP port; omitted/`nothing` uses file or opt-in environment defaults; `0` explicitly selects 3306 |
| `protocol` | `:default` | `:tcp`, or the deferred `:socket`/`:pipe` (they raise a clear error) |
| `bind` | `nothing` | local interface/address to connect from |
| `connect_timeout` | `nothing` | positive integer seconds for the whole establishment (dial, TLS, authentication, charset bootstrap) |
| `read_timeout`, `write_timeout` | `nothing` | positive integer seconds per transport read/write; expiry closes the connection |
| `reconnect` | `false` | after a command fails on a dead connection, the next command reconnects (never inside a transaction) |
| `init_command` | `nothing` | SQL run after authentication and charset bootstrap; it must also succeed in expired-password sandbox mode |
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
| `can_handle_expired_passwords` | `false` | connect in sandbox mode with an expired password for `ALTER USER USER() IDENTIFIED BY '…'` / `SET PASSWORD`; normal queries fail with error 1820 until the password is reset |

**TLS**

| keyword | default | meaning |
|---|---|---|
| `ssl_mode` | `:preferred` | `:disabled`, `:preferred` (TLS when offered, no fallback after a failed handshake), `:required`, `:verify_ca`, `:verify_identity`; only the last two authenticate the server |
| `ssl_ca` / `ssl_capath` | `nothing` | CA bundle file / hashed CA directory (one of them); supplying one raises the default mode to `:verify_ca` |
| `ssl_cert`, `ssl_key` | `nothing` | client certificate and key (mutual TLS) |
| `ssl_server_name` | host | the name used for SNI and certificate verification |
| `tls_version` | TLS 1.2 and 1.3 | e.g. `"TLSv1.3"` |
| `ssl_enforce`, `ssl_verify_server_cert` | `nothing` | `true` requires TLS / identity verification; `false` does not lower the mode; contradictions with an explicit keyword `ssl_mode` are errors |

**Authentication** (`mysql_native_password`, `caching_sha2_password`, `sha256_password`, and
`mysql_clear_password` are supported)

| keyword | default | meaning |
|---|---|---|
| `default_auth` | supported server default, else `caching_sha2_password` | plugin to answer the handshake with; an auth switch selects the account's plugin |
| `get_server_public_key` | `false` | fetch the server's RSA key for `caching_sha2`/`sha256` full authentication over plain TCP |
| `server_public_key` | `nothing` | path of that key in PEM form |
| `enable_cleartext_plugin` | `false` | allow `mysql_clear_password` (PAM/LDAP accounts); `default_auth="mysql_clear_password"` also enables it |
| `insecure_cleartext_auth` | `false` | allow cleartext authentication without `:verify_identity` |

**Result decoding**

| keyword | default | meaning |
|---|---|---|
| `zero_dates` | `:sentinel` | `0000-00-00` values: `:sentinel` (`Date(0)` / `Timestamp{P}(0, 1, 1)`), `:missing` (dates become `Union{Missing, T}`), `:error` |
| `time_type` | `Dates.Time` | `TIME` columns as `Dates.Time` (`0 ≤ t < 24h`) or `Dates.Microsecond` (signed, up to ±838 h) |

**Limits** (received lengths are checked before growing their payload buffers; outgoing
commands are checked after encoding and before sending)

| keyword | default | meaning |
|---|---|---|
| `max_allowed_packet` | 16 MiB | largest packet sent or accepted |
| `max_buffered_bytes` | 256 MiB | retained bytes of one buffered command (`nothing` = unlimited) |
| `max_response_bytes` | `nothing` | cap on a whole response, streamed rows included |
| `max_columns`, `max_result_sets`, `max_metadata_bytes` | 4096, 1024, 16 MiB | columns per result or parameters per prepared statement; result sets and metadata bytes per command |
| `max_preauth_packet`, `max_auth_rounds`, `max_auth_bytes` | min(1 MiB, `max_allowed_packet`), 8, 64 KiB | connection-phase bounds |
| `max_session_state_bytes` | 1 MiB | session-state blocks in an OK packet, including command responses |

Deprecated 1.x keywords (`data_truncation`, `net_buffer_length`, `secure_auth`,
`multi_results`) are accepted with a warning and have no effect; see the
[migration guide](migration.md) for removed and not-yet-available ones.

### Option-file rules

Option files are opt-in. `option_file` selects one file. `read_default_file=true` or
`read_default_group=true` also reads the default locations. `option_group` without
`option_file` selects those locations as well. On Unix these are `/etc/my.cnf`,
`/etc/mysql/my.cnf`, and `~/.my.cnf`, in that order. On Windows they are `my.ini` and
`my.cnf` in `%WINDIR%`, then in `C:\`. The explicit file is read last. A missing explicit
file is an error; missing default files are skipped. World-writable files on Unix and
`.mylogin.cnf` login-path files are skipped with a warning.

The reader selects `[client]` and `option_group`, with case-insensitive group names.
The last occurrence of an option in file order wins, including across selected groups.
Quoted values, MySQL backslash escapes, `#` comments, and full-line `;` comments are
supported. `!include`, `!includedir`, and `?includedir` raise an error. Unknown keys are
ignored. This is a subset of the [MySQL option-file format](https://dev.mysql.com/doc/refman/8.4/en/option-files.html).

Supported file keys are `host`, `user`, `password`, `port`, `database`, `connect-timeout`,
`default-character-set`, `protocol`, `bind-address`, `socket`, `tls-version`, `ssl-mode`,
`ssl-ca`, `ssl-capath`, `ssl-cert`, and `ssl-key`. Underscores can replace hyphens.
`socket` is accepted but unused. `ssl-cipher`, `ssl-crl`, and `ssl-crlpath` raise an error
because these settings are unavailable. `compress` also raises an error unless its value
is `0`, `OFF`, or `FALSE` (case-insensitive).

Nonempty positional host/user values and non-`nothing` keywords override file values.
An empty host/user allows file fallback. An empty password or database overrides the
file with an empty value. `MYSQL_TCP_PORT` is used only with `read_env=true` and when
neither a keyword nor a file supplies the port. `MYSQL_PWD` is never read.

For TLS, keyword `ssl_mode` wins over file `ssl-mode`. Without that keyword,
`ssl_verify_server_cert=true` selects `:verify_identity`; `ssl_enforce=true` requires at
least `:required` and preserves a stronger file mode. Otherwise the file mode wins.
Without any mode selection, a CA selects `:verify_ca`; the remaining default is `:preferred`.

## Types

Result columns decode to the Julia types below (`Union{Missing, T}` unless the column is
`NOT NULL`; `UNSIGNED` integer columns map to the unsigned counterpart):

| MySQL | Julia |
|---|---|
| `TINYINT`, `SMALLINT`, `MEDIUMINT`/`INT`, `BIGINT` | `Int8`, `Int16`, `Int32`, `Int64` |
| `FLOAT`, `DOUBLE` | `Float32`, `Float64` |
| `DECIMAL`/`NUMERIC` | `MySQL.DecimalResult` (exact, all 65 digits) |
| `BIT(n)` | `MySQL.Bit` |
| `DATE`, `TIME` | `Date`, `Time` (or `Microsecond` with `time_type`) |
| `DATETIME`/`TIMESTAMP` | `Timestamp{Second}`; with `fsp` 1–3 `Timestamp{Millisecond}`, 4–6 `Timestamp{Microsecond}` |
| `YEAR` | `Clong` (unsigned) |
| `CHAR`/`VARCHAR`/`TEXT`, `BINARY`/`VARBINARY`, `ENUM`, `SET`, `JSON` | `DataString` |
| `BLOB`, `GEOMETRY` | `DataBytes` |

`DataString` and `DataBytes` are [DataStrings.jl](https://github.com/JuliaData/DataStrings.jl)'s
compact string and byte values (the Arrow Utf8View/BinaryView layout): a value of up to
12 bytes is stored inline, a longer one references the cursor's row buffer, so decoding a
result copies no bytes and allocates nothing per value. `DataString <: AbstractString`
behaves like `String` (equality, hashing, ordering, iteration, `String(s)` to copy out);
`DataBytes <: AbstractVector{UInt8}` likewise (`Vector{UInt8}(b)` copies). A long value
keeps the buffer it references alive — the whole result of a buffered cursor, or the arena
a streaming cursor read its row into. Arenas have a 64 KiB target; a row can grow an arena
past that size. `String(s)`/`Vector{UInt8}(b)` detaches a value, and
`DataStrings.materialize(column)` detaches a whole column (as returned by
`Tables.columntable` or a DataFrame), copying every value out to a `String` or
`Vector{UInt8}` and keeping `missing`s. Requesting `String`/`Vector{UInt8}` explicitly through the
typed accessor (`Tables.getcolumn(row, String, i, name)`) still returns a copy.
`BINARY`/`VARBINARY` keep the 1.x string mapping; their bytes need not be valid UTF-8.

`Timestamp{P}` is [Durations.jl](https://github.com/JuliaData/Durations.jl)'s `Int64`
count since the Unix epoch at resolution `P` (the type proposed for the Julia 1.14 Dates
stdlib, which it becomes automatically there); `MySQL` re-exports it. It is an
`AbstractDateTime`: `Dates.year(ts)`, `DateTime(ts)`, `Date(ts)`, `Time(ts)`, arithmetic
with periods, and comparisons with `DateTime`/`Date` all work, and every MySQL value is
represented exactly. Construct one with `Timestamp{Microsecond}(2024, 2, 29, 13, 14, 15, 250, 500)`.

`MySQL.juliatype` computes the mapping for a wire type and its flags.

## Errors

Server errors are thrown as `MySQL.Error` (or `MySQL.StmtError` from prepared-statement
operations) with `errno`, `msg`, and `sqlstate` fields. A connection the server dropped
reports 4031 when MySQL supplies an idle-disconnect ERR, or the classic client codes
2006 ("MySQL server has gone away") and 2013 ("Lost connection to MySQL server during query")
when the transport closes. Protocol and server exceptions derive from
`MySQL.MySQLError`: besides the server errors there are `ProtocolError` (the byte stream
violated the protocol or a limit; the connection is closed), `TimeoutError`, `AuthError`,
`TLSNegotiationError`, `ConversionError` (a value cannot be represented by the column's
Julia type), and `LocalInfileRefused`. Invalid options and stale row access can raise
`ArgumentError`; transport errors can also propagate.

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
MySQL.DecimalResult
MySQL.timestamp_type
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
