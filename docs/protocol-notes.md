# Native wire-protocol backend: protocol notes and clean-room log

This file accompanies `src/Protocol/`. It records where every byte-level fact came from,
the places where the vendor documents disagree, and every consultation of a third-party
implementation (none so far). The plan that drives this work is
`~/.julia/dev/MySQL-native-protocol-plan.md` (not part of the repository).

## Sources of truth (in priority order)

1. Live lanes: `test/protocol/live_tests.jl` exercises the native backend against Harbor
   containers (`MYSQL_NATIVE_IMAGES`, default `mysql:8.4,mariadb:11.4`) — authentication
   plugin exchanges, TLS, charset bootstrap, ping/init_db/quit — and runs the executable
   compatibility manifest (`test/compat_manifest.jl`) on both backends side by side.
2. Server public headers, **numeric values only**: `include/my_command.h`,
   `include/mysql_com.h`, `include/field_types.h` from the `mysql-server` trunk.
   `scripts/gen_constants.jl` regenerates `src/Protocol/constants_generated.jl` and stamps
   the SHA-256 of the inputs.
3. Oracle "MySQL Source Code Documentation" protocol pages
   (`https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_*.html`, labelled
   MySQL 26.7.0) and the MariaDB KB protocol pages (CC BY-SA / GFDL).
4. RFCs for the cryptography used in later milestones (RFC 8017 OAEP, RFC 8032 Ed25519,
   RFC 8018 PBKDF2); TLS is delegated to Reseau.

Permissively licensed implementations (PyMySQL, MySqlConnector, mysql2, go-mysql, Vitess;
`go-sql-driver/mysql` for behavior only) may be consulted to resolve an ambiguity; each
consultation must be logged below as *question → answer → source*. GPL client code
(libmysqlclient, Connector/J, Connector/NET, MariaDB server plugins) and LGPL libmariadb
source are never read.

## Documented vendor defects and conflicts (do not "fix" silently)

| Topic | Oracle page | MariaDB page / server header | Decision |
|---|---|---|---|
| `COM_SET_OPTION` byte and response | `page_protocol_com_set_option` says `[0x1A]` and documents OK on success | `my_command.h`: `COM_STMT_RESET = 26`, `COM_SET_OPTION = 27`; KB `com_set_option`: `0x1B` and EOF on success | send `0x1B`; accept either OK or EOF for this command only; current MySQL 8.4 and MariaDB 11.4 send the seven-byte `0xFE`-headed OK shape under `CLIENT_DEPRECATE_EOF`, while the legacy EOF is exactly one or five bytes; `constants.jl` asserts the command byte at load time |
| Compression activation point | "after successful authentication" (capabilities page) | "activated after the handshake-response-packet" (KB `0-packet`) | compression is not implemented; capture-gated |
| SQLSTATE in a pre-capability ERR | connection-phase page: the first ERR "will not contain the SQL-state" | KB ERR description uses the `#` heuristic | whole remainder kept as the message, `sqlstate = ""` (`parse_initial_err`); revisit with captures |
| `0xFE` in row state | "check whether the packet length is less than 9" (EOF page) | "packet length is less than 0xFFFFFF" (KB result-set packets) | MariaDB rule on the *first chunk length* (`is_row_terminator`): an OK-as-EOF under DEPRECATE_EOF can exceed 9 bytes, a row starting with an 8-byte lenenc is ≥ 2^24 bytes |
| `enum_field_types` location | — | moved from `mysql_com.h` to `field_types.h` | generator reads both |

## Phase-dependent meaning of first bytes

| Byte | Greeting | Auth | Command response | Text row state | Binary row state |
|---|---|---|---|---|---|
| `0x00` | — | OK | OK (or PREPARE_OK) | row (empty first value) | **row header** |
| `0x01` | — | AuthMoreData (MySQL) / plugin data (MariaDB) | column count 1 | row | invalid |
| `0x02` | — | AuthNextFactor (MySQL, unsupported) / plugin data (MariaDB) | column count 2 | row | invalid |
| `0x0A` | HandshakeV10 | — | column count 10 | row | invalid |
| `0xFB` | — | plugin data (MariaDB) | LOCAL INFILE request (COM_QUERY only, and only if negotiated) | NULL first column | invalid |
| `0xFE` | — | AuthSwitchRequest (len > 1) / old switch (len 1, unsupported) | invalid | terminator iff first chunk < 0xFFFFFF, else row | same |
| `0xFF` | pre-capability ERR | ERR (session closed) | ERR (session stays usable) | ERR (result ends, session usable) | same |

## M1 decisions worth remembering

- One shared sequence counter per session (`PacketIO.seq`); the client continues the
  server's counter during the connection phase and across STARTTLS, and resets it to 0 for
  every command; no-response commands (`COM_STMT_CLOSE`, `COM_STMT_SEND_LONG_DATA`,
  `COM_QUIT`) reset it too but never read.
- Every declared length is checked against `Limits` **before** the buffer grows; the
  reassembled packet keeps `nchunks`/`first_chunk_len` so the terminator rule can use the
  physical framing.
- Any I/O or parse failure moves the session to `BROKEN` and closes the transport
  (`fault!`); a server ERR never does (phase returns to `READY` or, during auth, `CLOSED`).
- `TRANSITIONS` in `phases.jl` is the contract; the test suite asserts every row is
  exercised (`uncovered_transitions()` must be empty).
- No `Sockets` dependency: Unix sockets and named pipes are deferred; the transport union is
  `Reseau.TCP.Conn | Reseau.TLS.Conn | FaultTransport` (the last is test-only fault injection).
- Authentication plugin exchanges, TLS orchestration, and value decoding are later
  milestones; M1 only frames them (`read_auth_packet!`, `send_ssl_request!`,
  `replace_transport!`, raw `PacketView` rows).

## M2 decisions worth remembering

- **Transport security is a per-plugin, per-step rule** (`auth.jl` header table): the
  caching_sha2/sha256 full-auth cleartext step needs TLS (any mode); over plain TCP the RSA
  password exchange is used only when the caller opts in (`server_public_key` PEM or
  `get_server_public_key=true`), otherwise `AuthError`. `mysql_clear_password` needs explicit
  enablement *and* either `ssl_mode=:verify_identity` or `insecure_cleartext_auth=true`;
  `:preferred`/`:required` TLS is not enough because an active MITM can terminate it.
- **`ssl_mode` defaults to `:preferred` and never falls back**: a server without `CLIENT_SSL`
  stays plaintext, but once SSLRequest is sent a failed handshake faults the session.
  `ssl_ca`/`ssl_capath` alone escalate the *default* to `:verify_ca`; `ssl_verify_server_cert=true`
  to `:verify_identity`; `ssl_enforce=true` to `:required`. An explicit `ssl_mode` wins and
  contradicting flags (`:disabled` + `ssl_enforce=true`, `:required` + verify) are errors.
  `ssl_ca` and `ssl_capath` cannot be combined (Reseau takes one trust root).
- **SNI**: a DNS host name is always sent; an IP literal is passed to Reseau only under
  `:verify_ca`/`:verify_identity` (it needs the name to match the IP SAN). `ssl_server_name`
  overrides the verification/SNI name (SNI-routed deployments).
- **One establishment deadline** (`connect_timeout`): dial, greeting, TLS handshake, the
  whole authentication exchange and the utf8mb4 bootstrap share one absolute deadline
  (`apply_deadline!` on the TCP conn, re-applied on the TLS conn after STARTTLS); it is
  cleared once the session is `READY`. `read_timeout` applies per command (`init_command`).
- **utf8mb4 bootstrap contract**: `SET NAMES utf8mb4` is skipped only when the connect OK's
  session tracking reports `character_set_client/connection/results = utf8mb4`; otherwise it
  is sent and must return OK. MariaDB 11 and MySQL 8.4 report the variables only when they
  change, so the statement is usually sent once.
- **Finalizers never do I/O**: a dropped `Native.Handle` enqueues its `ReapEntry` (CAS
  `:live → :pending`); the reaper (0.5 s timer, `reap_now!`, `atexit`) removes entries under
  `REAPER_LOCK`, then closes each transport after releasing the lock. `close!` retires the
  entry first so a later finalizer is a no-op. Reseau's own poll-FD finalizer is the
  last-resort fd reclaimer.
- **RSA-OAEP through OpenSSL_jll's libcrypto** (`crypto.jl`): explicit SHA-1 OAEP + MGF1,
  `k - 42` plaintext cap, every handle freed in `finally`, 20k-iteration leak test. The
  masked plaintext and password copies are zeroed (`securezero!` = `OPENSSL_cleanse`).
- **TLS 1.3 post-handshake failures**: a TLS 1.3 server may reject the session (e.g. alert
  116 certificate_required) on the first record *after* the handshake; before authentication
  `fault!` reports that as `TLSNegotiationError`, afterwards as `ProtocolError`.
- **Upstream fix required (Reseau 1.4.0)**: Reseau's mixed-version client driver
  (`_native_tls_auto_client_handshake!`, used whenever both TLS 1.2 and 1.3 are allowed —
  the default) did not load the client identity into its TLS 1.3 state, so mutual TLS on
  TLS 1.3 sent an empty Certificate; found by the `ssl_mode` matrix here and fixed in
  https://github.com/JuliaServices/Reseau.jl/pull/150. `tls_tests.jl` runs the unpinned
  ("auto") mTLS case as a regular test, so the suite needs a Reseau that includes that fix
  (`tls_version="TLSv1.3"`/`"TLSv1.2"` pins select the exact-version drivers either way).
- Live-lane facts: both `mysql:8.4` and `mariadb:11.4` images auto-generate a self-signed
  server certificate, so `:preferred` lands on TLS and `:verify_ca` with a foreign CA is
  refused; MySQL 8.4 needs `--mysql-native-password=ON` to create native-password accounts
  and announces `caching_sha2_password` (auth switch for native accounts); MariaDB 11.4
  root uses `mysql_native_password` directly.
- Option files: `[client]` plus `option_group`, `!include`/`!includedir`/`?includedir` rejected (explicit
  error), world-writable files skipped with a warning, `.mylogin.cnf` skipped with a warning
  (obfuscated format; out of scope); `read_env=true` reads `MYSQL_TCP_PORT` only
  (`MYSQL_PWD` is deliberately ignored). Keywords beat files; a named group beats `[client]`.

## M3 decisions worth remembering

- **Type mapping is the 1.x mapping by construction**: `Native.juliatype` calls
  `MySQL.juliatype` with the wire type and flags. One wire fact feeds it: the server never
  sends `NUM_FLAG` (libmysqlclient synthesizes it client-side for `IS_NUM` types), so
  `Protocol.is_unsigned` derives numeric-ness from the wire type — otherwise
  `BIGINT UNSIGNED`/`YEAR` would decode as signed.
- **Rows are valid only while current** (`wrongrow`, same `ArgumentError` text as 1.x): every
  yielded row, outer-result advance, and explicit cursor close bumps the cursor's `epoch`;
  each `TextRow` carries the epoch it was issued under. Streaming cursors additionally own
  the connection's in-flight response through a per-result
  atomic `active_token` plus the connection `generation`; a foreign command drains the
  response and the cursor's rows raise `ProtocolError("cursor invalidated …")`. Buffered
  cursors own their bytes and survive later commands.
- **Cursor-owned buffers**: streaming packets alternate between two cursor-owned buffers so
  a terminator cannot overwrite the last current row; buffered results use one contiguous
  buffer plus row offsets. The per-command `max_buffered_bytes` budget is charged across
  every retained result of the command (multi-results included) and exceeding it faults the
  session.
- **Multi-results**: `executemultiple` yields a distinct cursor per result (DML/OK results
  and CALL's final OK yield empty cursors with their own snapshot); advancing past an
  unconsumed streaming result drains it and stales its rows; a later ERR ends iteration with
  `Error`; whatever a plain `execute` left unread is drained by the next operation.
- **Snapshots**: `rows_affected` is the preserved `Int64` bitcast; `lastrowid` comes from the
  cursor's own OK/terminator (a SELECT cursor reports 0 under DEPRECATE_EOF, where 1.x
  reported the connection's sticky value); status and warning counts are retained for both
  OK and legacy EOF terminators; a DML cursor keeps the 1.x `length == -1` sentinel.
- **Decoding policies** (`ResultOptions`): BIT is the big-endian value of all bytes (1.x read
  the first byte only); TIME decodes to `Dates.Time` for `0 ≤ t < 24h` and raises
  `ConversionError` otherwise, `time_type=Dates.Microsecond` is lossless; `zero_dates`
  (`:sentinel` default → `Date(0)`/`DateTime(0)`, `:missing` → `missing` and every date
  column typed `Union{Missing,T}`, `:error`); partial zero dates are errors unless
  `:missing`; DATETIME values with sub-millisecond digits warn and truncate (1.x warned,
  then failed). `DateAndTime` scales one-to-six fractional digits to microseconds (1.x
  treated the digits as an unscaled microsecond count, which was correct only at precision 6).
- **LOCAL INFILE** follows the plan's state table: refusal (`nothing`) always raises
  `LocalInfileRefused` even when the server accepts the empty upload; a handler error before
  any data (including the source's first read) is re-raised after resynchronizing; an error,
  size-limit crossing or write fault after data closes the connection; an unsolicited `0xFB`
  is a `ProtocolError`. Later results of the same COM_QUERY can request another upload.
- **Reconnect** is narrow: only before a send, only when the transport is known closed,
  never from `BROKEN` and never inside a transaction; it bumps the generation so older cursors invalidate.
  `transaction` holds the connection lock across `f`.
- Handle-level facts from the 8.4 lane: the terminator OK of a SELECT carries
  `last_insert_id = 0`; mariadb:11.4 and mysql:8.4 both serve the fixture identically.

## Third-party consultations

None.
