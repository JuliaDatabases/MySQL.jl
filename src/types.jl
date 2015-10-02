using Dates

"""
The MySQL handle passed to C calls.
"""
typealias MYSQL Ptr{Void}

"""
The Pointer to result set for C calls.
"""
typealias MYSQL_RES Ptr{Void}

"""
The record that would be returned by mysql_fetch_row API.
"""
type MYSQL_ROW
    values :: Ptr{Ptr{Cuchar}} # pointer to an array of strings
end

"""
The field object that contains the metadata of the table. 
Returned by mysql_fetch_fields API.
"""
type MYSQL_FIELD
    name :: Ptr{Cchar}             ##  Name of column
    org_name :: Ptr{Cchar}         ##  Original column name, if an alias
    table :: Ptr{Cchar}            ##  Table of column if column was a field
    org_table :: Ptr{Cchar}        ##  Org table name, if table was an alias
    db :: Ptr{Cchar}               ##  Database for table
    catalog :: Ptr{Cchar}          ##  Catalog for table
    def :: Ptr{Cchar}              ##  Default value (set by mysql_list_fields)
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
immutable JULIA_MYSQL_BIND
# This should be a Union
    buffer_bit::Ptr{Cuchar}
    buffer_tiny::Ptr{Cchar}
    buffer_short::Ptr{Cshort}
    buffer_int::Ptr{Cint}
    buffer_long::Ptr{Clong}
    buffer_float::Ptr{Cfloat}
    buffer_double::Ptr{Cdouble}
    buffer_string::Ptr{Cuchar}
    buffer_datetime::Ptr{MYSQL_TIME}
    buffer_date::Ptr{MYSQL_TIME}
    buffer_time::Ptr{MYSQL_TIME}

    function JULIA_MYSQL_BIND(buff_str_len)
        new(pointer(Array(Cuchar)),
            pointer(Array(Cchar)),
            pointer(Array(Cshort)),
            pointer(Array(Cint)),
            pointer(Array(Clong)),
            pointer(Array(Cfloat)),
            pointer(Array(Cdouble)),
            pointer(Array(Cuchar, buff_str_len)), # buffer_string
            pointer(Array(MYSQL_TIME)),
            pointer(Array(MYSQL_TIME)),
            pointer(Array(MYSQL_TIME)), )
    end
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

    function MYSQL_BIND(in_buffer::Ptr{Void}, in_buffer_length::Culong, in_buffer_type::Cint)
        new(0, 0, in_buffer, C_NULL, C_NULL, 0, 0, 0, in_buffer_length,
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

typealias MEM_ROOT Ptr{Void}
typealias LIST Ptr{Void}
typealias MYSQL_DATA Ptr{Void}
typealias MYSQL_ROWS Ptr{Void}

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
