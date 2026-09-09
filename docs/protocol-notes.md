# Native wire-protocol backend: protocol notes and clean-room log

This file accompanies `src/Protocol/`. It records where every byte-level fact came from,
the places where the vendor documents disagree, and every consultation of a third-party
implementation (including the review-policy exception logged below). Section numbers of the form §N.M refer to the internal
design plan that drove the rewrite; the ones that gate CI are: §8.4 = fuzzing, §8.9 =
per-row performance/allocation gates (allocations per row ≤ String/Vector columns + 1),
§8.10 = leak/lifecycle soak, §4.2 = the 1.x behavior table now in
`docs/src/migration.md` and `test/behavior_manifest.jl`.

## Sources of truth (in priority order)

1. Live lanes: `test/protocol/live_tests.jl` exercises the native backend against Harbor
   containers (`MYSQL_NATIVE_IMAGES`, default `mysql:8.4,mariadb:11.4`) — authentication
   plugin exchanges, TLS, charset bootstrap, ping/init_db/quit — and runs the executable
   behavior manifest (`test/behavior_manifest.jl`) as a native-only golden suite (goldens
   captured from the pre-2.0 dual-backend runs).
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

## Framing and phase machine (M1): decisions worth remembering

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

## TLS and authentication (M2): decisions worth remembering

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
  cleared once the session is `READY`. After that, `read_timeout` and `write_timeout` are
  re-armed before every transport read and write, including `init_command`.
- **utf8mb4 bootstrap contract**: `SET NAMES utf8mb4` is skipped only when the connect OK's
  session tracking reports `character_set_client/connection/results = utf8mb4`; otherwise it
  is sent and must return OK. MariaDB 11 and MySQL 8.4 report the variables only when they
  change, so the statement is usually sent once.
- **Finalizers never do I/O**: a dropped `MySQL.Handle` enqueues its `ReapEntry` (CAS
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
- **Upstream fix required (Reseau 1.4.1)**: Reseau's mixed-version client driver
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
  (`MYSQL_PWD` is deliberately ignored). Keywords beat files; selected groups are read in
  file order and the last value wins (checked with MySQL 8.4 `my_print_defaults`). Missing
  explicit files fail; missing default locations are skipped.

## Text protocol and cursors (M3): decisions worth remembering

- **Type mapping is the 1.x mapping by construction**: the column-decode layer (`src/decode.jl`) calls
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
  `Error` for text commands and `StmtError` for prepared commands; whatever a plain `execute`
  left unread is drained by the next operation.
- **Snapshots**: `rows_affected` is the preserved `Int64` bitcast; `lastrowid` comes from the
  cursor's own OK/terminator (a SELECT cursor reports 0 under DEPRECATE_EOF, where 1.x
  reported the connection's sticky value); status and warning counts are retained for both
  OK and legacy EOF terminators; a DML cursor keeps the 1.x `length == -1` sentinel.
- **Decoding policies** (`ResultOptions`): BIT is the big-endian value of all bytes (1.x read
  the first byte only); TIME decodes to `Dates.Time` for `0 ≤ t < 24h` and raises
  `ConversionError` otherwise, `time_type=Dates.Microsecond` is lossless; `zero_dates`
  (`:sentinel` default → `Date(0)`/`DateTime(0)`, `:missing` → `missing` and every date
  column typed `Union{Missing,T}`, `:error`); partial zero dates are errors unless
  `:missing`; a DATETIME value with sub-millisecond digits decoded to `DateTime` warns
  once and truncates to milliseconds on both protocols (1.x failed on the text path);
  `DateAndTime` scales the fractional digits by position (1.x's text path read them as an
  unscaled microsecond count, correct only at precision 6).
- **LOCAL INFILE** follows the plan's state table: refusal (`nothing`) always raises
  `LocalInfileRefused` even when the server accepts the empty upload; a handler error before
  any data (including the source's first read) is re-raised after resynchronizing; an error,
  size-limit crossing or write fault after data closes the connection; an unsolicited `0xFB`
  is a `ProtocolError`. Later results of the same COM_QUERY can request another upload.
- **Reconnect** is narrow: only before a send, only once the session is known dead
  (closed, or `BROKEN` by a fault — the command that hit the fault reports it as the
  classic `Error` 2006/2013), never inside a transaction; it bumps the generation so
  older cursors invalidate. `transaction` holds the connection lock across `f`.
- Handle-level facts from the 8.4 lane: the terminator OK of a SELECT carries
  `last_insert_id = 0`; mariadb:11.4 and mysql:8.4 both serve the fixture identically.

## Prepared statements (M4): decisions worth remembering

- **Prepared statements are the binary protocol**: `COM_STMT_PREPARE` → `PrepareOK` (the
  reserved byte is followed by `warning_count` only when the packet is ≥ 12 bytes; the
  `metadata_follows` flag belongs to `CLIENT_OPTIONAL_RESULTSET_METADATA`, which 2.0 never
  negotiates), then the parameter definitions and the column definitions, each closed by an
  EOF **only when `CLIENT_DEPRECATE_EOF` is off**. `read_definition_block!` bounds both blocks
  by `max_metadata_bytes`. `COM_STMT_EXECUTE` carries `statement_id`, `flags`
  (`CURSOR_TYPE_NO_CURSOR` — no server cursors in 2.0) and `iteration_count = 1`.
- **Two NULL-bitmap offsets**: the execute parameter bitmap uses bit offset **0**
  (`(nparams+7)/8` bytes); the binary resultset row bitmap uses bit offset **2**
  (`(ncols+7+2)/8` bytes). `scan_binary_row!` mirrors `scan_text_row!` — it walks the row once
  and records each column's *content* window (fixed width for numbers, the bytes after the
  one-byte temporal length prefix, and the bytes after the `string<lenenc>` prefix for
  everything else) so the value decoders stay lazy and the `wrongrow`/cursor-owned-buffer
  contract is identical to text. The obsolete `NEWDATE` wire type also uses the
  length-encoded byte form and retains the 1.x fallback-to-`String` mapping.
- **`new_params_bind_flag` / signature**: the client keeps the full last-sent `(type,
  unsigned)` signature per statement (`Statement.last_signature`) and resends the types only
  when the signature changes (a NULL parameter's slot is `MYSQL_TYPE_NULL`, so a value that
  flips NULL↔non-NULL forces a resend). Parameter type/encoding mirrors the effective 1.x
  `mysqltype`/`bind!` mapping: `Bit` is converted to bytes and sent as `BLOB`, while decimal
  values (DataDecimals; DecFP through the package extension) are converted to strings and
  sent as `STRING`. `Bool` maps to `TINY` (1.x left it
  at the `MYSQL_TYPE_STRING` fallback, an untested latent bug, so this is the sole deliberate
  deviation).
- **Long data**: `MySQL.send_long_data!` copies and sends each string/blob chunk, and the
  next execute omits that parameter's inline value. Copies remain on the statement until the
  first execute response so both reconnect and the single 1615 re-prepare can replay them for
  the new statement id. `MySQL.reset_statement!` sends `COM_STMT_RESET` and discards them;
  both helpers are public API (see the migration guide) but not exported.
- **Cursor is shared across protocols**: `Cursor{binary, buffered}` — `TextCursor =
  Cursor{false}`, `BinaryCursor = Cursor{true}` — so the ownership tokens, row epochs,
  multi-result draining, buffered budget and LOCAL INFILE state table have a single
  implementation; only `scan_row!` and `decode_column` dispatch on the protocol.
- **`ER_NEED_REPREPARE` (1615)**: a complete 1615 ERR as the first execute response packet
  (before any result bytes) triggers exactly one re-prepare (a fresh `statement_id`) and one
  re-execute (types re-sent, because the server's cached signature is gone). The client
  closes the superseded id after the new prepare succeeds. A second 1615 propagates as
  `StmtError`. A statement whose generation predates a reconnect is re-prepared lazily on
  its next execute; its old id belongs to the dead session and is not closed on the new one.
  Execute-time column definitions are authoritative and refresh the statement's cached
  metadata; a statement prepared without static metadata still honours the per-execute
  `mysql_date_and_time` keyword after that refresh.
- **Binary temporal decoding preserves the 1.x prepared-statement behaviour** except the
  shared Fixes: a sub-millisecond DATETIME **warns and truncates to milliseconds** (the text
  path now does the same; 1.x failed there); BIT is the big-endian value of all bytes (Fix), TIME honours sign and days and
  applies the `Dates.Time` range policy (Fix), and zero/partial dates follow the unified
  `zero_dates` policy (Fix; 1.x binary mapped zero components to 1970).
- **Statement reaping is finalizer-free**: `DBInterface.close!(stmt)` and a dropped
  statement's finalizer both park a preallocated `(statement_id, generation)` entry under a
  per-connection `ReentrantLock`; the finalizer path only uses `trylock` and re-registers the
  finalizer when the lock is busy. `begin_command!` sends `COM_STMT_CLOSE` for the parked ids
  of the current generation before the next command (after `drain_pending!`, so a streaming
  result is drained first). One-shot `execute(conn, sql, params)` prepares, executes and
  parks the statement the same way.

## Hardening and performance (M5): decisions worth remembering

- **Fuzzing found three real parser escapes** (all fixed with regression tests): `lowercase`
  on the untrusted server version string threw `InvalidCharError` on invalid UTF-8
  (`detect_kind` now ASCII-lowers bytes); a wire-supplied `NUM_FLAG` on a non-numeric
  column (or `UNSIGNED` on `MYSQL_TYPE_NULL`, whose Julia type is `String`) reached
  `unsigned(String)` (`is_unsigned` now trusts only the wire type); a DECIMAL value with an
  embedded NUL raised `ArgumentError` from the then-`Dec64` decoder's `Cstring` conversion
  instead of `ConversionError` (DECIMAL now decodes through DataDecimals, which rejects it
  as a parse failure). The fuzz contract: any mutated transcript must fail as a
  `Protocol.MySQLError`, never a crash. The harness (`test/protocol/fuzz.jl`) drives the
  real packet reader/classifiers/scanners/decoders and the handshake/auth parsers over an
  in-memory transport. Its vendor and synthetic corpus must produce the declared clean or
  documented-error outcome before mutation. Every case is deterministic from `(entry, seed)`.
  A bounded smoke batch runs in every CI lane. `scripts/fuzz.jl` runs budgeted
  batches in isolated workers with a wall-clock limit and an OS-enforced memory limit
  (hard address-space limit on the nightly Linux lane, RSS watchdog on other Unix hosts).
  Failed batches are split recursively inside the total run budget. An isolated failure
  saves its entry, seed, and exact mutated input; a cumulative or nondeterministic failure
  saves the smallest unresolved seed range.
- **The per-row hot path is allocation-free** (§8.9 gate: allocations per row ≤
  String/Vector columns + 1, asserted serverless in `test/protocol/perf_tests.jl` and
  against live servers in `test/perf/perf_gates.jl`). Four per-row allocations were
  eliminated: the closure passed to `guarded` per scanned row; the `lock(l) do` closure
  and the `Union{Nothing, Tuple}` iteration-protocol return of the streaming `iterate`
  (now a thin `@inline` wrapper over a `Bool`-returning `stream_advance!`); the mutable
  `PacketCursor` per scan (cursors own a scratch one, rebound per row); and the
  `Union{PacketView, ResultEnd}` return box of `read_row!` (`@inline` + no internal `try`
  so the union splits at the caller).
- **Command-phase reads are batched through a 64 KiB read buffer** (`PacketIO.readbuf`).
  Reseau's `unsafe_read` costs one `recv` per call, so per-packet exact reads dominated
  large scans (native was 0.3–0.5× Connector/C; with batching ≥ 0.9×). Reads stay
  byte-exact until authentication completes, so the STARTTLS empty-reader invariant is
  untouched (`replace_transport!` asserts it), and `FaultTransport` is never buffered so
  fault byte offsets stay deterministic. Buffered bytes are always bytes of the same
  connection's current response; a read of ≥ half the buffer bypasses it.
- **The `(ROWS, :row, ROWS)` self-transition skips the `TRANSITIONS` set lookup**
  (`row_transition!`): it is statically legal (`read_row!` already required phase ROWS)
  and the membership hash cost ~15% of a 1M-row scan. Coverage recording and the
  transition log are preserved.
- **§8.9 measurements** (historical record of the pre-2.0 dual-backend gate run — the
  ratio gates against Connector/C retired with the C backend at 2.0; `bench/` keeps the
  cross-driver comparison repeatable) (Chairmarks; mysql:8.4 in Docker, Apple Silicon
  host, quiet run):
  text scan 1.18×, binary (prepared) scan 1.05×, tiny/NULL scan 1.17×, 10k round trips
  plain 0.96× / TLS 0.92×, 100k `executemany` 0.85×, 64 MiB blob 0.98× of Connector/C;
  allocations per native row are 2/2/1 at gates 2/2/1. All raw gates met. Plain gates run
  against a server started with `--tls-version=` and assert an empty session `Ssl_cipher`
  for both clients. The TLS round-trip gate uses a second server and asserts a nonempty
  cipher for both. This is necessary because MariaDB Connector/C 3.4 cannot force
  `SSL_MODE_DISABLED`. **Round-trip-bound gates sit near a transport latency floor.** If a
  raw ratio misses, the harness measures five samples of 2,000 end-to-end COM_PING commands
  on each backend. COM_PING uses identical wire bytes but includes each client's minimal
  command wrapper, so the adjusted assertion is diagnostic evidence, not a replacement
  pass: the raw miss is recorded as `@test_skip`. The adjusted cost must remain nonnegative
  and meet the ratio. **Under `Pkg.test` the timing ratios run in a
  child process with `--check-bounds=auto`**: Pkg.test forces `--check-bounds=yes`, which
  slows the pure-Julia backend 2–3× on byte-heavy paths (64 MiB blob fetch 64 ms → 147 ms
  measured) while Connector/C's C code is untouched — a rigged race, not production
  performance. Correctness and allocation gates still run under full bounds checking.
- **§8.10 leak/lifecycle soak** (`test/protocol/leak_soak.jl`, primary live lane):
  10k statements and 10k cursors abandoned across tasks under GC thrash plus 100 abandoned
  connections all return `Prepared_stmt_count`/`Threads_connected` to baseline with the
  reaper queue empty, weak refs cleared, fds and RSS stable; finalizers provably park
  without I/O (server-side counts cannot move without a command on the owning
  connection); a statement preserved through the first streaming row, then finalized late,
  is only parked and cannot disturb that active cursor; a read deadline closes the
  connection deterministically.
- **Deferred (not faked)**: Windows named-pipe lane (§8.12, needs a Windows runner);
  external interop matrix ProxySQL/TiDB/Vitess/Aurora (§8.5, needs those servers);
  MYSQL_TYPE_VECTOR classic framing (undocumented); server cursors / COM_STMT_FETCH /
  query attributes / bulk execute / compression; OUT-param round trips beyond CALL result
  sets; the 60–90-day preview soak (calendar). See `docs/src/migration.md`.

## Idle disconnect announcements (round-1 live finding, resolved)

On MySQL 8.4, `SET SESSION wait_timeout=1`, a two-second idle wait, then `SELECT 1`
produced `ProtocolError("sequence id mismatch: expected 1, got 0")`. The captured
packet has header `91 00 00 00` and payload prefix `ff bf 0f 23 48 59 30 30 30`:
ERR 4031 / HY000 (`ER_CLIENT_INTERACTION_TIMEOUT`, MySQL 8.0.24+), sent *before* the
client's next command, when the server closes an idle connection — so it arrives as the
first packet of the next command's response, numbered 0 where 1 is expected. The packet
reader accepts exactly that shape (`stale_err`: first packet of a fresh command response,
sequence 0, ERR header) and the session reports it as a terminal `Error(4031)` (BROKEN,
transport closed), so `reconnect=true` recovers on the following command. Every other
sequence mismatch still faults. MariaDB closes idle connections silently (peer EOF → 2006).

## Third-party consultations

- **2026-09-08, Codex round-1 review — policy exception.** Question: does
  `sha256_password` require an empty response or a NUL byte for an empty password?
  The reviewer opened Oracle's GPL client source
  [`sql-common/client_authentication.cc` on the `8.4` branch](https://github.com/mysql/mysql-server/blob/8.4/sql-common/client_authentication.cc)
  before reading the source restrictions above. The source sends one NUL byte. This
  consultation violated the review policy. No code was copied, and no authentication
  implementation or test was changed based on it. A separate live check on MySQL 8.4
  accepted the existing empty response over both TCP and TLS. The maintainer must review
  this exception; the source-pattern check cannot validate consultation history.
