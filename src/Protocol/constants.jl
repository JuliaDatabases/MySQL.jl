# Protocol constants. Numeric values that exist in the server's public headers are generated
# (see scripts/gen_constants.jl); everything below is documented only in the protocol pages
# or is MariaDB-specific.

include("constants_generated.jl")

# Every implemented command byte must be unique and agree with the server enum.
let bytes = collect(keys(COMMAND_NAMES))
    allunique(bytes) || error("duplicate command byte in generated constants")
    COM_STMT_RESET == 0x1A && COM_SET_OPTION == 0x1B || error("COM_STMT_RESET/COM_SET_OPTION must be 0x1A/0x1B (the Oracle protocol page documents COM_SET_OPTION as 0x1A; the server enum says 0x1B)")
end

# MariaDB-only command.
const COM_STMT_BULK_EXECUTE = 0xFA

# Capability bit 1 doubles as MariaDB's "this is a MySQL client/server" marker: a MariaDB
# server leaves it clear and then the 4 reserved bytes of HandshakeV10 carry extended caps.
const CLIENT_MYSQL = CLIENT_LONG_PASSWORD
const CLIENT_SECURE_CONNECTION = CLIENT_RESERVED2

# MariaDB extended capabilities (bits 32..37, valid only when CLIENT_MYSQL is clear).
const MARIADB_CLIENT_PROGRESS = UInt64(1) << 32
const MARIADB_CLIENT_COM_MULTI = UInt64(1) << 33
const MARIADB_CLIENT_STMT_BULK_OPERATIONS = UInt64(1) << 34
const MARIADB_CLIENT_EXTENDED_METADATA = UInt64(1) << 35
const MARIADB_CLIENT_CACHE_METADATA = UInt64(1) << 36
const MARIADB_CLIENT_BULK_UNIT_RESULTS = UInt64(1) << 37

# Client-policy-only flags that must never be negotiated on the wire.
const CLIENT_POLICY_ONLY_FLAGS = CLIENT_IGNORE_SIGPIPE | CLIENT_SSL_VERIFY_SERVER_CERT | CLIENT_REMEMBER_OPTIONS

# Packet header bytes (meaning depends on the phase; see responses.jl).
const OK_HEADER = 0x00
const AUTH_MORE_DATA_HEADER = 0x01
const AUTH_NEXT_FACTOR_HEADER = 0x02
const LOCAL_INFILE_HEADER = 0xFB
const NULL_VALUE = 0xFB
const EOF_HEADER = 0xFE
const AUTH_SWITCH_HEADER = 0xFE
const ERR_HEADER = 0xFF
const HANDSHAKE_PROTOCOL_VERSION = 0x0A

# caching_sha2_password / sha256_password exchange bytes.
const CACHING_SHA2_FAST_AUTH_SUCCESS = 0x03
const CACHING_SHA2_PERFORM_FULL_AUTH = 0x04
const CACHING_SHA2_REQUEST_PUBLIC_KEY = 0x02
const SHA256_REQUEST_PUBLIC_KEY = 0x01

const SCRAMBLE_LENGTH = 20
const AUTH_PLUGIN_DATA_PART_1_LENGTH = 8
const HANDSHAKE_RESERVED_LENGTH = 10
const HANDSHAKE_RESPONSE_FILLER_LENGTH = 23
const SQLSTATE_LENGTH = 5
const SQLSTATE_MARKER = UInt8('#')

# Plugin names.
const PLUGIN_NATIVE_PASSWORD = "mysql_native_password"
const PLUGIN_CACHING_SHA2_PASSWORD = "caching_sha2_password"
const PLUGIN_SHA256_PASSWORD = "sha256_password"
const PLUGIN_CLEAR_PASSWORD = "mysql_clear_password"
const PLUGIN_OLD_PASSWORD = "mysql_old_password"
const PLUGIN_ED25519 = "client_ed25519"
const PLUGIN_PARSEC = "parsec"
const PLUGIN_DIALOG = "dialog"

# Character set / collation ids (information_schema.collations).
const CHARSET_LATIN1_SWEDISH_CI = 0x08
const CHARSET_UTF8MB3_GENERAL_CI = 0x21
const CHARSET_UTF8MB4_GENERAL_CI = 0x2D
const CHARSET_BINARY = 0x3F
const CHARSET_UTF8MB4_0900_AI_CI = 0xFF

# COM_SET_OPTION operations.
const MYSQL_OPTION_MULTI_STATEMENTS_ON = 0x0000
const MYSQL_OPTION_MULTI_STATEMENTS_OFF = 0x0001

# Server error codes the client must recognise.
const ER_ACCESS_DENIED_ERROR = 1045
const ER_NET_PACKET_TOO_LARGE = 1153
const ER_QUERY_INTERRUPTED = 1317
const ER_NEED_REPREPARE = 1615
const ER_MUST_CHANGE_PASSWORD = 1820
const ER_QUERY_TIMEOUT = 3024
const MARIADB_ER_STATEMENT_TIMEOUT = 1969
const MARIADB_ER_PROGRESS = 0xFFFF

# Client-reserved error codes (emulated for client-side failures; a server ERR carrying one
# of these ranges is malformed).
const CR_SERVER_GONE_ERROR = 2006
const CR_SERVER_LOST = 2013
const CR_SSL_CONNECTION_ERROR = 2026
const CR_AUTH_PLUGIN_CANNOT_LOAD = 2059

is_client_reserved_errno(code::Integer) = return (2000 <= code <= 2999) || (5000 <= code <= 5999)
