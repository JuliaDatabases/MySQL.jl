using Dates

"""
Julia wrapper for MySQL database handle. Used for passing to mysql_init,
mysql_real_connect, mysql_close etc.
"""
type MySQLDatabaseHandle
    ptr::Ptr{Cuchar}
    status::Cint
end

"""
Julia wrapper for MySQL statement handle. Used for prepared statement
API's.
"""
type MySQLStatementHandle
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
typealias MYSQL Ptr{Uint8}

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
Type mirroring MYSQL_TIME C struct.
"""
immutable MYSQL_TIME
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
immutable JU_MYSQL_BIND
    length::Array{Culong, 0}
    is_null::Array{Culong, 0}
    buffer_long::Array{Culong, 0}
    buffer_int::Array{Cint, 0}
    buffer_double::Array{Cdouble, 0}
    buffer_string::Array{Uint8, 1}
    buffer_datetime::Array{MYSQL_TIME, 0}
end

"""
Mirror to MYSQL_BIND struct in mysql_bind.h
"""
immutable MYSQL_BIND
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

    function MYSQL_BIND(in_length::Ptr{Culong}, in_is_null::Ptr{Cchar}, 
                        in_buffer::Ptr{Void}, in_buffer_length::Culong, in_buffer_type::Cint)
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

typealias MEM_ROOT Ptr{Uint8}
typealias LIST Ptr{Uint8}
typealias MYSQL_DATA Ptr{Uint8}
typealias MYSQL_ROWS Ptr{Uint8}

"""
Mirror to MYSQL_STMT struct in mysql.h
"""
type MYSQL_STMT
    mem_root::MEM_ROOT
    list::LIST
    mysql::MYSQL
    params::MYSQL_BIND
    bind::MYSQL_BIND
    fields::MYSQL_FIELD
    result::MYSQL_DATA
    data_cursor::MYSQL_ROWS

    affected_rows::Culong
    insert_id::Culong
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