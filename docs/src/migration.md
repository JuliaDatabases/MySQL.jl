# Migrating from 1.x to 2.0

MySQL.jl 2.0 replaces the MariaDB Connector/C backend with a **native wire-protocol
implementation**: the MySQL client/server protocol written in Julia on top of
[Reseau](https://github.com/JuliaServices/Reseau.jl) transports (TCP and TLS). It is *not*
"pure Julia" — OpenSSL underpins TLS and the RSA password exchange — but every `libmariadb`
`ccall`, its dynamic plugin loading, and its C handle lifetimes are gone, along with the
crash classes they caused (issues #220, #236, #240, #208, #206).

`MySQL.Connection` is now the native connection. Most code — `DBInterface.connect` /
`execute` / `prepare` / `executemany` / `executemultiple` / `transaction`, Tables.jl
cursors, `MySQL.load`, buffered (`mysql_store_result=true`, the default) and streaming
result sets — works unchanged. Pin `MySQL = "1"` to stay on the
last Connector/C release.

## Upgrade checklist

MySQL.jl 2.0 requires **Julia 1.10 or later**.

1. **Errors**: replace `MySQL.API.Error` / `MySQL.API.StmtError` with `MySQL.Error` /
   `MySQL.StmtError` (same field names/types plus a new `sqlstate`), or catch the root
   `MySQL.MySQLError`.
2. **Value types**: replace `MySQL.API.Bit` with `MySQL.Bit`. Text columns decode to
   `DataString` and BLOB columns to `DataBytes`
   ([DataStrings.jl](https://github.com/JuliaData/DataStrings.jl)): zero-copy views of the
   result buffer that compare, hash, sort, and print like `String`/`Vector{UInt8}`; copy
   out with `String(s)`/`Vector{UInt8}(b)`, or ask the typed accessor for `String`
   explicitly. Code that dispatches on `::String` needs `::AbstractString`. DATETIME/TIMESTAMP
   columns decode to `Timestamp{P}` — [Durations.jl](https://github.com/JuliaData/Durations.jl)'s
   `Int64` Unix-epoch instant, the type proposed for the Julia 1.14 Dates stdlib, which
   `MySQL` re-exports — at the column's declared fractional precision: `DATETIME` is
   `Timestamp{Second}`, `DATETIME(1..3)` `Timestamp{Millisecond}`, `DATETIME(4..6)`
   `Timestamp{Microsecond}`. Every value is exact, so `MySQL.DateAndTime` and the
   `mysql_date_and_time` keyword are gone. `DateTime(ts)`, `Date(ts)`, and `Time(ts)`
   convert; comparisons with `DateTime` work directly; `DateTime` values still bind as
   parameters. DECIMAL results decode to `MySQL.DecimalResult`
   (`DataDecimals.DecimalValue{DataDecimals.Int256}`), which preserves all 65 digits and
   the stored scale, instead of `DecFP.Dec64`; DataDecimals values bind directly as
   parameters, and `MySQL.load` infers `DECIMAL(P,S)` from a fixed-scale type (for a
   `DecimalValue` column, specify the destination type with `coltypes`). DecFP is not
   supported anymore: convert `Dec64`/`Dec128` values to DataDecimals (or strings) before
   binding them.
3. **Multi-statements**: pass `multi_statements=true` if you relied on 1.x accepting
   `"stmt1; stmt2"` by default (an `if/elseif` bug made 1.x enable it silently).
4. **Enum-valued options**: pass Symbols — `ssl_mode=:required` (was
   `MySQL.API.SSL_MODE_REQUIRED`), `protocol=:tcp` (was `MySQL.API.MYSQL_PROTOCOL_TCP`).
5. **Local servers**: every host, `"localhost"` and `""` included, is dialed over TCP (the
   Connector/C rule that turned `localhost` into a Unix socket is gone). The socket and
   named-pipe transports are not implemented yet: `protocol=:socket`/`:pipe` or
   `named_pipe=true` raise a clear error (an explicit `protocol=:tcp` overrides
   `named_pipe`). A `unix_socket` path is accepted but unused.
   TCP access also needs a matching account grant. With `skip_name_resolve`, a
   `'user'@'localhost'` grant need not cover `127.0.0.1` or `::1`; see
   [MySQL's host-resolution rules](https://dev.mysql.com/doc/refman/8.0/en/server-system-variables.html#sysvar_skip_name_resolve).
   Socket-only authentication also needs a TCP-compatible account.
6. **Unknown, removed, or unavailable keywords now error** with an explanation instead of
   being silently swallowed — fix the call sites the errors point at.

## The `MySQL.API` module is gone

1.x names and their 2.0 replacements:

| 1.x | 2.0 |
|---|---|
| `MySQL.API.Error`, `MySQL.API.StmtError` | `MySQL.Error`, `MySQL.StmtError` (aliases of `MySQL.Protocol.Error`/`StmtError`; same `errno::Cuint`/`msg` fields and `showerror` text, plus `sqlstate`); root type `MySQL.MySQLError` |
| `MySQL.API.Bit` | `MySQL.Bit` (same `bits::UInt64` field) |
| `MySQL.DateAndTime` (`MySQL.API.DateAndTime`), `mysql_date_and_time=true` | removed: DATETIME/TIMESTAMP decode to `Timestamp{P}` (re-exported from Durations.jl) with every digit the column carries |
| `MySQL.API.juliatype` / `MySQL.juliatype` | `MySQL.juliatype` (strings → `DataString`, blobs → `DataBytes`, DATETIME/TIMESTAMP → `Timestamp{P}`, DECIMAL → DataDecimals) |
| `MySQL.API.MYSQL_TYPE_*` constants | `MySQL.Protocol.MYSQL_TYPE_*` (wire-value `UInt8`s) |
| `MySQL.API.SSL_MODE_*`, `MySQL.API.MYSQL_PROTOCOL_*` enums | Symbols: `ssl_mode=:disabled/:preferred/:required/:verify_ca/:verify_identity`, `protocol=:default/:tcp/:socket/:pipe` |
| `MySQL.API.mysqltype` | removed (parameter types are inferred from Julia values when binding) |
| `MySQL.API` handle types (`MYSQL`, `MYSQL_STMT`, `MYSQL_RES`, `MYSQL_BIND`), raw `ccall` wrappers, `MySQL.setoptions!`/`API.getoption` | removed — there are no C handles |
| `conn.mysql` (the raw C handle field on `Connection`) | removed — use the driver API; per-command results live on the returned cursor (`cur.rows_affected`, `DBInterface.lastrowid(cur)`) |

Cursor/row types: `MySQL.Cursor{binary, buffered}` with aliases `MySQL.TextCursor`
(`DBInterface.execute(conn, sql)`) and `MySQL.BinaryCursor` (prepared execution);
row types `MySQL.TextRow` and `MySQL.BinaryRow` (1.x: `MySQL.TextRow` and `MySQL.Row`).

## Additional 2.0 breaks (beyond the behavior table)

- **`mysql://` stripping**: only a *leading* `mysql://` prefix on the host is stripped;
  1.x stripped everything up to a `mysql://` substring found anywhere in the host.
- **`port=0`** now means the default port (3306); in 1.x it meant "take the port from the
  option file". Omit `port` (or pass `nothing`) to fall back to option files.
- **`conn.port`** is an `Int` (was a `String`), and `Base.show` prints it unquoted.
- **`MySQL.load`** `debug` keyword accepts `false`/`true`/`:values`; `debug=true` logs
  generated statements only, `debug=:values` also logs row values (1.x `debug=true`
  logged values). A `DateTime` column is created as `DATETIME(3)` (1.x: `DATETIME`,
  which dropped the milliseconds); `Timestamp{Second}`/`{Millisecond}`/`{Microsecond}`
  columns become `DATETIME`/`DATETIME(3)`/`DATETIME(6)`.

## Unchanged (Preserve)

The observable 1.x surface is preserved unless a row below says otherwise, including:
positional `connect(MySQL.Connection, host, user, passwd)`, `passwd=nothing` vs `""`,
option files (subset; unsupported directives fail closed), `init_command`,
`found_rows`/`no_schema`/`ignore_space` as independent flags, the result type mapping
(`MySQL.juliatype`) except for DECIMAL and the decoding policies below, driver-keyword
dispatch on `execute` (SQL parameters still cannot be passed as keywords), `executemany`, the `wrongrow`
contract ("a row is only valid while it is the cursor's current row", same
`ArgumentError`), `rows_affected::Int64` bitcast semantics, cursor `close!`/`close`
idempotence, and escaping (`MySQL.escape`).

These are asserted by the executable behavior manifest
(`test/behavior_manifest.jl`), whose golden values were captured from dual-backend runs
against the same servers before the C backend was removed.

## Behavior changes (Fix)

Deliberate, documented changes relative to Connector/C 1.6.0:

| Area | 1.6.0 (Connector/C) | 2.0 (native) |
|---|---|---|
| Client flags | `if/elseif` bug: only the first true flag among `found_rows, no_schema, compress, ignore_space, local_files, multi_statements, multi_results` was applied; `multi_statements` silently defaulted `true` in code | independent flags; **`multi_statements` default `false`**; `multi_results` is a no-op (always on) |
| `compress=true` | accepted | `ArgumentError` (compression is not implemented; planned for 2.x) |
| `local_files=true` | accepted without a handler | requires `local_infile_handler`, otherwise `ArgumentError` at connect; a server upload request without a configured handler is a `ProtocolError` |
| Unknown keywords | silently swallowed | `ArgumentError` |
| `ssl_mode` | #240: enum collision, `SSL_MODE_DISABLED` unimplementable | five real modes; default `:preferred`; explicit `ssl_mode` wins over `ssl_enforce`/`ssl_verify_server_cert`/CA-material escalation; contradictions are `ArgumentError`s; **no plaintext fallback after a failed TLS handshake** |
| `ssl_ca` + `ssl_capath` together | both applied | `ArgumentError` (Reseau has a single trust-root source); each alone works |
| `connect_timeout` | C socket timeout with platform-dependent meaning | one monotonic establishment deadline spanning dial, greeting, TLS, the whole auth exchange, and the charset bootstrap |
| `read_timeout` / `write_timeout` | `MYSQL_OPT_READ_TIMEOUT`/`MYSQL_OPT_WRITE_TIMEOUT`: per socket operation | same meaning: re-armed before every transport read/write, so a slowly-consumed streaming result never expires while the server keeps answering; expiry closes the connection |
| `reconnect` | C auto-reconnect | the same contract, made explicit: the command that hits a dead connection reports it (`MySQL.Error` 2006/2013), and the *next* command reconnects — only before a send, never mid-command, never inside a transaction; a reconnect that itself fails leaves the connection retryable, not closed |
| Connection loss | `API.Error` 2006 "server has gone away" / 2013 "lost connection during query" | the same `MySQL.Error` codes: 2006 when the server dropped the connection instead of answering, 2013 mid-response; a MySQL 8.0.24+ server that reaps an idle connection (`wait_timeout`) announces it, and that announcement is reported as `MySQL.Error` 4031; the connection is closed until `reconnect` or a new connect |
| `executemultiple` | first-OK result yielded nothing; later results mutated one cursor (stale `lookup`, aliased metadata) | every result (DML/OK included) is a **distinct cursor** with immutable metadata and its own OK snapshot; advancing past an unconsumed streaming result drains and invalidates it |
| `lastrowid` | read live connection/statement state (sticky) | snapshot from the cursor's own OK/terminator (a SELECT cursor reports 0) |
| DML cursor `length` | `-1` (the C client's sentinel; `collect` threw) | a result-less cursor has `length` 0 and iterates empty; **buffered SELECT cursors report the row count**; the outcome is in `rows_affected`/`lastrowid` |
| DATETIME/TIMESTAMP result type | `DateTime` (milliseconds): sub-millisecond values errored on the text protocol and were silently truncated on the binary one; `mysql_date_and_time=true` gave `DateAndTime`, whose text path read `DATETIME(1..5)` fractions as an unscaled microsecond count (`.4` → 4 µs) | `Timestamp{Second}` / `Timestamp{Millisecond}` / `Timestamp{Microsecond}` by the column's `fsp`; every digit is kept, nothing is truncated; `DateTime` parameters still bind, a `Timestamp{Nanosecond}` parameter with a sub-microsecond part raises `InexactError` |
| String and BLOB result types | `String` / `Vector{UInt8}` copies (one allocation per value; `TextRow` values could alias freed C memory, #206) | `DataString` / `DataBytes` views of the Julia-owned result buffer: no copy, no allocation per value, and the values stay valid after the row is gone; explicit `String`/`Vector{UInt8}` requests still copy |
| BIT decoding | text: first byte only; binary: little-endian | big-endian value of all bytes (≤ 8) in both protocols |
| BIT parameters | little-endian `bitvalue` encoding | big-endian binary string (matches the decode) |
| `Bool` parameters | fell through to the `MYSQL_TYPE_STRING` fallback (untested latent bug) | bound as `MYSQL_TYPE_TINY` |
| TIME decoding | text parse errored on negative/≥24 h; binary ignored sign and days | `Dates.Time` for `0 ≤ t < 24h`, `ConversionError` otherwise; `time_type=Dates.Microsecond` opt-in is lossless and signed |
| Zero dates | text special-cased only zero DATETIME; text zero DATE failed; binary mapped zero components to 1970 | unified `zero_dates` policy: `:sentinel` (default, `Date(0)` / `Timestamp{P}(0, 1, 1)`), `:missing` (widens column types to `Union{Missing, T}`), `:error`; partial zero dates (`2024-00-05`) are `ConversionError` unless `:missing` |
| `Base.isopen` | `mysql_ping` round trip | local check only; use `MySQL.ping(conn)` for a round trip |
| Errors | `API.Error`/`API.StmtError` with pointer-only constructors | `MySQL.Error`/`MySQL.StmtError` keep the same names, field names and types (`errno::Cuint`, `msg`) and `showerror` text, in a real hierarchy (`MySQLError` → `ServerError` → `Error`/`StmtError`, plus `ProtocolError`, `AuthError`, `TimeoutError`, `ConversionError`, …), with public constructors and a new `sqlstate` field |
| Buffered memory | unbounded | buffered results are bounded by `max_buffered_bytes` (default 256 MiB, per command across all retained result sets incl. row offsets/NULL masks/metadata); exceeding it is a `ProtocolError`. Streaming stays unbounded by default (`max_response_bytes=nothing`) |
| Transactions | lock not held | the connection lock is held across `DBInterface.transaction(f, conn)`: other tasks block until commit/rollback |
| Cleanup/finalizers | abandoned C handles depended on Connector/C lifetimes | explicit `close!` or a do-block remains the contract; a dropped connection only enqueues its transport for the timer reaper, and a dropped statement only parks its preallocated id for the next command. Finalizers do no protocol or transport I/O; explicit close, timer reaping, and parked statement close are exactly-once |
| Concurrent use | not thread-safe | connection operations are lock-serialized. One task must consume a streaming cursor; a command from another task drains the pending response and invalidates that cursor instead of overwriting its Julia-owned row bytes. A transaction owns the connection lock until commit or rollback |
| `MySQL.load` | one round trip per row; embedded backticks in identifiers were not escaped; `debug=true` logged row values | rows are inserted in multi-row batches (`batchsize=1000`, bounded by the packet size, `max_columns`, and the 65535-marker limit); doubles embedded identifier backticks; `debug=true` logs statements only; `debug=:values` logs row values |

## Deprecated (accepted with a warning; no effect)

- `data_truncation` (no C buffer truncation exists natively)
- `net_buffer_length` (buffer sizing is automatic)
- `secure_auth` (`mysql_old_password` is never supported; the option has no effect)
- `multi_results` (multiple result sets are always negotiated; the option has no effect)

## Removed (error explains the replacement)

- `charset_dir`; `charset_name` accepts only `"utf8mb4"`
- `connection_handler`, `plugin_dir` (no C plugins to load)
- `protocol=:memory` (shared memory transport)

## Temporarily unavailable (compatibility names are reserved)

- `ssl_cipher`, `ssl_crl`, `ssl_crlpath`, and `passphrase` need matching transport support
  in Reseau. MySQL.jl keeps these option names reserved and reports that they are not
  available in 2.0; it does not silently ignore recognized option-file forms, and the
  options are not declared permanently removed.
- `compress=true` needs a compressed-packet layer with its own sequence tracking,
  buffering, and resource limits. It is planned for a later 2.x release.

## Added

`ssl_mode` (five modes), `tls_version`, `ssl_server_name`, `get_server_public_key`,
`server_public_key`, `enable_cleartext_plugin`, `insecure_cleartext_auth`,
`can_handle_expired_passwords`, `local_infile_handler`, `max_local_infile_bytes`,
`zero_dates`, `time_type`, `read_env` (opt-in `MYSQL_TCP_PORT`; `MYSQL_PWD` is never
read), `max_buffered_bytes`, `max_response_bytes`, `max_columns`, `max_result_sets`,
`max_metadata_bytes`, `max_preauth_packet`, `max_auth_rounds`, `max_auth_bytes`,
`max_session_state_bytes`, `attrs` (connection attributes sent in the handshake),
`debug` (per-packet protocol debug logging), `MySQL.ping`, `MySQL.connection_id`,
`MySQL.server_version`, `MySQL.server_kind`, `MySQL.escape_identifier`,
`MySQL.send_long_data!`, `MySQL.reset_statement!`, `MySQL.DecimalResult`,
`MySQL.timestamp_type`, the re-exported `Timestamp`, and the `batchsize` keyword of
`MySQL.load`.

## Option value types (2.0)

Connection-option values are validated against closed type sets (this is also what makes
the client compilable with `juliac --trim=safe`): string options accept `String` or
`SubString{String}`; integer options accept the standard machine integer types or a decimal
string (the public `DBInterface.connect` method requires an integer or `nothing` for
`port`); boolean options accept `Bool`; `attrs` accepts `Vector{Pair{String, String}}`;
`zero_dates` accepts a `Symbol` or `String`; `time_type` accepts exactly `Dates.Time` or
`Dates.Microsecond`. Anything else raises an `ArgumentError` naming the option (1.x
silently accepted, coerced, or ignored some of these).

## Static compilation (`juliac --trim`)

MySQL.jl 2.0 compiles under `juliac --trim=safe`; `Pkg.test` includes a trim workload
(`test/mysql_trim_workload.jl`) that compiles and runs connect, text-protocol execute
(buffered and streaming), prepared statements, one-shot parameterized execute, `ping`, and
`escape` against a scripted in-process server. In a trimmed executable, consume rows with
the schema-typed accessor — `Tables.getcolumn(row, T, i, name)` — the same call
schema-aware sinks make. The runtime-schema conveniences (`Tables.columntable`, untyped
`row.name` access, `MySQL.load`) build columns from runtime `Type` values and are not
statically resolvable; use them from regular Julia. A custom `local_infile_handler` (and
the `IO` it returns) is dispatched dynamically and works in a trimmed binary only if its
methods were compiled in. The trim workload also exercises abandoned-connection reaping,
but leaves all connection deadlines disabled; it does not validate timeout behavior.
`connect_timeout` hangs in trimmed executables with Reseau ≤ 1.4.1 — its deadline-armed
dial parked on tasks a trimmed build never ran, fixed in
[Reseau #151](https://github.com/JuliaServices/Reseau.jl/pull/151).

## Security: what `ssl_mode=:preferred` does and does not give you

The default `ssl_mode=:preferred` matches libmysqlclient, the MySQL CLI, Connector/J,
MySqlConnector, and libpq. Its precise guarantees:

> `:preferred` provides confidentiality against **passive observers only**; it gives no
> protection against an active man-in-the-middle. Capability stripping by an active
> attacker removes the opportunistic encryption (the client then continues in plaintext,
> because the server appears not to support TLS). Full `caching_sha2_password` /
> `sha256_password` authentication over unverified TLS can disclose the password to an
> active MITM. Only `:verify_ca` and `:verify_identity` authenticate the server.

Hardening relative to Oracle's documented behavior: after a failed TLS handshake the
client never falls back to plaintext, SNI is sent for DNS host names in every TLS
mode, and supplying CA material escalates the default to `:verify_ca`. Cleartext
authentication (`mysql_clear_password`) additionally requires explicit enablement and
either `:verify_identity` or `insecure_cleartext_auth=true`.

## Not yet implemented (deferred)

Documented gaps, planned for later 2.x releases — attempting to use them raises a clear
error rather than misbehaving:

- **Unix sockets and Windows named pipes** (transport is TCP/TLS). Every host, including
  `"localhost"`, is dialed over TCP; asking for the local transport explicitly
  (`protocol=:socket`/`:pipe`, or `named_pipe=true` without `protocol=:tcp`) raises a clear error, and a `unix_socket`
  path (keyword or option file) is accepted but unused until the transport exists.
- **Compression** (`compress=true` is an `ArgumentError`), server cursors /
  `COM_STMT_FETCH`, query attributes, `COM_STMT_BULK_EXECUTE`
- MariaDB `client_ed25519` / PARSEC / `dialog` (PAM) authentication (`UnsupportedAuthError`)
- `MYSQL_TYPE_VECTOR` result columns (MySQL 9.x; its classic-protocol binary framing is
  not documented by the vendor sources in scope)
- OUT-parameter interpretation beyond prepared CALL result sets
- Pooling, cancellation, DSN parsing
- The external interop matrix (ProxySQL / TiDB / Vitess / Aurora) is deferred. It is not
  automated or claimed as validated for 2.0.
