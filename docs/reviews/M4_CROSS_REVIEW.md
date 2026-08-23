VERDICT: CLEAN

Commits:
- `fix(protocol): validate prepare response headers`
- `fix(protocol): validate binary row spans`
- `fix(native): harden binary value decoding`
- `fix(native): preserve effective parameter wire types`
- `fix(protocol): preserve prepared error hierarchy`
- `fix(native): make statement parking lossless`
- `fix(native): close superseded statement ids`
- `fix(native): preserve prepared API contracts`
- `fix(native): charge binary cursor type storage`
- `fix(native): apply refreshed prepared metadata options`
- `fix(native): close the statement reaper lifecycle`
- `fix(native): revalidate parameters after reprepare`
- `test(native): cover prepared protocol contracts`
- `test(native): exercise every prepared parameter family`
- `fix(native): validate all binary date fields`
- `test(protocol): cover prepared reset state`
- `test(protocol): cover execute framing and spans`
- `fix(native): refresh execute-time metadata`
- `fix(native): replay prepared long data`
- `test(native): cover binary policy manifest`
- `fix(native): isolate cached result metadata`
- `test(native): reject invalid long-data binds`
- `docs(native): describe prepared DBInterface surface`
- `fix(protocol): scan legacy NEWDATE values`
- `fix(native): preserve one-shot metadata options`
- `test(native): exercise prepared CALL live`
- `docs: record M4 cross-review`

Findings fixed:
- `src/Protocol/stmt.jl:79`, MEDIUM — PREPARE_OK accepted a nonzero reserved byte, partial warning counts, and arbitrary trailing bytes. This could consume an unnegotiated `metadata_follows` byte silently.
- `src/Protocol/responses.jl:340`, HIGH — Binary row scanning accepted every unknown type as length-encoded and accepted arbitrary temporal lengths. A malicious row could desynchronize all later column spans.
- `src/Native/binary.jl:14`, HIGH — Binary decoders could reach `unsafe_string`, pointer use, and `@inbounds` reads with an invalid caller-controlled span.
- `src/Native/binary.jl:67`, MEDIUM — FLOAT and DOUBLE decoding ignored the measured span width and could read bytes outside the value window.
- `src/Native/binary.jl:84`, MEDIUM — Binary DATE/DATETIME/TIME decoding accepted invalid sign, clock, microsecond, and 838-hour fields. DATE could ignore malformed trailing clock bytes.
- `src/Native/binary.jl:192`, MEDIUM — DecFP and `Bit` parameters used their nominal API types instead of the effective 1.x bind types (`STRING` and `BLOB`).
- `src/Protocol/commands.jl:158`, MEDIUM — COM_STMT_RESET errors and prepared errors received during rows used `Error` instead of the required `StmtError` hierarchy.
- `src/Native/connection.jl:212`, HIGH — Explicit statement close used a nonblocking park and could drop a statement id when the finalizer spinlock was busy. Finalizer parking also allocated queue elements.
- `src/Native/statement.jl:108`, MEDIUM — A successful 1615 re-prepare replaced the statement id without closing the superseded id on the same server generation.
- `src/Native/statement.jl:252`, MEDIUM — Closed-statement and parameter-count errors did not preserve the 1.x exception and message contract. Execute-time `mysql_date_and_time` could also override static prepare metadata.
- `src/Native/cursor.jl:118`, MEDIUM — The buffered-result budget did not charge the binary cursor's retained wire-type table.
- `src/Native/statement.jl:276`, HIGH — Parameter count was checked only before reconnect or 1615 re-prepare. Changed server metadata could produce an invalid execute frame or an indexing failure.
- `src/Native/statement.jl:294`, MEDIUM — Result options were selected before reconnect or 1615 metadata refresh and could apply the wrong temporal mapping.
- `src/Native/connection.jl:113`, HIGH — Connection close did not close the statement-reaper lifecycle. Duplicate or late finalizer parking could retain queue links after the connection was gone.
- `src/Native/statement.jl:301`, HIGH — Authoritative execute-time column definitions did not reliably refresh the Statement cache. Dynamic metadata could become effectively static after its first result.
- `src/Native/statement.jl:301`, MEDIUM — Statement and cursor schema containers were aliased after a metadata refresh, and the cache did not track which temporal option produced its types.
- `src/Native/statement.jl:151`, HIGH — Long-data chunks had no complete driver lifecycle. They were not retained, omitted from inline values, replayed after reconnect/1615, cleared after the first response, or reset safely.
- `src/Protocol/responses.jl:332`, MEDIUM — The legacy `MYSQL_TYPE_NEWDATE` byte form was rejected instead of scanned as length-encoded content and decoded through the preserved String fallback.
- `src/Native/statement.jl:356`, MEDIUM — One-shot `execute(conn, sql, params; mysql_date_and_time=true)` dropped the option when the statement had dynamic execute-time metadata.
- `test/protocol/binary_tests.jl:93`, LOW — M4 unit coverage omitted malformed PREPARE_OK shapes, exact execute framing, span failures, NULL-boundary signatures, reset state, reprepare variants, wrongrow modes, and several parameter families.
- `test/compat_manifest.jl:245`, LOW — The live compatibility manifest omitted the complete parameter family, binary TIME/zero-date/BIT policies, prepared wrongrow, executemany, and prepared CALL multi-results.

Deferred:
- `src/Protocol/responses.jl:366` — MySQL 9.x `MYSQL_TYPE_VECTOR` is still rejected. The current vendor binary-result documentation does not define its classic-protocol framing, and the required MySQL 8.4/MariaDB 11.4 lanes cannot settle it. Add a documented or capture-gated decoder in the later server-compatibility milestone.
- `src/Protocol/stmt.jl:105` — Server cursors/COM_STMT_FETCH, query attributes, COM_STMT_BULK_EXECUTE, and compression remain deliberate M5/2.x protocol extensions. M4 always sends `CURSOR_TYPE_NO_CURSOR`.
- `src/Native/statement.jl:322` — Prepared CALL multi-results are complete, but special OUT-parameter interpretation and round trips beyond those result sets remain deferred by scope.
- `test/protocol/binary_tests.jl:708` — Section 8.9 scale and performance gates remain for M5: 100k `executemany`, 64 MiB values, allocation limits, and native-versus-C throughput ratios.
- `test/protocol/binary_tests.jl:632` — Section 8.10 still needs the long-running server `Prepared_stmt_count`, fd, heap, and reconnect leak soak. M4 has deterministic and threaded reaper stress coverage.

Test results:
- `Protocol | 1354 | 1354 | 43.3s`
- `Protocol (--check-bounds=yes) | 1354 | 1354 | 46.0s`
- `MySQL | 1687 | 1687 | 1m36.9s`
- `Testing MySQL tests passed`

Assumptions / Decisions / Validation:
- Assumption — `fdf23e9` is the accepted M1-M3 boundary. I reviewed only `fdf23e9..HEAD` and used earlier code only to understand an inherited contract.
- Assumption — The external plan, official MySQL/MariaDB protocol documentation, and the local 1.x implementation define Preserve versus Fix.
- Assumption — MySQL 8.4 and MariaDB 11.4 are the required live M4 lanes. Newer server-only types need separate evidence.
- Decision — I kept `send_long_data!` and `reset_statement!` in the `MySQL.Native` namespace. I did not expand the package export surface.
- Decision — I accepted vendor-documented legacy NEWDATE framing. I deferred VECTOR because its binary framing is not documented by the sources in scope.
- Decision — I preserved the effective 1.x `Bit`, DecFP, ENUM, temporal, and exception behavior. I kept `Bool` to `MYSQL_TYPE_TINY` as the one directed parameter deviation.
- Decision — I kept all finalizer paths free of transport I/O. Explicit close may wait for the spinlock so it cannot lose an id.
- Validation — The normal and bounds-enabled protocol suites passed after the final code fixes. The later manifest-only commit is not loaded by those commands.
- Validation — The final full package run passed the Connector/C suite, MySQL 8.4, MariaDB 11.4, and every applicable text/binary compatibility row on both live lanes.
- Validation — The final live row verifies prepared CALL result sets and the final OK on both supported server families. The legacy backend remains skipped for its known final-OK crash.
- Validation — `git diff --check fdf23e9..HEAD` passed. Every review commit has the required Codex trailer.
- Validation — I did not consult prohibited GPL/LGPL client implementation code. I did not change the pinned Reseau manifest, edit outside this worktree, or push.
