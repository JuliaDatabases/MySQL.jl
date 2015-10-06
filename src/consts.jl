"""
The field_type in the MYSQL_FIELD object that directly maps to native MYSQL types
"""
baremodule MYSQL_TYPES
    import Base: call, @doc

    const MYSQL_TYPE_DECIMAL     = 0
    const MYSQL_TYPE_TINY        = 1
    const MYSQL_TYPE_SHORT       = 2
    const MYSQL_TYPE_LONG        = 3
    const MYSQL_TYPE_FLOAT       = 4
    const MYSQL_TYPE_DOUBLE      = 5
    const MYSQL_TYPE_NULL        = 6
    const MYSQL_TYPE_TIMESTAMP   = 7
    const MYSQL_TYPE_LONGLONG    = 8
    const MYSQL_TYPE_INT24       = 9
    const MYSQL_TYPE_DATE        = 10
    const MYSQL_TYPE_TIME        = 11
    const MYSQL_TYPE_DATETIME    = 12
    const MYSQL_TYPE_YEAR        = 13
    const MYSQL_TYPE_NEWDATE     = 14
    const MYSQL_TYPE_VARCHAR     = 15
    const MYSQL_TYPE_BIT         = 16
    const MYSQL_TYPE_NEWDECIMAL  = 246
    const MYSQL_TYPE_ENUM        = 247
    const MYSQL_TYPE_SET         = 248
    const MYSQL_TYPE_TINY_BLOB   = 249
    const MYSQL_TYPE_MEDIUM_BLOB = 250
    const MYSQL_TYPE_LONG_BLOB   = 251
    const MYSQL_TYPE_BLOB        = 252
    const MYSQL_TYPE_VAR_STRING  = 253
    const MYSQL_TYPE_STRING      = 254
    const MYSQL_TYPE_GEOMETRY    = 255
end

"""
Constant indicating whether multiple statements in queries should be supported or not.
"""
const CLIENT_MULTI_STATEMENTS = ( unsigned(1) << 16)

"""
Options to be passed to mysql_options API.
"""
baremodule MYSQL_OPTION
    import Base: call, @doc

    const MYSQL_OPT_CONNECT_TIMEOUT = 0
    const MYSQL_OPT_COMPRESS = 1
    const MYSQL_OPT_NAMED_PIPE = 2
    const MYSQL_INIT_COMMAND = 3
    const MYSQL_READ_DEFAULT_FILE = 4
    const MYSQL_READ_DEFAULT_GROUP = 5
    const MYSQL_SET_CHARSET_DIR = 6
    const MYSQL_SET_CHARSET_NAME = 7
    const MYSQL_OPT_LOCAL_INFILE = 8
    const MYSQL_OPT_PROTOCOL = 9
    const MYSQL_SHARED_MEMORY_BASE_NAME = 10
    const MYSQL_OPT_READ_TIMEOUT = 11
    const MYSQL_OPT_WRITE_TIMEOUT = 12
    const MYSQL_OPT_USE_RESULT = 13
    const MYSQL_OPT_USE_REMOTE_CONNECTION = 14
    const MYSQL_OPT_USE_EMBEDDED_CONNECTION = 15
    const MYSQL_OPT_GUESS_CONNECTION = 16
    const MYSQL_SET_CLIENT_IP = 17
    const MYSQL_SECURE_AUTH = 18
    const MYSQL_REPORT_DATA_TRUNCATION = 19
    const MYSQL_OPT_RECONNECT = 20
    const MYSQL_OPT_SSL_VERIFY_SERVER_CERT = 21
    const MYSQL_PLUGIN_DIR = 22
    const MYSQL_DEFAULT_AUTH = 23
    const MYSQL_OPT_BIND = 24
    const MYSQL_OPT_SSL_KEY = 25
    const MYSQL_OPT_SSL_CERT = 26
    const MYSQL_OPT_SSL_CA = 27
    const MYSQL_OPT_SSL_CAPATH = 28
    const MYSQL_OPT_SSL_CIPHER = 29
    const MYSQL_OPT_SSL_CRL = 30
    const MYSQL_OPT_SSL_CRLPATH = 31
    const MYSQL_OPT_CONNECT_ATTR_RESET = 32
    const MYSQL_OPT_CONNECT_ATTR_ADD = 33
    const MYSQL_OPT_CONNECT_ATTR_DELETE = 34
    const MYSQL_SERVER_PUBLIC_KEY = 35
    const MYSQL_ENABLE_CLEARTEXT_PLUGIN = 36
    const MYSQL_OPT_CAN_HANDLE_EXPIRED_PASSWORDS = 37
end

const MYSQL_DATA_FRAME = 0
const MYSQL_ARRAY = 1

export MYSQL_DATA_FRAME, MYSQL_ARRAY
