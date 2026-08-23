# M6 independent cross-review

Review date: 2026-08-23

Reviewed range: `origin/main..native-m3`, starting from review head
`20ed4edf59c7f5424f8d7dc794bbea911ba195a3`. The code fixes end at
`e93a9a7cdd1d7887c7f67cdb7b2f687e0bf8ede5`.

I reviewed the full branch against `MySQL-native-protocol-plan.md`,
`docs/src/migration.md`, `docs/protocol-notes.md`, the earlier M3/M4 reviews, and
the repository conventions. I checked the protocol, malformed-input, lifecycle,
concurrency, value-codec, TLS/auth, option-file, packaging, CI, and documentation
surfaces. I also rechecked the two prior adversarial-fix rounds.

## Findings fixed

| # | Severity | Location | Defect and fix | Regression evidence |
|---:|:---:|---|---|---|
| 1 | Medium | `src/Protocol/commands.jl:296` | Draining an abandoned `COM_STMT_PREPARE` response learned the server statement ID but did not close it. `drain_step!` now parses the full prepare response and sends `COM_STMT_CLOSE` for that ID. (`eb0959f`) | `test/protocol/session_tests.jl:939` verifies the exact close command and ID. |
| 2 | High | `src/Protocol/responses.jl:71` | `parse_ok` accepted malformed payloads for known session-state block types and returned the session to a usable state. Known blocks are now validated while the OK packet is parsed. Unknown block types remain opaque for forward compatibility. (`4475dd4`) | `test/protocol/responses_tests.jl:83` covers truncated, trailing, and malformed known blocks. |
| 3 | High | `src/Protocol/responses.jl:199` | An ERR packet with the SQLSTATE marker and fewer than five state bytes could escape through an unsafe parse path. The parser now rejects the truncated field as `ProtocolError`. (`4475dd4`) | `test/protocol/responses_tests.jl:112` supplies a truncated SQLSTATE. |
| 4 | Medium | `src/Protocol/responses.jl:128` | GTID session state accepted unsupported selectors and malformed length-encoded values. The parser now requires selector `0` and full consumption of one value. (`33ea6b3`) | `test/protocol/responses_tests.jl:88` covers malformed, unsupported, and non-canonical GTID blocks. |
| 5 | Medium | `src/Protocol/responses.jl:120` | An empty `SESSION_TRACK_SYSTEM_VARIABLES` block was accepted even though it cannot contain a name/value pair. The parser now requires at least one complete pair. (`85a36b2`) | `test/protocol/responses_tests.jl:86` covers the empty block. |
| 6 | High | `src/Native/options.jl:121` | On Unix, default protocol selection for an empty host or `localhost` silently selected TCP and discarded an option-file socket. It now selects the local transport and fails clearly because Unix sockets are deferred. Explicit `protocol=:tcp` remains the escape hatch. The analogous Windows pipe rule is preserved. (`8457940`) | `test/protocol/native_tests.jl:180` and `test/protocol/tls_tests.jl:135` cover option files, default hosts, explicit TCP, and strict TLS. |
| 7 | High | `src/Native/load.jl:3` | Native `MySQL.load` did not safely normalize embedded backticks. A later prequoted-name shortcut also trusted malformed quoting. Native identifiers now double embedded backticks, preserve only syntactically valid prequoted identifiers, and normalize unsafe prequoted input. The C backend keeps its 1.x behavior. (`20080d2`, `986ef20`) | `test/protocol/binary_tests.jl:108` covers raw, valid prequoted, qualified, and malformed prequoted identifiers. |
| 8 | High | `src/Native/load.jl:15`, `src/load.jl:87` | Native `debug=true` logged row values, including secrets, and rejected the planned `debug=:values` mode. It now logs statements only for `true`; only `:values` logs row data. (`20080d2`) | `test/protocol/binary_tests.jl:108` asserts the exact logging policy and invalid-mode rejection. |
| 9 | High | `src/Native/reaper.jl:11`, `src/Native/connect.jl:21` | The handle finalizer allocated a queue node/callback on its enqueue path. The reaper now uses an intrusive preallocated entry, a try-lock-only finalizer path, and finalizer re-registration when the lock is busy. Transport close remains outside the global lock. (`bf9133b`) | `test/protocol/native_tests.jl:275` asserts zero enqueue allocations, lock contention behavior, concurrent enqueue, and exactly-once close. |
| 10 | High | `src/Protocol/packets.jl:45`, `src/Protocol/packets.jl:161` | Aggregate response accounting used `Int` and could wrap on 32-bit Julia, which could bypass `max_response_bytes`. It now uses checked-range `UInt64` accounting. (`e7585df`) | `test/protocol/packets_tests.jl:61` crosses `typemax(Int)` and verifies reset on the next command. |
| 11 | Medium | `src/Native/options.jl:416` | `local_infile_handler` accepted only `Function`, which rejected callable structs. Validation now checks `applicable(handler, "")`. (`540a410`) | `test/protocol/native_tests.jl:1` covers a callable functor and a non-callable value. |
| 12 | High | `src/Native/cursor.jl:68` | A foreign task could consume a live streaming cursor and race its connection owner. Streaming cursors now bind to the first consuming task, check the active response token, and reject foreign access. (`d6cf94a`) | `test/protocol/cursor_tests.jl:344` checks foreign row access and iteration. |
| 13 | High | `src/Native/connection.jl:178` | A reconnecting command could try to drain an unread response after its transport was already known closed. It now reconnects before any drain attempt, so no stale transport read occurs. (`d6cf94a`) | `test/protocol/cursor_tests.jl:834` leaves the session in `ROWS`, closes only the transport, and verifies reconnect. |
| 14 | High | `src/Protocol/commands.jl:195`, `src/Protocol/stmt.jl:36` | Result and prepared-statement metadata vectors were sized from the server column count before metadata-byte limits could reject the response. Columns are now appended only after each bounded packet is read and parsed. (`c3c71c4`) | `test/protocol/session_tests.jl:674` verifies that declared metadata cannot force allocation before the byte budget is enforced. |
| 15 | Low | `src/Protocol/auth.jl:42`, `src/Native/binary.jl:45` | The new production tree contained 197 expression-body methods without the required explicit `return`. The native and protocol sources now follow the repository function convention. (`885648f`) | A static full-tree audit found no remaining production violation; all runtime suites stayed green. |
| 16 | Medium | `.github/workflows/ci.yml:13`, `.github/workflows/ci.yml:67` | The clean-room forbidden-reference check and the required 85% native line-coverage threshold were absent. CI now runs both checks. (`dd85d5e`) | `scripts/check_native_cleanroom.jl:1` and `scripts/check_native_coverage.jl:1` are exercised locally; final results are below. |
| 17 | Low | `docs/protocol-notes.md:88`, `docs/protocol-notes.md:221` | The notes still described command-wide I/O timeouts and a per-connection spinlock after those contracts changed. They now describe per-transport-operation timeout re-arming and the `ReentrantLock`/try-lock finalizer design. (`728a68b`) | Documentation was checked against `src/Protocol/packets.jl:41` and `src/Native/connection.jl:37`. |
| 18 | Medium | `test/compat_manifest.jl:523` | The executable compatibility manifest covered result values but omitted most plan section 4.2 rows. It now maps every declared row and runs the surface assertions against both backends on a real server. (`f243d75`) | `test/compat_manifest.jl:655` asserts exact plan-row coverage; the live run passed on both server families. |
| 19 | High | `src/Native/options.jl:345`, `src/Protocol/limits.jl:59`, `src/Protocol/packets.jl:63` | Hostile or oversized integer options could throw `InexactError` or overflow nanosecond deadlines, especially on 32-bit Julia. Options now check `Int` range, timeout seconds have an `Int64` nanosecond cap, and deadline addition saturates. (`6dc35a9`) | `test/protocol/codec_tests.jl:70`, `native_tests.jl:40`, and `packets_tests.jl:70` cover large integers and saturated deadlines. |
| 20 | High | `src/Native/cursor.jl:391` | Advancing a multi-result iterator could drain another task's unconsumed streaming result. The outer iterator now applies the same task-ownership rule as row iteration. (`d4e5529`) | `test/protocol/cursor_tests.jl:492` verifies foreign outer advancement fails without consuming data. |
| 21 | High | `src/Protocol/auth.jl:87`, `src/Protocol/auth.jl:310` | Authentication helpers left SHA intermediates, concatenated password inputs, and sent cleartext/RSA replies in scratch buffers on success and error paths. The code now builds secret buffers directly and wipes every intermediate in `finally` blocks. (`cd8446b`) | `test/protocol/auth_tests.jl:37`, `auth_tests.jl:231`, and `auth_tests.jl:364` verify wiping after success, injected failure, and transport send. |
| 22 | Medium | `src/Protocol/commands.jl:82` | `COM_SET_OPTION` rejected the legal one-byte legacy EOF response. The simple-command reader now accepts the short EOF form while keeping status unchanged. (`25db2de`) | `test/protocol/session_tests.jl:380` covers one-, five-, and seven-byte response forms. |
| 23 | High | `src/Protocol/responses.jl:367`, `src/Native/binary.jl:122` | Binary DATE accepted DATETIME lengths 7 and 11. This could consume a malformed row under the wrong column type. DATE now permits only lengths 0 and 4, and decode repeats the check. (`a3c4e39`) | `test/protocol/binary_tests.jl:229` covers both invalid lengths and the direct decoder. |
| 24 | High | `src/Protocol/columns.jl:47` | The deferred `MYSQL_TYPE_VECTOR` type reached later decode code and could fail outside the documented error contract. It is now rejected at column metadata as `ProtocolError`. (`54bbffa`) | `test/protocol/responses_tests.jl:160` and `cursor_tests.jl:196` cover the parser and live cursor path. |
| 25 | Low | `src/Native/options.jl:382` | `named_pipe=nothing` was rejected even though omitted compatibility keywords use `nothing`. It now means false. (`8ffc698`) | `test/protocol/native_tests.jl:14` covers `nothing` with explicit TCP. |
| 26 | High | `src/Native/statement.jl:164` | Re-prepare could reduce the parameter count and then replay retained long data for a parameter that no longer existed. Invalid retained chunks are now discarded before replay and execution fails locally. (`981a40b`) | `test/protocol/binary_tests.jl:944` simulates a two-parameter statement becoming one parameter and verifies recovery. |
| 27 | High | `src/Native/connect.jl:165`, `src/Native/connect.jl:202` | `init_command` used generic draining for later `LOCAL INFILE` results. It sent an empty upload instead of invoking the configured handler. Init processing now uses the normal bounded upload handler for every result. (`5b3f552`) | `test/protocol/tls_tests.jl:299` verifies a later init result requests and receives the handler payload. |
| 28 | High | `src/Protocol/columns.jl:35` | Invalid UTF-8 in a column name reached `Symbol(col.name)` and escaped as `InvalidCharError`, outside the malformed-stream contract. All six string fields in a column definition are now validated before native metadata use. (`e93a9a7`) | `test/protocol/cursor_tests.jl:211` sends an invalid name and verifies `ProtocolError` plus connection fault. |

## Validation

- Baseline before review fixes:
  - Serverless, Julia 1.12, 4 threads: 1443/1443.
  - Serverless, Julia 1.12, 1 thread: 1443/1443.
- Final serverless suite at code head `e93a9a7`:
  - `julia --project=. -t 4 --startup-file=no -e 'include("test/protocol/runtests.jl")'`: 1515/1515 in 1m14.6s.
  - `julia --project=. -t 1 --startup-file=no -e 'include("test/protocol/runtests.jl")'`: 1515/1515 in 1m21.1s.
  - Julia 1.10.11 clean compatibility environment: 1515/1515 in 57.9s.
- Malformed-stream fuzzing:
  - Final-head deterministic worker: 1,000,000 cases, seeds 1,000,000 through 1,999,999, zero violations.
- Acceptance scripts:
  - Native line coverage: 2719/2787 executable lines, 97.56%.
  - Clean-room scan: 28 source files, zero forbidden references.
- Full gate:
  - `CI=true julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'`: 2020/2020 in 3m13.2s with `--check-bounds=yes`.
  - The full gate ran native live lanes on `mysql:8.4` and `mariadb:11.4`, the two-backend compatibility manifest, the lifecycle soak, and the stable Connector/C tests.
  - CI intentionally skipped only the timing-ratio performance gate. Its correctness and allocation smoke coverage remains in the serverless/full suites and the dedicated perf job.
- Manual compatibility check during review:
  - MySQL 8.4: 70/70 surface assertions plus all existing value rows passed against both the native and Connector/C backends.
- Repository checks:
  - `git diff --check origin/main..HEAD`: clean.
  - Every review-fix commit has `Co-Authored-By: Codex <codex@openai.com>`.
  - No review-started Docker container remains running.

## Assumptions and review decisions

- I treated the plan and migration table as authoritative. I preserved deliberate `Fix` rows instead of reporting them as regressions.
- I kept the stable C backend's observable 1.x behavior. Native-only dispatch implements the load changes.
- I kept unknown session-state block types opaque. This supports forward compatibility. Known block types are strict.
- I treated explicit `protocol=:tcp` as the supported escape hatch from the deferred local transport selected for an empty host or `localhost`.
- I did not change Reseau. I found no dependency defect that needed a local Reseau edit.
- I did not rewrite old non-imperative commits. I used imperative subjects for every new review commit.

## Deferred / noted for the human

- External interoperability captures, a Windows named-pipe implementation, Windows ARM64 execution, and the long preview soak remain the explicitly deferred items listed in `docs/protocol-notes.md`. I did not turn those declared future gates into code changes.
- The registered-package propagation delay for Reseau 1.4.1 is external state. I did not lower compat because 1.4.1 contains the required TLS 1.3 client-certificate fix.

VERDICT: CLEAN
