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
Base.show(io::IO, b::Bit) = print(io, "MySQL.API.Bit(\"$(lstrip(bitstring(b.bits), '0'))\")")
Base.unsigned(::Type{Bit}) = Bit

mysql_type(::Type{Bit}) = MYSQL_TYPE_BIT
mysql_type(::Type{Cchar}) = MYSQL_TYPE_TINY
mysql_type(::Type{Cshort}) = MYSQL_TYPE_SHORT
mysql_type(::Type{Cint}) = MYSQL_TYPE_LONG
mysql_type(::Type{Int64}) = MYSQL_TYPE_LONGLONG
mysql_type(::Type{Cfloat}) = MYSQL_TYPE_FLOAT
mysql_type(::Type{Dec64}) = MYSQL_TYPE_DECIMAL
mysql_type(::Type{Cdouble}) = MYSQL_TYPE_DOUBLE
mysql_type(::Type{Vector{UInt8}}) = MYSQL_TYPE_BLOB
mysql_type(::Type{DateTime}) = MYSQL_TYPE_TIMESTAMP
mysql_type(::Type{Date}) = MYSQL_TYPE_DATE
mysql_type(::Type{Dates.Time}) = MYSQL_TYPE_TIME
mysql_type(::Type{Missing}) = MYSQL_TYPE_NULL
mysql_type(::Type{Nothing}) = MYSQL_TYPE_NULL
mysql_type(::Type{T}) where {T} = MYSQL_TYPE_VAR_STRING
mysql_type(x) = mysql_type(typeof(x))

function julia_type(mysqltype)
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
        return String # Vector{UInt8}
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

# Constant indicating whether multiple statements in queries should be supported.
const CLIENT_MULTI_STATEMENTS = UInt32( unsigned(1) << 16)

# Options to be passed to mysql_options API.
const MYSQL_OPT_CONNECT_TIMEOUT = UInt32(0)
const MYSQL_OPT_COMPRESS = UInt32(1)
const MYSQL_OPT_NAMED_PIPE = UInt32(2)
const MYSQL_INIT_COMMAND = UInt32(3)
const MYSQL_READ_DEFAULT_FILE = UInt32(4)
const MYSQL_READ_DEFAULT_GROUP = UInt32(5)
const MYSQL_SET_CHARSET_DIR = UInt32(6)
const MYSQL_SET_CHARSET_NAME = UInt32(7)
const MYSQL_OPT_LOCAL_INFILE = UInt32(8)
const MYSQL_OPT_PROTOCOL = UInt32(9)
const MYSQL_SHARED_MEMORY_BASE_NAME = UInt32(10)
const MYSQL_OPT_READ_TIMEOUT = UInt32(11)
const MYSQL_OPT_WRITE_TIMEOUT = UInt32(12)
const MYSQL_OPT_USE_RESULT = UInt32(13)
const MYSQL_OPT_USE_REMOTE_CONNECTION = UInt32(14)
const MYSQL_OPT_USE_EMBEDDED_CONNECTION = UInt32(15)
const MYSQL_OPT_GUESS_CONNECTION = UInt32(16)
const MYSQL_SET_CLIENT_IP = UInt32(17)
const MYSQL_SECURE_AUTH = UInt32(18)
const MYSQL_REPORT_DATA_TRUNCATION = UInt32(19)
const MYSQL_OPT_RECONNECT = UInt32(20)
const MYSQL_OPT_SSL_VERIFY_SERVER_CERT = UInt32(21)
const MYSQL_PLUGIN_DIR = UInt32(22)
const MYSQL_DEFAULT_AUTH = UInt32(23)
const MYSQL_OPT_BIND = UInt32(24)
const MYSQL_OPT_SSL_KEY = UInt32(25)
const MYSQL_OPT_SSL_CERT = UInt32(26)
const MYSQL_OPT_SSL_CA = UInt32(27)
const MYSQL_OPT_SSL_CAPATH = UInt32(28)
const MYSQL_OPT_SSL_CIPHER = UInt32(29)
const MYSQL_OPT_SSL_CRL = UInt32(30)
const MYSQL_OPT_SSL_CRLPATH = UInt32(31)
const MYSQL_OPT_CONNECT_ATTR_RESET = UInt32(32)
const MYSQL_OPT_CONNECT_ATTR_ADD = UInt32(33)
const MYSQL_OPT_CONNECT_ATTR_DELETE = UInt32(34)
const MYSQL_SERVER_PUBLIC_KEY = UInt32(35)
const MYSQL_ENABLE_CLEARTEXT_PLUGIN = UInt32(36)
const MYSQL_OPT_CAN_HANDLE_EXPIRED_PASSWORDS = UInt32(37)

const MYSQL_DATA_FRAME = 0
const MYSQL_TUPLES = 1
export MYSQL_DATA_FRAME, MYSQL_TUPLES

const MYSQL_TIMESTAMP_DATE     = 0
const MYSQL_TIMESTAMP_DATETIME = 1
const MYSQL_TIMESTAMP_TIME     = 2

const NOT_NULL_FLAG = UInt32(1)
const UNSIGNED_FLAG = UInt32(32)
const MYSQL_NO_DATA = 100

const MYSQL_DEFAULT_PORT = 3306

const CR_SERVER_GONE_ERROR = 2006
const CR_SERVER_LOST = 2013

if Sys.iswindows()
	const MYSQL_DEFAULT_SOCKET = "MySQL"
else
	const MYSQL_DEFAULT_SOCKET = "/tmp/mysql.sock"
end
