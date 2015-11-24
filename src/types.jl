"""
The MySQL handle.
"""
type MySQLHandle
    mysqlptr::Ptr{Void}
    host::AbstractString
    user::AbstractString
    db::AbstractString
end

function Base.show(io::IO, hndl::MySQLHandle)
    if hndl.mysqlptr == C_NULL
        print(io, "Null MySQL Handle")
    else
        print(io, """MySQL Handle
------------
Host: $(hndl.host)
User: $(hndl.user)
DB:   $(hndl.db)
""")
    end
end

"""
The Pointer to result set for C calls.
"""
typealias MYSQL_RES Ptr{Void}

"""
The record that would be returned by mysql_fetch_row API.
"""
typealias MYSQL_ROW Ptr{Ptr{Cchar}} # pointer to an array of strings

typealias MYSQL_TYPE UInt32

"""
The field object that contains the metadata of the table. 
Returned by mysql_fetch_fields API.
"""
immutable MYSQL_FIELD
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
    timetype::Cuint
end

export MYSQL_TIME

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

    function MYSQL_BIND(buff::Ptr{Void}, bufflen, bufftype)
        new(0, 0, buff, C_NULL, C_NULL, 0, 0, 0, convert(Culong, bufflen),
            0, 0, 0, 0, bufftype, 0, 0, 0, 0, C_NULL)
    end

    function MYSQL_BIND(arr::Array, bufftype)
        MYSQL_BIND(convert(Ptr{Void}, pointer(arr)), sizeof(arr), bufftype)
    end

    function MYSQL_BIND(str::AbstractString, bufftype)
        MYSQL_BIND(convert(Ptr{Void}, pointer(str)), sizeof(str), bufftype)
    end
end

typealias MEM_ROOT Ptr{Void}
typealias LIST Ptr{Void}
typealias MYSQL_DATA Ptr{Void}

"""
Mirror to MYSQL_ROWS struct in mysql.h
"""
type MYSQL_ROWS
    next::Ptr{MYSQL_ROWS}
    data::MYSQL_ROW
    length::Culong
end

"""
Mirror to MYSQL_STMT struct in mysql.h
"""
immutable MYSQL_STMT # This is different in mariadb header file.
    mem_root::MEM_ROOT
    list::LIST
    mysql::Ptr{Void}
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

"""
The MySQL Statement Handle.
"""
type MySQLStatementHandle
    stmtptr::Ptr{MYSQL_STMT}
end

function Base.show(io::IO, hndl::MySQLStatementHandle)
    if hndl.stmtptr == C_NULL
        print(io, "Null MySQL Statement Handle")
    else
        print(io, """MySQL Statement Handle""")
    end
end


"""
Iterator for the mysql result (MYSQL_RES).
"""
type MySQLRowIterator
    result::MYSQL_RES
    row::Tuple
    jfield_types::Array{Type, 1}
    rowsleft::Int64
end

export MySQLHandle, MYSQL_RES, MYSQL_ROW, MYSQL_TYPE, MYSQL_FIELD, MySQLRowIterator,
       MYSQL_STMT, MYSQL_TIME, MYSQL_BIND, MySQLStatementHandle
