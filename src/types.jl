using Dates

abstract MySQL5 <: DBI.DatabaseSystem

"""
Julia wrapper for MySQL database handle. Used for passing to mysql_init,
mysql_real_connect, mysql_close etc.
"""
type MySQLDatabaseHandle <: DBI.DatabaseHandle
    ptr::Ptr{Cuchar}
    status::Cint
end

"""
Julia wrapper for MySQL statement handle. Used for prepared statement
API's.
"""
type MySQLStatementHandle <: DBI.StatementHandle
    db::MySQLDatabaseHandle
    ptr::Ptr{Cuchar}
    executed::Int

    function MySQLStatementHandle(db::MySQLDatabaseHandle, ptr::Ptr{Void})
        new(db, ptr, 0)
    end
end

"""
The record that would be returned by mysql_fetch_row API.
"""
type MYSQL_ROW
    values :: Ptr{Ptr{Uint8}} # pointer to an array of strings
end

"""
The MySQL handle passed to C calls.
"""
typealias MYSQLPTR Ptr{Cuchar}

"""
The Pointer to result set for C calls.
"""
typealias MYSQL_RES Ptr{Uint8}

"""
The field object that contains the metadata of the table. 
Returned by mysql_fetch_fields API.
"""
type MYSQL_FIELD
    name :: Ptr{Uint8}             ##  Name of column
    org_name :: Ptr{Uint8}         ##  Original column name, if an alias
    table :: Ptr{Uint8}            ##  Table of column if column was a field
    org_table :: Ptr{Uint8}        ##  Org table name, if table was an alias
    db :: Ptr{Uint8}               ##  Database for table
    catalog :: Ptr{Uint8}          ##  Catalog for table
    def :: Ptr{Uint8}              ##  Default value (set by mysql_list_fields)
    field_length :: Clong          ##  Width of column (create length)
    max_length :: Clong            ##  Max width for selected set
    name_length :: Cuint
    org_name_length :: Cuint
    table_length :: Cuint
    org_table_length :: Cuint
    db_length :: Cuint
    catalog_length :: Cuint
    def_length :: Cuint
    flags :: Cuint                 ##  Div flags
    decimals :: Cuint              ##  Number of decimals in field
    charsetnr :: Cuint             ##  Character set
    field_type :: Cuint            ##  Type of field. See mysql_com.h for types
    extension :: Ptr{Void}
end

"""
The field_type in the MYSQL_FIELD object that directly maps to native MYSQL types
"""
baremodule MYSQL_CONSTS
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
Native mysql to julia type mapping.
"""
MYSQL_TYPE_MAP = [
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_DECIMAL::Int64     => Float64,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_TINY::Int64        => Int8,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_SHORT::Int64       => Int64,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONG::Int64        => Int64,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_FLOAT::Int64       => Float64,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_DOUBLE::Int64      => Float64,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_NULL::Int64        => Any,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_TIMESTAMP::Int64   => Any,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONGLONG::Int64    => Int64,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_INT24::Int64       => Int64,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_DATE::Int64        => Any,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_TIME::Int64        => Any,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_DATETIME::Int64    => String,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_YEAR::Int64        => Int64,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDATE::Int64     => String,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_VARCHAR::Int64     => String,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_BIT::Int64         => Int8,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_NEWDECIMAL::Int64  => Float64,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_ENUM::Int64        => Int64,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_SET::Int64         => Any,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_TINY_BLOB::Int64   => Any,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_MEDIUM_BLOB::Int64 => Any,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_LONG_BLOB::Int64   => Any,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_BLOB::Int64        => Any,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_VAR_STRING::Int64  => String,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_STRING::Int64      => String,
    MySQL.MYSQL_CONSTS.MYSQL_TYPE_GEOMETRY::Int64    => Any
]

# Constant indicating whether multiple statements in queries should be supported or not.
const CLIENT_MULTI_STATEMENTS = ( unsigned(1) << 16)

"""
Type mirroring MYSQL_TIME C struct.
"""
immutable type MYSQL_TIME
    year::Cuint
    month::Cuint
    day::Cuint
    hour::Cuint
    minute::Cuint
    second::Cuint
    second_part::Culong
    neg::Cchar
    offset::Cuint
end

"""
Support for prepared statement related APIs.
"""
immutable type JU_MYSQL_BIND
    length::Array{Culong, 0}
    is_null::Array{Culong, 0}
    buffer_long::Array{Culong, 0}
    buffer_int::Array{Cint, 0}
    buffer_double::Array{Cdouble, 0}
    buffer_string::Array{Uint8, 1}
    buffer_datetime::Array{MYSQL_TIME, 0}
end

immutable type MYSQL_BIND
    length::Ptr{Culong}
    is_null::Ptr{Cchar}
    buffer::Ptr{Void}
    error::Ptr{Cchar}
    row_ptr::Ptr{Cuchar}
    store_param_func ::Ptr{Void}
    fetch_result ::Ptr{Void}
    skip_result ::Ptr{Void}
    buffer_length::Culong
    offset::Culong
    length_value::Culong
    param_number :: Cuint
    pack_length :: Cuint
    buffer_type :: Cint
    error_value :: Cchar
    is_unsigned :: Cchar
    long_data_used :: Cchar
    is_null_value :: Cchar
    extension :: Ptr{Void}

    function MYSQL_BIND(in_buffer_type::Cint, in_length::Ptr{Culong}, in_is_null::Ptr{Cchar}, 
                        in_buffer::Ptr{Void}, in_buffer_length::Culong)
        new(in_length, in_is_null, in_buffer, C_NULL, C_NULL, 0, 0, 0, in_buffer_length,
            0, 0, 0, 0, in_buffer_type, 0, 0, 0, 0, C_NULL)
    end

    function MYSQL_BIND(in_length::Ptr{Culong}, in_is_null::Ptr{Cchar}, in_buffer::Ptr{Void}, in_error::Ptr{Cchar}, in_row_ptr::Ptr{Cuchar},
            in_store_param_func::Ptr{Void}, in_fetch_result ::Ptr{Void}, in_skip_result ::Ptr{Void}, in_buffer_length::Culong,
            in_offset::Culong, in_length_value::Culong, in_param_number :: Cuint, in_pack_length :: Cuint, in_buffer_type :: Cint,
            in_error_value :: Cchar, in_is_unsigned :: Cchar, in_long_data_used :: Cchar, in_is_null_value :: Cchar,
            in_extension :: Ptr{Void} )
        new(in_length, in_is_null, in_buffer, in_error, in_row_ptr, in_store_param_func, in_fetch_result, in_skip_result, in_buffer_length,
            in_offset, in_length_value, in_param_number, in_pack_length, in_buffer_type, in_error_value, in_is_unsigned, in_long_data_used, 
            in_is_null_value, in_extension)
    end

    function MYSQL_BIND()
        new(C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, C_NULL)
    end
end

#=
type MYSQL_STMT
    mem_root::MEM_ROOT
    list::LIST
    mysql::MySQL5
    params::MYSQL_BIND
    bind::MYSQL_BIND
    fields::MYSQL_FIELD
    result::MYSQL_DATA
    data_cursor::MYSQL_ROWS

    affected_rows::Culongulong
    insert_id::Culongulong
    stmt_id::Culong
    flags::Culong
    prefetch_rows::Culong

    server_status::Cuint
    last_errno::Cuint
    param_count::Cuint
    field_count::Cuint
    state::Cuint
    last_error::Ptr{Cchar}
    sqlstate::Ptr{Cchar}
    send_types_to_server::Cint
    bind_param_done::Cint
    bind_result_done::Cuchar
    unbuffered_fetch_cancelled::Cint
    update_max_length::Cint
    extension::Ptr{Cuchar}
end
=#

"""
Options to be passed to mysql_options API.
"""
baremodule MYSQL_OPTION
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
