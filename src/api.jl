module API

using Dates, DecFP

# Load libmariadb from our deps.jl
const depsjl_path = joinpath(dirname(@__FILE__), "..", "deps", "deps.jl")
if !isfile(depsjl_path)
    error("MySQL not installed properly, run Pkg.build(\"MySQL\"), restart Julia and try again")
end
include(depsjl_path)

include("consts.jl")

const MEM_ROOT = Ptr{Cvoid}
const LIST = Ptr{Cvoid}
const MYSQL_DATA = Ptr{Cvoid}
const MYSQL_RES = Ptr{Cvoid}
const MYSQL_ROW = Ptr{Ptr{Cchar}}  # pointer to an array of strings
const MYSQL_TYPE = UInt32

"""
The field object that contains the metadata of the table. 
Returned by mysql_fetch_fields API.
"""
struct MYSQL_FIELD
    name::Ptr{Cchar}             ##  Name of column
    org_name::Ptr{Cchar}         ##  Original column name, if an alias
    table::Ptr{Cchar}            ##  Table of column if column was a field
    org_table::Ptr{Cchar}        ##  Org table name, if table was an alias
    db::Ptr{Cchar}               ##  Database for table
    catalog::Ptr{Cchar}          ##  Catalog for table
    def::Ptr{Cchar}              ##  Default value (set by mysql_list_fields)
    length::Culong               ##  Width of column (create length)
    max_length::Culong           ##  Max width for selected set
    name_length::Cuint
    org_name_length::Cuint
    table_length::Cuint
    org_table_length::Cuint
    db_length::Cuint
    catalog_length::Cuint
    def_length::Cuint
    flags::Cuint                 ##  Div flags
    decimals::Cuint              ##  Number of decimals in field
    charsetnr::Cuint             ##  Character set
    field_type::Cuint            ##  Type of field. See mysql_com.h for types
    extension::Ptr{Cvoid}
end
notnullable(field) = (field.flags & API.NOT_NULL_FLAG) > 0
isunsigned(field) = (field.flags & API.UNSIGNED_FLAG) > 0

"""
Type mirroring MYSQL_TIME C struct.
"""
struct MYSQL_TIME
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

import Base.==

const MYSQL_DATE_FORMAT = Dates.DateFormat("yyyy-mm-dd")
const MYSQL_DATETIME_FORMAT = Dates.DateFormat("yyyy-mm-dd HH:MM:SS.s")

mysql_time(str) = Dates.Time(map(x->parse(Int, x), split(str, ':'))...)
mysql_date(str) = Dates.Date(str, MYSQL_DATE_FORMAT)
mysql_datetime(str) = Dates.DateTime(occursin(" ", str) ? str : "1970-01-01 " * str, MYSQL_DATETIME_FORMAT)
export mysql_time, mysql_date, mysql_datetime

function Base.convert(::Type{DateTime}, mtime::MYSQL_TIME)
    if mtime.year == 0 || mtime.month == 0 || mtime.day == 0
        DateTime(1970, 1, 1,
                 mtime.hour, mtime.minute, mtime.second)
    else
        DateTime(mtime.year, mtime.month, mtime.day,
                 mtime.hour, mtime.minute, mtime.second)
    end
end
Base.convert(::Type{Dates.Time}, mtime::MYSQL_TIME) =
    Dates.Time(mtime.hour, mtime.minute, mtime.second)
Base.convert(::Type{Date}, mtime::MYSQL_TIME) =
    Date(mtime.year, mtime.month, mtime.day)

Base.convert(::Type{MYSQL_TIME}, t::Dates.Time) =
    MYSQL_TIME(0, 0, 0, Dates.hour(t), Dates.minute(t), Dates.second(t), 0, 0, 0)
Base.convert(::Type{MYSQL_TIME}, dt::Date) =
    MYSQL_TIME(Dates.year(dt), Dates.month(dt), Dates.day(dt), 0, 0, 0, 0, 0, 0)

function Base.convert(::Type{MYSQL_TIME}, dtime::DateTime)
    if Dates.year(dtime) == 1970 && Dates.month(dtime) == 1 && Dates.day(dtime) == 1
        MYSQL_TIME(0, 0, 0,
                   Dates.hour(dtime), Dates.minute(dtime), Dates.second(dtime), 0, 0, 0)
    else
        MYSQL_TIME(Dates.year(dtime), Dates.month(dtime), Dates.day(dtime),
                   Dates.hour(dtime), Dates.minute(dtime), Dates.second(dtime), 0, 0, 0)
    end
end

"""
Mirror to MYSQL_BIND struct in mysql_bind.h
"""
struct MYSQL_BIND
    length::Ptr{Culong}
    is_null::Ptr{Cchar}
    buffer::Ptr{Cvoid}
    error::Ptr{Cchar}
    row_ptr::Ptr{Cuchar}
    store_param_func::Ptr{Cvoid}
    fetch_result::Ptr{Cvoid}
    skip_result::Ptr{Cvoid}
    buffer_length::Culong 
    offset::Culong 
    length_value::Culong
    param_number::Cuint
    pack_length::Cuint
    buffer_type::Cint
    error_value::Cchar
    is_unsigned::Cchar
    long_data_used::Cchar
    is_null_value::Cchar
    extension::Ptr{Cvoid}

    function MYSQL_BIND(buff::Ptr{Cvoid}, bufflen, bufftype)
        new(0, 0, buff, C_NULL, C_NULL, 0, 0, 0, convert(Culong, bufflen),
            0, 0, 0, 0, bufftype, 0, 0, 0, 0, C_NULL)
    end
end

function MYSQL_BIND(arr, bufftype)
    MYSQL_BIND(convert(Ptr{Cvoid}, pointer(arr)), sizeof(arr), bufftype)
end

"""
Mirror to MYSQL_ROWS struct in mysql.h
"""
struct MYSQL_ROWS
    next::Ptr{MYSQL_ROWS}
    data::MYSQL_ROW
    length::Culong
end

"""
Mirror to MYSQL_STMT struct in mysql.h
"""
struct MYSQL_STMT # This is different in mariadb header file.
    mem_root::MEM_ROOT
    list::LIST
    mysql::Ptr{Cvoid}
    params::MYSQL_BIND
    bind::MYSQL_BIND
    fields::MYSQL_FIELD
    result::MYSQL_DATA
    data_cursor::MYSQL_ROWS

    affected_rows::Culonglong
    insert_id::Culonglong
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

macro c(func, ret, args, vals...)
    if Sys.iswindows()
        esc(quote
            ret = ccall( ($func, libmariadb), stdcall, $ret, $args, $(vals...))
        end)
    else
        esc(quote
            ret = ccall( ($func, libmariadb),          $ret, $args, $(vals...))
        end)
    end
end

# function  mysql_library_init(argc=0, argv=C_NULL, groups=C_NULL)
#     return ccall((:mysql_library_init, libmariadb),
#                  Cint,
#                  (Cint, Ptr{Ptr{UInt8}}, Ptr{Ptr{UInt8}}),
#                  argc, argv, groups)
# end

# function  mysql_library_end()
#     return ccall((:mysql_library_end, libmariadb),
#                  Cvoid,
#                  (),
#                 )
# end

"""
Initializes the MYSQL object. Must be called before mysql_real_connect.
Memory allocated by mysql_init can be freed with mysql_close.
"""
function mysql_init(mysqlptr::Ptr{Cvoid})
    return @c(:mysql_init,
                 Ptr{Cvoid},
                 (Ptr{Cuchar}, ),
                 mysqlptr)
end

"""
Used to connect to database server. Returns a MYSQL handle on success and
C_NULL on failure.
"""
function mysql_real_connect(mysqlptr::Ptr{Cvoid},
                              host::String,
                              user::String,
                              passwd::String,
                              db::String,
                              port::Cuint,
                              unix_socket::String,
                              client_flag::UInt32)

    return @c(:mysql_real_connect,
                 Ptr{Cvoid},
                 (Ptr{Cvoid},
                  Ptr{Cuchar},
                  Ptr{Cuchar},
                  Ptr{Cuchar},
                  Ptr{Cuchar},
                  Cuint,
                  Ptr{Cuchar},
                  Culong),
                 mysqlptr,
                 host,
                 user,
                 passwd,
                 db,
                 port,
                 unix_socket,
                 client_flag)
end

function mysql_options(mysqlptr::Ptr{Cvoid},
                        option_type::Cuint,
                        option::Ptr{Cvoid})
    return @c(:mysql_options,
                 Cint,
                 (Ptr{Cuchar},
                  Cint,
                  Ptr{Cuchar}),
                 mysqlptr,
                 option_type,
                 option)
end

mysql_options(mysqlptr, option_type, option::String) =
    mysql_options(mysqlptr, option_type, convert(Ptr{Cvoid}, pointer(option)))

function mysql_options(mysqlptr, option_type, option)
    v = [option]
    return mysql_options(mysqlptr, option_type, convert(Ptr{Cvoid}, pointer(v)))
end

"""
Close an opened MySQL connection.
"""
function mysql_close(mysqlptr::Ptr{Cvoid})
    return @c(:mysql_close,
                 Cvoid,
                 (Ptr{Cuchar}, ),
                 mysqlptr)
end

"""
Returns the error number of the last API call.
"""
function mysql_errno(mysqlptr::Ptr{Cvoid})
    return @c(:mysql_errno,
                 Cuint,
                 (Ptr{Cuchar}, ),
                 mysqlptr)
end

"""
Returns a string of the last error message of the most recent function call.
If no error occured and empty string is returned.
"""
function mysql_error(mysqlptr::Ptr{Cvoid})
    return @c(:mysql_error,
                 Ptr{Cuchar},
                 (Ptr{Cuchar}, ),
                 mysqlptr)
end

"""
Executes the prepared query associated with the statement handle.
"""
function mysql_stmt_execute(stmtptr)
    return @c(:mysql_stmt_execute,
                 Cint,
                 (Ptr{Cuchar}, ),
                 stmtptr)
end

"""
Closes the prepared statement.
"""
function mysql_stmt_close(stmtptr)
    return @c(:mysql_stmt_close,
                 Cchar,
                 (Ptr{Cuchar}, ),
                 stmtptr)
end

function mysql_insert_id(mysqlptr::Ptr{Cvoid})
    return @c(:mysql_insert_id,
                 Int64,
                 (Ptr{Cuchar}, ),
                 mysqlptr)
end

"""
Creates the sql string where the special chars are escaped
"""
function mysql_real_escape_string(mysqlptr::Ptr{Cvoid},
                                  to::Vector{Cuchar},
                                  from::String,
                                  length::Culong)
    return @c(:mysql_real_escape_string,
                 Cuint,
                 (Ptr{Cuchar},
                  Ptr{Cuchar},
                  Ptr{Cuchar},
                  Culong),
                 mysqlptr,
                 to,
                 from,
                 length)
end

"""
Creates a mysql_stmt handle. Should be closed with mysql_close_stmt
"""
function mysql_stmt_init(mysqlptr::Ptr{Cvoid})
    return @c(:mysql_stmt_init,
                 Ptr{MYSQL_STMT},
                 (Ptr{Cvoid}, ),
                 mysqlptr)
end

function mysql_stmt_prepare(stmtptr, s::String)
    return @c(:mysql_stmt_prepare,
                 Cint,
                 (Ptr{Cvoid}, Ptr{Cchar}, Culong),
                 stmtptr,      s,        length(s))
end

"""
Returns the error message for the recently invoked statement API
"""
function mysql_stmt_error(stmtptr)
    return @c(:mysql_stmt_error,
                 Ptr{Cuchar},
                 (Ptr{Cuchar}, ),
                 stmtptr)
end

"""
Store the entire result returned by the prepared statement in the
bind datastructure provided by mysql_stmt_bind_result.
"""
function mysql_stmt_store_result(stmtptr)
    return @c(:mysql_stmt_store_result,
                 Cint,
                 (Ptr{Cuchar}, ),
                 stmtptr)
end

"""
Return the metadata for the results that will be received from
the execution of the prepared statement.
"""
function mysql_stmt_result_metadata(stmtptr)
    return @c(:mysql_stmt_result_metadata,
                 MYSQL_RES,
                 (Ptr{MYSQL_STMT}, ),
                 stmtptr)
end

"""
Equivalent of `mysql_num_rows` for prepared statements.
"""
function mysql_stmt_num_rows(stmtptr)
    return @c(:mysql_stmt_num_rows,
                 Clong,
                 (Ptr{Cuchar}, ),
                 stmtptr)
end

"""
Equivalent of `mysql_fetch_row` for prepared statements.
"""
function mysql_stmt_fetch(stmtptr)
    return @c(:mysql_stmt_fetch,
                 Cint,
                 (Ptr{Cuchar}, ),
                 stmtptr)
end

"""
Bind the returned data from execution of the prepared statement
to a preallocated datastructure `bind`.
"""
function mysql_stmt_bind_result(stmtptr, bind::Ptr{MYSQL_BIND})
    return @c(:mysql_stmt_bind_result,
                 Cchar,
                 (Ptr{Cuchar}, Ptr{Cuchar}),
                 stmtptr,
                 bind)
end

function mysql_query(mysqlptr::Ptr{Cvoid}, sql::String)
    return @c(:mysql_query,
                 Cint,
                 (Ptr{Cvoid}, Ptr{UInt8}),
                 mysqlptr,
                 sql)
end

function mysql_store_result(mysqlptr::Ptr{Cvoid})
    return @c(:mysql_store_result,
                 MYSQL_RES,
                 (Ptr{Cvoid}, ),
                 mysqlptr)
end

"""
Returns the field metadata.
"""
function mysql_fetch_fields(results::MYSQL_RES)
    return @c(:mysql_fetch_fields,
                 Ptr{MYSQL_FIELD},
                 (MYSQL_RES, ),
                 results)
end


"""
Returns the row from the result set.
"""
function mysql_fetch_row(results::MYSQL_RES)
    return @c(:mysql_fetch_row,
                 MYSQL_ROW,
                 (MYSQL_RES, ),
                 results)
end

"""
Frees the result set.
"""
function mysql_free_result(results)
    return @c(:mysql_free_result,
                 Ptr{Cuchar},
                 (MYSQL_RES, ),
                 results.ptr)
end

"""
Returns the number of fields in the result set.
"""
function mysql_num_fields(results::MYSQL_RES)
    return @c(:mysql_num_fields,
                 Cuint,
                 (MYSQL_RES, ),
                 results)
end

"""
Returns the number of records from the result set.
"""
function mysql_num_rows(results::MYSQL_RES)
    return @c(:mysql_num_rows,
                 Clong,
                 (MYSQL_RES, ),
                 results)
end

"""
Returns the # of affected rows in case of insert / update / delete.
"""
function mysql_affected_rows(results::MYSQL_RES)
    return @c(:mysql_affected_rows,
                 Culong,
                 (MYSQL_RES, ),
                 results)
end

"""
Set the auto commit mode.
"""
function mysql_autocommit(mysqlptr::Ptr{Cvoid}, mode::Cchar)
    return @c(:mysql_autocommit,
                 Cchar, (Ptr{Cvoid}, Cchar),
                 mysqlptr, mode)
end

"""
Used to get the next result while executing multi query. Returns 0 on success
and more results are present. Returns -1 on success and no more results. Returns
positve on error.
"""
function mysql_next_result(mysqlptr::Ptr{Cvoid})
    return @c(:mysql_next_result,
                 Cint, (MYSQL_RES, ),
                 mysqlptr)
end

"""
Returns the number of columns for the most recent query on the connection.
"""
function mysql_field_count(mysqlptr::Ptr{Cvoid})
    return @c(:mysql_field_count,
                 Cuint, (Ptr{Cvoid}, ), mysqlptr)
end

function mysql_stmt_param_count(stmt)
    return @c(:mysql_stmt_param_count,
                 Culong, (Ptr{MYSQL_STMT}, ), stmt)
end

"""
This API is used to bind input data for the parameter markers in the SQL
 statement that was passed to `mysql_stmt_prepare()`. It uses `MYSQL_BIND`
 structures to supply the data. `bind` is the address of an array of `MYSQL_BIND`
 structures. The client library expects the array to contain one element for
 each ? parameter marker that is present in the query.
"""
function mysql_stmt_bind_param(stmt, bind::Ptr{MYSQL_BIND})
    return @c(:mysql_stmt_bind_param,
                 Cuchar, (Ptr{MYSQL_STMT}, Ptr{MYSQL_BIND}, ),
                 stmt, bind)
end

"""
Returns number of affected rows for prepared statement. `mysql_stmt_execute` must
 be called before this.
"""
function mysql_stmt_affected_rows(stmt)
    return @c(:mysql_stmt_affected_rows,
                 Culong, (Ptr{Cvoid}, ), stmt)
end

end # module
