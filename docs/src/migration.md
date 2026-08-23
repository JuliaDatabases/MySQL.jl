# Migrating to the native wire-protocol backend

MySQL.jl is replacing its MariaDB Connector/C backend with a **native wire-protocol
backend**: the MySQL client/server protocol implemented in Julia on top of
[Reseau](https://github.com/JuliaServices/Reseau.jl) transports (TCP and TLS). It is *not*
"pure Julia" — OpenSSL underpins TLS and the RSA password exchange, and DecFP provides
`Dec64` — but every `libmariadb` `ccall`, its dynamic plugin loading, and its C handle
lifetimes are gone, along with the crash classes they caused (issues #220, #236, #240,
#208, #206).

## Trying the preview (1.x)

During 1.x the native backend is the separate, opt-in connection type
`MySQL.Native.Connection`; `MySQL.Connection` continues to use Connector/C, and existing
code is unaffected:

```julia
conn = DBInterface.connect(MySQL.Native.Connection, host, user, passwd; db="mydb", port=3306)
DBInterface.execute(conn, "SELECT 1")
stmt = DBInterface.prepare(conn, "SELECT * FROM t WHERE id = ?")
DBInterface.execute(stmt, (17,))
```

Every DBInterface/Tables operation works the same way as on `MySQL.Connection`: `execute`
(text protocol), `prepare`/`execute` (binary protocol), `executemany`, `executemultiple`,
`transaction`, `MySQL.load`, buffered (`mysql_store_result=true`, the default) and
streaming result sets, and the `mysql_date_and_time` keyword.

At 2.0 the native implementation becomes `MySQL.Connection` and the C backend moves to the
maintained `release-1.x` branch — pin `MySQL = "1"` to stay on Connector/C.

## Unchanged (Preserve)

The observable 1.x surface is preserved unless a row below says otherwise, including:
positional `connect(MySQL.Connection, host, user, passwd)` (with the `mysql://` substring
strip), `passwd=nothing` vs `""`, option files (subset; see below), `init_command`,
`found_rows`/`no_schema`/`ignore_space` as independent flags, the result type mapping
(`MySQL.juliatype`) exactly as 1.6.0 computes it, driver-keyword dispatch on `execute`
(SQL parameters still cannot be passed as keywords), `executemany`, the `wrongrow`
contract ("a row is only valid while it is the cursor's current row", same
`ArgumentError`), `rows_affected::Int64` bitcast semantics, cursor `close!`/`close`
idempotence, `Base.show(conn)`, `MySQL.escape`, and the `MySQL.API` value types (`Bit`,
`DateAndTime`, `MYSQL_TYPE_*`/`CLIENT_*` constants, `juliatype`, `mysqltype`).

## Behavior changes (Fix)

Deliberate, documented changes relative to Connector/C 1.6.0:

| Area | 1.6.0 (Connector/C) | Native backend |
|---|---|---|
| Client flags | `if/elseif` bug: only the first true flag among `found_rows, no_schema, compress, ignore_space, local_files, multi_statements, multi_results` was applied; `multi_statements` silently defaulted `true` in code | independent flags; **`multi_statements` default `false`**; `multi_results` is a no-op (always on) |
| `compress=true` | accepted | `ArgumentError` (compression is not implemented; planned for 2.x) |
| `local_files=true` | accepted without a handler | requires `local_infile_handler`, otherwise `ArgumentError` at connect; a server upload request without a configured handler is a `ProtocolError` |
| Unknown keywords | silently swallowed | `ArgumentError` |
| `ssl_mode` | #240: enum collision, `SSL_MODE_DISABLED` unimplementable | five real modes; default `:preferred`; explicit `ssl_mode` wins over `ssl_enforce`/`ssl_verify_server_cert`/CA-material escalation; contradictions are `ArgumentError`s; **no plaintext fallback after a failed TLS handshake** |
| `ssl_ca` + `ssl_capath` together | both applied | `ArgumentError` (Reseau has a single trust-root source); each alone works |
| `connect_timeout` | C socket timeout with platform-dependent meaning | one monotonic establishment deadline spanning dial, greeting, TLS, the whole auth exchange, and the charset bootstrap |
| `reconnect` | C auto-reconnect | narrow: only before a send on a transport known closed; never mid-command, never in a transaction, never after a protocol fault |
| `executemultiple` | first-OK result yielded nothing; later results mutated one cursor (stale `lookup`, aliased metadata) | every result (DML/OK included) is a **distinct cursor** with immutable metadata and its own OK snapshot; advancing past an unconsumed streaming result drains and invalidates it |
| `lastrowid` | read live connection/statement state (sticky) | snapshot from the cursor's own OK/terminator (a SELECT cursor reports 0) |
| DML cursor `length` | `-1` surprises | DML cursors keep the `-1` sentinel; **buffered SELECT cursors report the row count** |
| BIT decoding | text: first byte only; binary: little-endian | big-endian value of all bytes (≤ 8) in both protocols |
| TIME decoding | text parse errored on negative/≥24 h; binary ignored sign and days | `Dates.Time` for `0 ≤ t < 24h`, `ConversionError` otherwise; `time_type=Dates.Microsecond` opt-in is lossless and signed |
| Zero dates | text special-cased only zero DATETIME; text zero DATE failed; binary mapped zero components to 1970 | unified `zero_dates` policy: `:sentinel` (default, `Date(0)`/`DateTime(0)`), `:missing` (widens column types to `Union{Missing, T}`), `:error`; partial zero dates (`2024-00-05`) are `ConversionError` unless `:missing` |
| `Base.isopen` | `mysql_ping` round trip | local check only; use `MySQL.Native.ping(conn)` for a round trip |
| Errors | `API.Error`/`API.StmtError` with pointer-only constructors | same names/field types (`errno::Cuint`, `msg`) in a real hierarchy (`MySQLError` → `ServerError` → `Error`/`StmtError`, plus `ProtocolError`, `AuthError`, `TimeoutError`, `ConversionError`, …), public constructors, and a new `sqlstate` field |
| Buffered memory | unbounded | buffered results are bounded by `max_buffered_bytes` (default 256 MiB, per command across all retained result sets incl. row offsets/NULL masks/metadata); exceeding it is a `ProtocolError`. Streaming stays unbounded by default (`max_response_bytes=nothing`) |
| Transactions | lock not held | the connection lock is held across `DBInterface.transaction(f, conn)`: other tasks block until commit/rollback |
| Cleanup/finalizers | abandoned C handles depended on Connector/C lifetimes | explicit `close!` or a do-block remains the contract; a dropped native connection only enqueues its transport for the timer reaper, and a dropped statement only parks its preallocated id for the next command. Finalizers do no protocol or transport I/O; explicit close, timer reaping, and parked statement close are exactly-once |
| Concurrent use | not thread-safe | connection operations are lock-serialized. One task must consume a streaming cursor; a command from another task drains the pending response and invalidates that cursor instead of overwriting its Julia-owned row bytes. A transaction owns the connection lock until commit or rollback |
| `MySQL.load(...; debug=true)` | logged every row | statements only; `debug=:values` logs rows; `quoteid` doubles embedded backticks |
| `Bool` parameters | fell through to the `MYSQL_TYPE_STRING` fallback (untested latent bug) | bound as `MYSQL_TYPE_TINY` |
| Value lifetime (#206) | `TextRow` values could alias freed C memory | rows decode from Julia-owned, cursor-owned buffers |

## Deprecated (warning in 1.x preview, `ArgumentError` in 2.0)

- `data_truncation` (no C buffer truncation exists natively)
- `net_buffer_length`

## Removed (error explains the replacement)

- `charset_dir`; `charset_name` accepts only `"utf8mb4"`
- `ssl_cipher`, `ssl_crl`, `ssl_crlpath`, `passphrase` (no Reseau support)
- `connection_handler`, `plugin_dir` (no C plugins to load)
- `protocol=:memory` (shared memory transport)
- `MySQL.API` handle types, raw `ccall` wrappers, `setoptions!`/`getoption`

## Added

`ssl_mode` (five modes), `tls_version`, `ssl_server_name`, `get_server_public_key`,
`server_public_key`, `enable_cleartext_plugin`, `insecure_cleartext_auth`,
`can_handle_expired_passwords`, `local_infile_handler`, `max_local_infile_bytes`,
`zero_dates`, `time_type`, `read_env` (opt-in `MYSQL_TCP_PORT`; `MYSQL_PWD` is never
read), `max_buffered_bytes`, `max_response_bytes`, `max_columns`, `max_result_sets`,
`max_metadata_bytes`, `MySQL.Native.ping`, `MySQL.Native.escape_identifier`,
`MySQL.Native.send_long_data!`, `MySQL.Native.reset_statement!`, and the do-block form
`DBInterface.connect(f, …)`.

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
native backend never falls back to plaintext, SNI is sent for DNS host names in every TLS
mode, and supplying CA material escalates the default to `:verify_ca`. Cleartext
authentication (`mysql_clear_password`) additionally requires explicit enablement and
either `:verify_identity` or `insecure_cleartext_auth=true`.

## Not yet implemented (deferred)

Documented gaps of the preview, planned for later milestones — attempting to use them
raises a clear error rather than misbehaving:

- **Unix sockets and Windows named pipes** (transport is TCP/TLS in the preview; the
  Windows named-pipe CI lane needs a Windows runner and is part of the 2.0 promotion gate)
- **Compression** (`compress=true` is an `ArgumentError`), server cursors /
  `COM_STMT_FETCH`, query attributes, `COM_STMT_BULK_EXECUTE`
- MariaDB `client_ed25519` / PARSEC / `dialog` (PAM) authentication (`UnsupportedAuthError`)
- `MYSQL_TYPE_VECTOR` result columns (MySQL 9.x; its classic-protocol binary framing is
  not documented by the vendor sources in scope)
- OUT-parameter interpretation beyond prepared CALL result sets
- Pooling, cancellation, DSN parsing (2.x roadmap, both backends)
- The external interop matrix (ProxySQL / TiDB / Vitess / Aurora) runs as a separate
  nightly lane and a manual checklist, not in `Pkg.test`
