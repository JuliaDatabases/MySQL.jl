# The field_type in the MYSQL_FIELD object that directly maps to native MYSQL types
const MYSQL_TYPE_DECIMAL     = UInt32(0)
const MYSQL_TYPE_TINY        = UInt32(1)
const MYSQL_TYPE_SHORT       = UInt32(2)
const MYSQL_TYPE_LONG        = UInt32(3)
const MYSQL_TYPE_FLOAT       = UInt32(4)
const MYSQL_TYPE_DOUBLE      = UInt32(5)
const MYSQL_TYPE_NULL        = UInt32(6)
const MYSQL_TYPE_TIMESTAMP   = UInt32(7)
const MYSQL_TYPE_LONGLONG    = UInt32(8)
const MYSQL_TYPE_INT24       = UInt32(9)
const MYSQL_TYPE_DATE        = UInt32(10)
const MYSQL_TYPE_TIME        = UInt32(11)
const MYSQL_TYPE_DATETIME    = UInt32(12)
const MYSQL_TYPE_YEAR        = UInt32(13)
const MYSQL_TYPE_NEWDATE     = UInt32(14)
const MYSQL_TYPE_VARCHAR     = UInt32(15)
const MYSQL_TYPE_BIT         = UInt32(16)
const MYSQL_TYPE_NEWDECIMAL  = UInt32(246)
const MYSQL_TYPE_ENUM        = UInt32(247)
const MYSQL_TYPE_SET         = UInt32(248)
const MYSQL_TYPE_TINY_BLOB   = UInt32(249)
const MYSQL_TYPE_MEDIUM_BLOB = UInt32(250)
const MYSQL_TYPE_LONG_BLOB   = UInt32(251)
const MYSQL_TYPE_BLOB        = UInt32(252)
const MYSQL_TYPE_VAR_STRING  = UInt32(253)
const MYSQL_TYPE_STRING      = UInt32(254)
const MYSQL_TYPE_GEOMETRY    = UInt32(255)

struct Bit
    bits::UInt64
end
Base.string(b::Bit) = String(lstrip(bitstring(b.bits), '0'))
function bitvalue(b::Bit)
    x = b.bits
    lz = leading_zeros(x)
    N = lz <=  8 ? 8 : lz <= 16 ? 7 : lz <= 24 ? 6 :
        lz <= 32 ? 5 : lz <= 40 ? 4 : lz <= 48 ? 3 :
        lz <= 54 ? 2 : 1
    A = Vector{UInt8}(undef, N)
    msk = 0x00000000000000ff
    for i = 1:N
        @inbounds A[i] = (x & msk) % UInt8
        x >>= 8
    end
    return A
end
Base.show(io::IO, b::Bit) = print(io, "MySQL.API.Bit(\"$(string(b))\")")
Base.unsigned(::Type{Bit}) = Bit

struct DateAndTime <: Dates.AbstractDateTime
    date::Date
    time::Time
end

Dates.Date(x::DateAndTime) = x.date
Dates.Time(x::DateAndTime) = x.time
Dates.year(x::DateAndTime) = Dates.year(Date(x))
Dates.month(x::DateAndTime) = Dates.month(Date(x))
Dates.day(x::DateAndTime) = Dates.day(Date(x))
Dates.hour(x::DateAndTime) = Dates.hour(Time(x))
Dates.minute(x::DateAndTime) = Dates.minute(Time(x))
Dates.second(x::DateAndTime) = Dates.second(Time(x))
Dates.millisecond(x::DateAndTime) = Dates.millisecond(Time(x))
Dates.microsecond(x::DateAndTime) = Dates.microsecond(Time(x))

import Base.==
==(a::DateAndTime, b::DateAndTime) = ==(a.date, b.date) && ==(a.time, b.time)

mysqltype(::Type{Bit}) = MYSQL_TYPE_BIT
mysqltype(::Union{Type{Cchar}, Type{Cuchar}}) = MYSQL_TYPE_TINY
mysqltype(::Union{Type{Cshort}, Type{Cushort}}) = MYSQL_TYPE_SHORT
mysqltype(::Union{Type{Cint}, Type{Cuint}}) = MYSQL_TYPE_LONG
mysqltype(::Union{Type{Int64}, Type{UInt64}}) = MYSQL_TYPE_LONGLONG
mysqltype(::Type{Cfloat}) = MYSQL_TYPE_FLOAT
mysqltype(::Type{Dec64}) = MYSQL_TYPE_DECIMAL
mysqltype(::Type{Cdouble}) = MYSQL_TYPE_DOUBLE
mysqltype(::Type{Vector{UInt8}}) = MYSQL_TYPE_BLOB
mysqltype(::Type{DateTime}) = MYSQL_TYPE_TIMESTAMP
mysqltype(::Type{DateAndTime}) = MYSQL_TYPE_DATETIME
mysqltype(::Type{Date}) = MYSQL_TYPE_DATE
mysqltype(::Type{Time}) = MYSQL_TYPE_TIME
mysqltype(::Type{Missing}) = MYSQL_TYPE_NULL
mysqltype(::Type{Nothing}) = MYSQL_TYPE_NULL
mysqltype(::Type{T}) where {T} = MYSQL_TYPE_STRING
mysqltype(x) = mysqltype(typeof(x))

function juliatype(mysqltype)
    if mysqltype == API.MYSQL_TYPE_BIT
        return Bit
    elseif mysqltype == API.MYSQL_TYPE_TINY ||
            mysqltype == API.MYSQL_TYPE_ENUM
        return Cchar
    elseif mysqltype == API.MYSQL_TYPE_SHORT
        return Cshort
    elseif mysqltype == API.MYSQL_TYPE_LONG ||
            mysqltype == API.MYSQL_TYPE_INT24
        return Cint
    elseif mysqltype == API.MYSQL_TYPE_LONGLONG
        return Int64
    elseif mysqltype == API.MYSQL_TYPE_FLOAT
        return Cfloat
    elseif mysqltype == API.MYSQL_TYPE_DECIMAL ||
           mysqltype == API.MYSQL_TYPE_NEWDECIMAL
        return Dec64
    elseif mysqltype == API.MYSQL_TYPE_DOUBLE
        return Cdouble
    elseif mysqltype == API.MYSQL_TYPE_TINY_BLOB ||
           mysqltype == API.MYSQL_TYPE_MEDIUM_BLOB ||
           mysqltype == API.MYSQL_TYPE_LONG_BLOB ||
           mysqltype == API.MYSQL_TYPE_BLOB ||
           mysqltype == API.MYSQL_TYPE_GEOMETRY
        return Vector{UInt8}
    elseif mysqltype == API.MYSQL_TYPE_YEAR
        return Clong
    elseif mysqltype == API.MYSQL_TYPE_TIMESTAMP
        return DateTime
    elseif mysqltype == API.MYSQL_TYPE_DATE
        return Date
    elseif mysqltype == API.MYSQL_TYPE_TIME
        return Dates.Time
    elseif mysqltype == API.MYSQL_TYPE_DATETIME
        return DateTime
    elseif mysqltype == API.MYSQL_TYPE_SET ||
           mysqltype == API.MYSQL_TYPE_NULL ||
           mysqltype == API.MYSQL_TYPE_VARCHAR ||
           mysqltype == API.MYSQL_TYPE_VAR_STRING ||
           mysqltype == API.MYSQL_TYPE_STRING
        return String
    else
        return String
    end
end

@enum mysql_protocol_type begin
    MYSQL_PROTOCOL_DEFAULT
    MYSQL_PROTOCOL_TCP
    MYSQL_PROTOCOL_SOCKET
    MYSQL_PROTOCOL_PIPE
    MYSQL_PROTOCOL_MEMORY
end

@enum mysql_ssl_mode begin
    SSL_MODE_DISABLED
    SSL_MODE_PREFERRED
    SSL_MODE_REQUIRED
    SSL_MODE_VERIFY_CA
    SSL_MODE_VERIFY_IDENTITY
end

# Options to be passed to mysql_options API.
@enum mysql_option begin
    MYSQL_OPT_CONNECT_TIMEOUT
    MYSQL_OPT_COMPRESS
    MYSQL_OPT_NAMED_PIPE
    MYSQL_INIT_COMMAND
    MYSQL_READ_DEFAULT_FILE
    MYSQL_READ_DEFAULT_GROUP
    MYSQL_SET_CHARSET_DIR
    MYSQL_SET_CHARSET_NAME
    MYSQL_OPT_LOCAL_INFILE
    MYSQL_OPT_PROTOCOL
    MYSQL_SHARED_MEMORY_BASE_NAME
    MYSQL_OPT_READ_TIMEOUT
    MYSQL_OPT_WRITE_TIMEOUT
    MYSQL_OPT_USE_RESULT
    MYSQL_OPT_USE_REMOTE_CONNECTION
    MYSQL_OPT_USE_EMBEDDED_CONNECTION
    MYSQL_OPT_GUESS_CONNECTION
    MYSQL_SET_CLIENT_IP
    MYSQL_SECURE_AUTH
    MYSQL_REPORT_DATA_TRUNCATION
    MYSQL_OPT_RECONNECT
    MYSQL_OPT_SSL_VERIFY_SERVER_CERT
    MYSQL_PLUGIN_DIR
    MYSQL_DEFAULT_AUTH
    MYSQL_OPT_BIND
    MYSQL_OPT_SSL_KEY
    MYSQL_OPT_SSL_CERT
    MYSQL_OPT_SSL_CA
    MYSQL_OPT_SSL_CAPATH
    MYSQL_OPT_SSL_CIPHER
    MYSQL_OPT_SSL_CRL
    MYSQL_OPT_SSL_CRLPATH
    MYSQL_OPT_CONNECT_ATTR_RESET
    MYSQL_OPT_CONNECT_ATTR_ADD
    MYSQL_OPT_CONNECT_ATTR_DELETE
    MYSQL_SERVER_PUBLIC_KEY
    MYSQL_ENABLE_CLEARTEXT_PLUGIN
    MYSQL_OPT_CAN_HANDLE_EXPIRED_PASSWORDS
    MYSQL_OPT_SSL_ENFORCE
    MYSQL_OPT_MAX_ALLOWED_PACKET
    MYSQL_OPT_NET_BUFFER_LENGTH
    MYSQL_OPT_TLS_VERSION

    MYSQL_PROGRESS_CALLBACK=5999
    MYSQL_OPT_NONBLOCK
    MYSQL_DATABASE_DRIVER=7000
    MARIADB_OPT_SSL_FP
    MARIADB_OPT_SSL_FP_LIST
    MARIADB_OPT_TLS_PASSPHRASE
    MARIADB_OPT_TLS_CIPHER_STRENGTH
    MARIADB_OPT_TLS_VERSION
    MARIADB_OPT_TLS_PEER_FP
    MARIADB_OPT_TLS_PEER_FP_LIST
    MARIADB_OPT_CONNECTION_READ_ONLY
    MYSQL_OPT_CONNECT_ATTRS
    MARIADB_OPT_USERDATA
    MARIADB_OPT_CONNECTION_HANDLER
    MARIADB_OPT_PORT
    MARIADB_OPT_UNIXSOCKET
    MARIADB_OPT_PASSWORD
    MARIADB_OPT_HOST
    MARIADB_OPT_USER
    MARIADB_OPT_SCHEMA
    MARIADB_OPT_DEBUG
    MARIADB_OPT_FOUND_ROWS
    MARIADB_OPT_MULTI_RESULTS
    MARIADB_OPT_MULTI_STATEMENTS
    MARIADB_OPT_INTERACTIVE
    MARIADB_OPT_PROXY_HEADER
    MARIADB_OPT_IO_WAIT
    MYSQL_OPT_SSL_MODE
end

const CUINTOPTS = Set([MYSQL_OPT_CONNECT_TIMEOUT, MYSQL_OPT_PROTOCOL, MYSQL_OPT_READ_TIMEOUT, MYSQL_OPT_WRITE_TIMEOUT, MYSQL_OPT_SSL_MODE])
const CULONGOPTS = Set([MYSQL_OPT_MAX_ALLOWED_PACKET, MYSQL_OPT_NET_BUFFER_LENGTH])
const BOOLOPTS = Set([MYSQL_ENABLE_CLEARTEXT_PLUGIN, MYSQL_OPT_CAN_HANDLE_EXPIRED_PASSWORDS, MYSQL_OPT_LOCAL_INFILE, MYSQL_OPT_RECONNECT, MYSQL_REPORT_DATA_TRUNCATION, MYSQL_OPT_SSL_ENFORCE, MYSQL_OPT_SSL_VERIFY_SERVER_CERT])
const STRINGOPTS = Set([MYSQL_DEFAULT_AUTH, MYSQL_OPT_BIND, MYSQL_OPT_SSL_CA, MYSQL_OPT_SSL_CAPATH, MYSQL_OPT_SSL_CERT, MYSQL_OPT_SSL_CIPHER, MYSQL_OPT_SSL_CRL, MYSQL_OPT_SSL_CRLPATH, MYSQL_OPT_SSL_KEY, MYSQL_OPT_TLS_VERSION, MYSQL_PLUGIN_DIR, MYSQL_READ_DEFAULT_FILE, MYSQL_READ_DEFAULT_GROUP, MYSQL_SERVER_PUBLIC_KEY, MYSQL_SET_CHARSET_DIR, MYSQL_SET_CHARSET_NAME, MYSQL_SHARED_MEMORY_BASE_NAME])

const MYSQL_TIMESTAMP_DATE     = 0
const MYSQL_TIMESTAMP_DATETIME = 1
const MYSQL_TIMESTAMP_TIME     = 2

const NOT_NULL_FLAG = UInt32(1)
const UNSIGNED_FLAG = UInt32(32)
const BINARY_FLAG = UInt32(128)
const NUM_FLAG = UInt32(32768)
const MYSQL_NO_DATA = 100

const MYSQL_DEFAULT_PORT = 3306

const CR_SERVER_GONE_ERROR = 2006
const CR_SERVER_LOST = 2013

if Sys.iswindows()
	const MYSQL_DEFAULT_SOCKET = "MySQL"
else
	const MYSQL_DEFAULT_SOCKET = "/tmp/mysql.sock"
end

@enum enum_stmt_attr_type begin
  STMT_ATTR_UPDATE_MAX_LENGTH
  STMT_ATTR_CURSOR_TYPE
  STMT_ATTR_PREFETCH_ROWS

  STMT_ATTR_PREBIND_PARAMS=200
  STMT_ATTR_ARRAY_SIZE
  STMT_ATTR_ROW_SIZE
  STMT_ATTR_STATE
  STMT_ATTR_CB_USER_DATA
  STMT_ATTR_CB_PARAM
  STMT_ATTR_CB_RESULT
end

const BOOL_STMT_ATTR = Set([STMT_ATTR_UPDATE_MAX_LENGTH])
const CULONG_STMT_ATTR = Set([STMT_ATTR_CURSOR_TYPE, STMT_ATTR_PREFETCH_ROWS])

const CLIENT_FOUND_ROWS = 2
const CLIENT_NO_SCHEMA = 16
const CLIENT_COMPRESS = 32
const CLIENT_LOCAL_FILES = 128
const CLIENT_IGNORE_SPACE = 256
const CLIENT_MULTI_STATEMENTS =  (UInt64(1) << 16)
const CLIENT_MULTI_RESULTS =     (UInt64(1) << 17)