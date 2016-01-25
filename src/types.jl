typealias MEM_ROOT Ptr{Void}
typealias LIST Ptr{Void}
typealias MYSQL_DATA Ptr{Void}
typealias MYSQL_RES Ptr{Void}
typealias MYSQL_ROW Ptr{Ptr{Cchar}}  # pointer to an array of strings
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

"""
Mirror to MYSQL_ROWS struct in mysql.h
"""
immutable MYSQL_ROWS
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
The MySQL handle.
"""
type MySQLHandle
    mysqlptr::Ptr{Void}
    host::AbstractString
    user::AbstractString
    db::AbstractString
    stmtptr::Ptr{MYSQL_STMT}
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

type MySQLResult
    con::MySQLHandle
    resptr::MYSQL_RES
end

"""
Iterator for the mysql result.
"""
type MySQLRowIterator
    result::MySQLResult
    jtypes::Array{Type, 1}
    is_nullables::Array{Bool, 1}
    rowsleft::Int64
end

"""
Iterator for prepared statement results.
"""
type MySQLStatementIterator
    hndl::MySQLHandle
    jtypes::Array{Type, 1}
    is_nullables::Array{Bool, 1}
    binding::Array{MYSQL_BIND, 1}
end

abstract MySQLError

# For errors that happen in the MySQL C connector
type MySQLInternalError <: MySQLError
    con::Ptr{Void}

    function MySQLInternalError(con::MySQLHandle)
        new(con.mysqlptr)
    end

    function MySQLInternalError(ptr)
        new(ptr)
    end
end

Base.showerror(io::IO, e::MySQLInternalError) = print(io, bytestring(mysql_error(e.con)))

# Internal errors that happen when using prepared statements
type MySQLStatementError <: MySQLError
    stmt::Ptr{MYSQL_STMT}

    function MySQLStatementError(hndl::MySQLHandle)
        new(hndl.stmtptr)
    end

    function MySQLStatementError(ptr)
        new(ptr)
    end
end

Base.showerror(io::IO, e::MySQLStatementError) =
    print(io, bytestring(mysql_stmt_error(e.stmt)))

# For errors that happen in MySQL.jl
type MySQLInterfaceError <: MySQLError
    msg::AbstractString
end

Base.showerror(io::IO, e::MySQLInterfaceError) = print(io, e.msg)

type MySQLMetadata
    names::Array{AbstractString, 1}
    mtypes::Array{MYSQL_TYPE, 1}
    jtypes::Array{Type, 1}
    lens::Array{Int, 1}
    is_nullables::Array{Bool, 1}
    nfields::Int

    function MySQLMetadata(fields::Array{MYSQL_FIELD, 1})
        nfields = length(fields)
        names = Array(AbstractString, nfields)
        mtypes = Array(MYSQL_TYPE, nfields)
        jtypes = Array(Type, nfields)
        lens = Array(Int, nfields)
        is_nullables = Array(Bool, nfields)
        for i in 1:nfields
            names[i] = bytestring(fields[i].name)
            mtypes[i] = fields[i].field_type
            jtypes[i] = mysql_get_julia_type(fields[i].field_type)
            lens[i] = fields[i].field_length
            is_nullables[i] = mysql_is_nullable(fields[i])
        end
        new(names, mtypes, jtypes, lens, is_nullables, nfields)
    end
end

export MySQLHandle, MySQLResult, MySQLRowIterator,
       MySQLInternalError, MySQLStatementError,
       MySQLInterfaceError, MySQLMetadata, MySQLStatementIterator
