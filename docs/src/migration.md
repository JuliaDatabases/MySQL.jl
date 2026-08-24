# Migrating from 1.x to 2.0

MySQL.jl 2.0 replaces the MariaDB Connector/C backend with a **native wire-protocol
implementation**: the MySQL client/server protocol written in Julia on top of
[Reseau](https://github.com/JuliaServices/Reseau.jl) transports (TCP and TLS). It is *not*
"pure Julia" — OpenSSL underpins TLS and the RSA password exchange, and DecFP provides
`Dec64` — but every `libmariadb` `ccall`, its dynamic plugin loading, and its C handle
lifetimes are gone, along with the crash classes they caused (issues #220, #236, #240,
#208, #206).

`MySQL.Connection` is now the native connection. Most code — `DBInterface.connect` /
`execute` / `prepare` / `executemany` / `executemultiple` / `transaction`, Tables.jl
cursors, `MySQL.load`, buffered (`mysql_store_result=true`, the default) and streaming
result sets, `mysql_date_and_time` — works unchanged. Pin `MySQL = "1"` to stay on
Connector/C (the `release-1.x` branch).

## Upgrade checklist

1. **Errors**: replace `MySQL.API.Error` / `MySQL.API.StmtError` with `MySQL.Error` /
   `MySQL.StmtError` (same field names/types plus a new `sqlstate`), or catch the root
   `MySQL.MySQLError`.
2. **Value types**: replace `MySQL.API.Bit` with `MySQL.Bit`. `MySQL.DateAndTime` and
   `MySQL.juliatype` are unchanged.
3. **Multi-statements**: pass `multi_statements=true` if you relied on 1.x accepting
   `"stmt1; stmt2"` by default (an `if/elseif` bug made 1.x enable it silently).
4. **Enum-valued options**: pass Symbols — `ssl_mode=:required` (was
   `MySQL.API.SSL_MODE_REQUIRED`), `protocol=:tcp` (was `MySQL.API.MYSQL_PROTOCOL_TCP`).
5. **Local servers**: the Unix-socket / named-pipe transport is not implemented yet, and an
   empty host or `"localhost"` on Unix (`"."` on Windows) selects it, as in 1.x. Connecting
   to a local server over TCP therefore needs `protocol=:tcp` (or `host="127.0.0.1"`).
6. **Unknown/removed keywords now error** with an explanation instead of being silently
   swallowed — fix the call sites the errors point at.

## The `MySQL.API` module is gone

1.x names and their 2.0 replacements:

| 1.x | 2.0 |
|---|---|
| `MySQL.API.Error`, `MySQL.API.StmtError` | `MySQL.Error`, `MySQL.StmtError` (aliases of `MySQL.Protocol.Error`/`StmtError`; same `errno::Cuint`/`msg` fields and `showerror` text, plus `sqlstate`); root type `MySQL.MySQLError` |
| `MySQL.API.Bit` | `MySQL.Bit` (same `bits::UInt64` field) |
| `MySQL.DateAndTime` (`MySQL.API.DateAndTime`) | `MySQL.DateAndTime` (unchanged) |
| `MySQL.API.juliatype` / `MySQL.juliatype` | `MySQL.juliatype` (unchanged mapping) |
| `MySQL.API.MYSQL_TYPE_*` constants | `MySQL.Protocol.MYSQL_TYPE_*` (wire-value `UInt8`s) |
| `MySQL.API.SSL_MODE_*`, `MySQL.API.MYSQL_PROTOCOL_*` enums | Symbols: `ssl_mode=:disabled/:preferred/:required/:verify_ca/:verify_identity`, `protocol=:default/:tcp/:socket/:pipe` |
| `MySQL.API.mysqltype` | removed (parameter types are inferred from Julia values when binding) |
| `MySQL.API` handle types (`MYSQL`, `MYSQL_STMT`, `MYSQL_RES`, `MYSQL_BIND`), raw `ccall` wrappers, `MySQL.setoptions!`/`API.getoption` | removed — there are no C handles |

Cursor/row types: `MySQL.Cursor{binary, buffered}` with aliases `MySQL.TextCursor`
(`DBInterface.execute(conn, sql)`) and `MySQL.BinaryCursor` (prepared execution);
row types `MySQL.TextRow` and `MySQL.BinaryRow` (1.x: `MySQL.TextRow` and `MySQL.Row`).

## Additional 2.0 breaks (beyond the behavior table)

- **`mysql://` stripping**: only a *leading* `mysql://` prefix on the host is stripped;
  1.x stripped everything up to a `mysql://` substring found anywhere in the host.
- **`port=0`** now means the default port (3306); in 1.x it meant "take the port from the
  option file". Omit `port` (or pass `nothing`) to fall back to option files.
- **`conn.port`** is an `Int` (was a `String`), and `Base.show` prints it unquoted.
- **`MySQL.Native`** (the 1.7 preview namespace) is gone; everything it exported lives at
  the top level: `MySQL.ping`, `MySQL.escape`, `MySQL.escape_identifier`,
  `MySQL.send_long_data!`, `MySQL.reset_statement!`, `MySQL.ConnectOptions`.
- **`MySQL.load`** `debug` keyword accepts `false`/`true`/`:values`; `debug=true` logs
  generated statements only, `debug=:values` also logs row values (1.x `debug=true`
  logged values).

## Unchanged (Preserve)

The observable 1.x surface is preserved unless a row below says otherwise, including:
positional `connect(MySQL.Connection, host, user, passwd)`, `passwd=nothing` vs `""`,
option files (subset; unsupported directives fail closed), `init_command`,
`found_rows`/`no_schema`/`ignore_space` as independent flags, the result type mapping
(`MySQL.juliatype`) exactly as 1.6.0 computes it, driver-keyword dispatch on `execute`
(SQL parameters still cannot be passed as keywords), `executemany`, the `wrongrow`
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
| `reconnect` | C auto-reconnect | narrow: only before a send on a transport known closed; never mid-command, never in a transaction, never after a protocol fault; a reconnect that itself fails leaves the connection retryable, not closed |
| `executemultiple` | first-OK result yielded nothing; later results mutated one cursor (stale `lookup`, aliased metadata) | every result (DML/OK included) is a **distinct cursor** with immutable metadata and its own OK snapshot; advancing past an unconsumed streaming result drains and invalidates it |
| `lastrowid` | read live connection/statement state (sticky) | snapshot from the cursor's own OK/terminator (a SELECT cursor reports 0) |
| DML cursor `length` | `-1` surprises | DML cursors keep the `-1` sentinel; **buffered SELECT cursors report the row count** |
| Sub-millisecond DATETIME | text errored; binary truncated silently | text warns then raises `ConversionError`; binary (prepared) warns then truncates to milliseconds — each preserves its 1.x protocol behavior (both mirror `MYSQL_TIME`) |
| BIT decoding | text: first byte only; binary: little-endian | big-endian value of all bytes (≤ 8) in both protocols |
| BIT parameters | little-endian `bitvalue` encoding | big-endian binary string (matches the decode) |
| `Bool` parameters | fell through to the `MYSQL_TYPE_STRING` fallback (untested latent bug) | bound as `MYSQL_TYPE_TINY` |
| TIME decoding | text parse errored on negative/≥24 h; binary ignored sign and days | `Dates.Time` for `0 ≤ t < 24h`, `ConversionError` otherwise; `time_type=Dates.Microsecond` opt-in is lossless and signed |
| Zero dates | text special-cased only zero DATETIME; text zero DATE failed; binary mapped zero components to 1970 | unified `zero_dates` policy: `:sentinel` (default, `Date(0)`/`DateTime(0)`), `:missing` (widens column types to `Union{Missing, T}`), `:error`; partial zero dates (`2024-00-05`) are `ConversionError` unless `:missing` |
| `Base.isopen` | `mysql_ping` round trip | local check only; use `MySQL.ping(conn)` for a round trip |
| Errors | `API.Error`/`API.StmtError` with pointer-only constructors | `MySQL.Error`/`MySQL.StmtError` keep the same names, field names and types (`errno::Cuint`, `msg`) and `showerror` text, in a real hierarchy (`MySQLError` → `ServerError` → `Error`/`StmtError`, plus `ProtocolError`, `AuthError`, `TimeoutError`, `ConversionError`, …), with public constructors and a new `sqlstate` field |
| Buffered memory | unbounded | buffered results are bounded by `max_buffered_bytes` (default 256 MiB, per command across all retained result sets incl. row offsets/NULL masks/metadata); exceeding it is a `ProtocolError`. Streaming stays unbounded by default (`max_response_bytes=nothing`) |
| Transactions | lock not held | the connection lock is held across `DBInterface.transaction(f, conn)`: other tasks block until commit/rollback |
| Cleanup/finalizers | abandoned C handles depended on Connector/C lifetimes | explicit `close!` or a do-block remains the contract; a dropped connection only enqueues its transport for the timer reaper, and a dropped statement only parks its preallocated id for the next command. Finalizers do no protocol or transport I/O; explicit close, timer reaping, and parked statement close are exactly-once |
| Concurrent use | not thread-safe | connection operations are lock-serialized. One task must consume a streaming cursor; a command from another task drains the pending response and invalidates that cursor instead of overwriting its Julia-owned row bytes. A transaction owns the connection lock until commit or rollback |
| `MySQL.load` | embedded backticks in identifiers were not escaped; `debug=true` logged row values | doubles embedded identifier backticks; `debug=true` logs statements only; `debug=:values` logs row values |
| Value lifetime (#206) | `TextRow` values could alias freed C memory | rows decode from Julia-owned, cursor-owned buffers |

## Deprecated (accepted with a warning; no effect)

- `data_truncation` (no C buffer truncation exists natively)
- `net_buffer_length` (buffer sizing is automatic)
- `secure_auth` (`mysql_old_password` is never supported; the option has no effect)
- `multi_results` (multiple result sets are always negotiated; the option has no effect)

## Removed (error explains the replacement)

- `charset_dir`; `charset_name` accepts only `"utf8mb4"`
- `ssl_cipher`, `ssl_crl`, `ssl_crlpath`, `passphrase` (no Reseau support)
- `connection_handler`, `plugin_dir` (no C plugins to load)
- `protocol=:memory` (shared memory transport)

## Added

`ssl_mode` (five modes), `tls_version`, `ssl_server_name`, `get_server_public_key`,
`server_public_key`, `enable_cleartext_plugin`, `insecure_cleartext_auth`,
`can_handle_expired_passwords`, `local_infile_handler`, `max_local_infile_bytes`,
`zero_dates`, `time_type`, `read_env` (opt-in `MYSQL_TCP_PORT`; `MYSQL_PWD` is never
read), `max_buffered_bytes`, `max_response_bytes`, `max_columns`, `max_result_sets`,
`max_metadata_bytes`, `MySQL.ping`, `MySQL.escape_identifier`,
`MySQL.send_long_data!`, `MySQL.reset_statement!`.

## Option value types (2.0)

Connection-option values are validated against closed type sets (this is also what makes
the client compilable with `juliac --trim=safe`): string options accept `String` or
`SubString{String}`; integer options accept the standard machine integer types or a decimal
string; boolean options accept `Bool`; `attrs` accepts `Vector{Pair{String, String}}`;
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
methods were compiled in. Avoid `connect_timeout`/`read_timeout`/`write_timeout` in trimmed
executables for now: Reseau's deadline-armed waits depend on timer machinery that a trimmed
build does not currently carry.

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

- **Unix sockets and Windows named pipes** (transport is TCP/TLS). As in 1.x, an empty
  host or `"localhost"` on Unix (and `"."` on Windows) selects the local transport;
  because that transport is deferred, connect raises a clear error instead of silently
  using TCP — pass `protocol=:tcp` to force a TCP connection to a local server.
- **Compression** (`compress=true` is an `ArgumentError`), server cursors /
  `COM_STMT_FETCH`, query attributes, `COM_STMT_BULK_EXECUTE`
- MariaDB `client_ed25519` / PARSEC / `dialog` (PAM) authentication (`UnsupportedAuthError`)
- `MYSQL_TYPE_VECTOR` result columns (MySQL 9.x; its classic-protocol binary framing is
  not documented by the vendor sources in scope)
- OUT-parameter interpretation beyond prepared CALL result sets
- Pooling, cancellation, DSN parsing
- The external interop matrix (ProxySQL / TiDB / Vitess / Aurora) runs as a separate
  nightly lane and a manual checklist, not in `Pkg.test`
