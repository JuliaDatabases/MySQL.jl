VERDICT: CLEAN

Commits:
- `fix(native): validate text temporal values`
- `fix(native): validate rows before retention`
- `fix(native): complete local infile states`
- `fix(native): enforce connection ownership`
- `fix(native): isolate cursor result lifetimes`
- `fix(protocol): recover before local infile data`
- `test(native): cover text result transitions`
- `fix(native): reject signed unsigned text values`
- `fix(native): retain result warning snapshots`
- `fix(native): preserve DML cursor length`
- `fix(native): retain local infile error context`
- `fix(native): preserve temporal compatibility`
- `fix(native): preserve outer transaction ownership`
- `docs: record M3 cross-review`

Findings fixed:
- `src/Native/decode.jl:108`, MEDIUM — Unsigned text accepted a leading minus sign and could wrap. Numeric decoders also accepted a valid prefix with trailing invalid bytes.
- `src/Native/decode.jl:149`, MEDIUM — Date parsing classified malformed prefixes as zero dates. Fractions longer than six digits were truncated. TIME accepted hours above 838.
- `src/Native/decode.jl:215`, MEDIUM — DateTime and DateAndTime changed valid-server 1.x behavior without a section 4.2 Fix disposition. The Preserve behavior is restored and executable.
- `src/Native/cursor.jl:99`, HIGH — The buffered limit omitted retained metadata and index state. Its charge could also overflow before comparison.
- `src/Native/cursor.jl:143`, HIGH — Malformed text rows could be retained or iterated without faulting the protocol session.
- `src/Native/connection.jl:116`, HIGH — A foreign command invalidated the active cursor only after its blocking drain. A concurrent reader could still treat the old row as active.
- `src/Native/connection.jl:128`, HIGH — Reconnect was possible from BROKEN state and during a server-reported transaction.
- `src/Native/connection.jl:147`, MEDIUM — Command reads and writes did not apply the configured Reseau deadlines.
- `src/Native/cursor.jl:204`, HIGH — Streaming reads reused the current row buffer. A terminator or failed next row could overwrite state still visible through the last row.
- `src/Native/cursor.jl:249`, MEDIUM — Cursor close did not always stale the current row, become locally closed, or remain idempotent.
- `src/Native/cursor.jl:389`, HIGH — Multi-results reused one ownership token. Closing an older cursor could drain a newer result.
- `src/Native/cursor.jl:285`, HIGH — Recoverable LOCAL INFILE failures could close the session, later-result requests were not handled, and upload-response classification was not restored to query mode.
- `src/Protocol/commands.jl:296`, HIGH — A size-limit failure before the first upload byte faulted the connection instead of sending an empty packet and resynchronizing.
- `src/Native/cursor.jl:277`, MEDIUM — A handler failure discarded the server ERR instead of retaining it in the exception cause chain.
- `src/Native/cursor.jl:116`, LOW — Result terminator warning counts were not retained in cursor snapshots.
- `src/Native/cursor.jl:90`, LOW — Native DML cursors reported length 0. The required 1.x sentinel is -1.
- `src/Native/connection.jl:189`, HIGH — A rejected nested transaction cleared the outer transaction owner. A later nested START could commit the outer transaction implicitly.
- `test/protocol/cursor_tests.jl:267`, LOW — Section 8.7 lacked fake-peer coverage for legacy EOF cursors, ordered DML/SELECT transitions, and ERR during rows in both storage modes.

Deferred:
- `src/Native/cursor.jl:343` — M4 owns parameter binding, DBInterface.prepare, MySQL.load, binary rows, and the binary wrongrow half of section 8.7. No M4 code was added.
- `test/protocol/cursor_tests.jl:505` — M5 owns the section 8.9 scale and performance gates: 1M-row scans, the default-limit result above 256 MiB, allocation limits, and C-backend throughput ratios. M3 has functional limit tests only.

Test results:
- `Protocol | 1128 | 1128 | 35.6s`
- `MySQL | 1425 | 1425 | 1m19.7s`
- `Testing MySQL tests passed`

Assumptions made:
- `native-m1` is the accepted baseline. I inspected baseline code only where an M3 change depended on its contract.
- The external plan and the 1.x implementation control Preserve versus Fix. I corrected M3 notes and manifest rows when they disagreed.
- The mysql:8.4 and mariadb:11.4 Docker lanes are the supported live-server evidence for this milestone.

Decisions made:
- I restored the 1.x DML length and temporal quirks. I did not add new Fix dispositions outside section 4.2.
- I used a distinct token for each result cursor and two cursor-owned streaming buffers.
- I kept pre-upload LOCAL INFILE failures recoverable. I kept every ambiguous or post-data failure fatal.
- One full run hit a non-reproducible M1 reaper stress assertion. The same test passed in focused runs and in the final full run. I did not change accepted M1 code.

Validation/verification:
- The required focused command passed on the final source tree.
- The required full command passed the Connector/C suite, both live lanes, and the manifest on both backends.
- `git diff --check native-m1..HEAD` passed. Every review commit has the required Codex trailer.
- An extra Julia 1.10 package run did not reach MySQL code because the untracked Julia 1.12 Manifest could not be instantiated on Julia 1.10. I did not alter the pinned Manifest. The added atomic syntax was checked directly on Julia 1.10.
- I did not consult GPL client code. I did not edit outside this worktree. I did not push.
