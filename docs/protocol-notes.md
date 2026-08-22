# Native wire-protocol backend: protocol notes and clean-room log

This file accompanies `src/Protocol/`. It records where every byte-level fact came from,
the places where the vendor documents disagree, and every consultation of a third-party
implementation (none so far). The plan that drives this work is
`~/.julia/dev/MySQL-native-protocol-plan.md` (not part of the repository).

## Sources of truth (in priority order)

1. Live captures from the pinned server lanes (none recorded yet — M1 has no server lane).
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
| `COM_SET_OPTION` byte | `page_protocol_com_set_option` says `[0x1A]` | `my_command.h`: `COM_STMT_RESET = 26`, `COM_SET_OPTION = 27`; KB `com_set_option`: `0x1B` | `0x1B`; `constants.jl` asserts it at load time |
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

## Third-party consultations

None.
