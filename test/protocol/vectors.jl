# Golden vectors taken verbatim from the vendor protocol documentation (hex dumps include
# the 4-byte packet header unless noted). Sources:
#   Oracle "MySQL Source Code Documentation" (MySQL 26.7.0):
#     page_protocol_basic_tls            — HandshakeV10 (5.5.2-m2), HandshakeResponse41, SSLRequest
#     page_protocol_connection_phase_packets_protocol_handshake_response — response with connect attrs (5.6.6-m9)
#     page_protocol_basic_ok_packet      — OK example
#     page_protocol_basic_err_packet     — ERR example
#     page_protocol_basic_eof_packet     — EOF example
#     page_protocol_com_stmt_prepare     — column definitions of the PREPARE_OK example
#     page_protocol_basic_compression_packet — uncompressed text result set of SELECT repeat("a", 50)
#     page_protocol_binary_resultset     — binary result set example
#     page_protocol_command_phase_sp     — CALL multi() multi-resultset example
module Vectors

using ..FakePeer: hexbytes

# Protocol::Handshake for a 5.5.2-m2 server (no CLIENT_PLUGIN_AUTH: the high capability
# bytes are 00 00); scramble "\"=NP)u9V" + ")d@R\\Uxz|!)K".
const HANDSHAKE_V10_552 = hexbytes("""
36 00 00 00 0a 35 2e 35 2e 32 2d 6d 32 00 52 00
00 00 22 3d 4e 50 29 75 39 56 00 ff ff 08 02 00
00 00 00 00 00 00 00 00 00 00 00 00 00 29 64 40
52 5c 55 78 7a 7c 21 29 4b 00""")

# Protocol::HandshakeResponse41 sent by a non-TLS 5.5 client: caps 0x0003a605, max packet
# 16 MiB, charset 8, user "root", 20-byte native-password response.
const HANDSHAKE_RESPONSE_552 = hexbytes("""
3a 00 00 01 05 a6 03 00 00 00 00 01 08 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 72 6f 6f 74 00 14 14 63 6b 70 99 8a
b6 9e 96 87 a2 30 9a 40 67 2b 83 38 85 4b""")

# Protocol::SSLRequest with CLIENT_SSL set (caps 0x0003ae05).
const SSL_REQUEST_552 = hexbytes("""
20 00 00 01 05 ae 03 00 00 00 00 01 08 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00""")

# HandshakeResponse41 with CLIENT_PLUGIN_AUTH and CLIENT_CONNECT_ATTRS (MySQL 5.6.6-m9):
# caps 0x001ea285, max packet 1 GiB, charset 8, user root, plugin mysql_native_password,
# attrs _os/_client_name/_pid/_client_version/_platform/foo.
const HANDSHAKE_RESPONSE_566_ATTRS = hexbytes("""
b2 00 00 01 85 a2 1e 00 00 00 00 40 08 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 72 6f 6f 74 00 14 22 50 79 a2 12 d4
e8 82 e5 b3 f4 1a 97 75 6b c8 be db 9f 80 6d 79
73 71 6c 5f 6e 61 74 69 76 65 5f 70 61 73 73 77
6f 72 64 00 61 03 5f 6f 73 09 64 65 62 69 61 6e
36 2e 30 0c 5f 63 6c 69 65 6e 74 5f 6e 61 6d 65
08 6c 69 62 6d 79 73 71 6c 04 5f 70 69 64 05 32
32 33 34 34 0f 5f 63 6c 69 65 6e 74 5f 76 65 72
73 69 6f 6e 08 35 2e 36 2e 36 2d 6d 39 09 5f 70
6c 61 74 66 6f 72 6d 06 78 38 36 5f 36 34 03 66
6f 6f 03 62 61 72""")

# OK: 0 affected rows, last-insert-id 0, AUTOCOMMIT, 0 warnings.
const OK_EXAMPLE = hexbytes("07 00 00 02 00 00 00 02 00 00 00")

# ERR 1096 (HY000) "No tables used".
const ERR_EXAMPLE = hexbytes("17 00 00 01 ff 48 04 23 48 59 30 30 30 4e 6f 20 74 61 62 6c 65 73 20 75 73 65 64")

# EOF: 0 warnings, AUTOCOMMIT.
const EOF_EXAMPLE = hexbytes("05 00 00 05 fe 00 00 02 00")

# Column definitions from the PREPARE_OK example (SELECT CONCAT(?, ?) AS col1).
const COLUMN_DEF_PARAM = hexbytes("17 00 00 02 03 64 65 66 00 00 00 01 3f 00 0c 3f 00 00 00 00 00 fd 80 00 00 00 00")
const COLUMN_DEF_COL1 = hexbytes("1a 00 00 05 03 64 65 66 00 00 00 04 63 6f 6c 31 00 0c 3f 00 00 00 00 00 fd 80 00 1f 00 00")

# Text result set of SELECT repeat("a", 50) (no DEPRECATE_EOF): column count, column
# definition, EOF, one row, EOF.
const TEXT_RESULTSET_REPEAT_A = hexbytes("""
01 00 00 01 01
25 00 00 02 03 64 65 66 00 00 00 0f 72 65 70 65 61 74 28 22 61 22 2c 20 35 30 29 00 0c 08 00 32 00 00 00 fd 01 00 1f 00 00
05 00 00 03 fe 00 00 02 00
33 00 00 04 32 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61
05 00 00 05 fe 00 00 02 00""")

# Binary result set example: one VAR_STRING column "col1", one row "foobar".
const BINARY_RESULTSET_FOOBAR = hexbytes("""
01 00 00 01 01
1a 00 00 02 03 64 65 66 00 00 00 04 63 6f 6c 31 00 0c 08 00 06 00 00 00 fd 00 00 1f 00 00
05 00 00 03 fe 00 00 02 00
09 00 00 04 00 00 06 66 6f 6f 62 61 72
05 00 00 05 fe 00 00 02 00""")

# CALL multi(): two result sets (status 0x0a = AUTOCOMMIT|MORE_RESULTS_EXISTS on their
# EOFs) followed by the closing OK of the CALL (1 affected row).
const CALL_MULTI_RESULTSET = hexbytes("""
01 00 00 01 01
17 00 00 02 03 64 65 66 00 00 00 01 31 00 0c 3f 00 01 00 00 00 08 81 00 00 00 00
05 00 00 03 fe 00 00 0a 00
02 00 00 04 01 31
05 00 00 05 fe 00 00 0a 00
01 00 00 06 01
17 00 00 07 03 64 65 66 00 00 00 01 31 00 0c 3f 00 01 00 00 00 08 81 00 00 00 00
05 00 00 08 fe 00 00 0a 00
02 00 00 09 01 31
05 00 00 0a fe 00 00 0a 00
07 00 00 0b 00 01 00 02 00 00 00""")

payload(packet::Vector{UInt8}) = packet[5:end]

end # module
