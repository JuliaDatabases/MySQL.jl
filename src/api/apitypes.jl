struct Error <: Exception
    errno::Cuint
    msg::String
    Error(ptr) = new(mysql_errno(ptr), unsafe_string(mysql_error(ptr)))
end
Base.showerror(io::IO, e::Error) = print(io, "($(e.errno)): $(e.msg)")

# wraps a MYSQL opaque pointer
mutable struct MYSQL
    ptr::Ptr{Cvoid}
    function MYSQL(ptr)
        ptr == C_NULL && error("error creating API.MYSQL structure; null pointer encountered; probably insufficient memory available")
        mysql = new(ptr)
        finalizer(mysql) do x
            if x.ptr != C_NULL
                mysql_close(x.ptr)
                x.ptr = C_NULL
            end
        end
        return mysql
    end
end

Error(mysql::MYSQL) = Error(mysql.ptr)

# wraps a MYSQL_RES opaque pointer
mutable struct MYSQL_RES
    ptr::Ptr{Cvoid}
    function MYSQL_RES(ptr)
        res = new(ptr)
        if ptr != C_NULL
            finalizer(x -> mysql_free_result(x.ptr), res)
        end
        return res
    end
end

struct StmtError <: Exception
    errno::Cuint
    msg::String
    StmtError(ptr) = new(mysql_stmt_errno(ptr), unsafe_string(mysql_stmt_error(ptr)))
end
Base.showerror(io::IO, e::StmtError) = print(io, "($(e.errno)): $(e.msg)")

# wraps a MYSQL_STMT opaque pointer
mutable struct MYSQL_STMT
    ptr::Ptr{Cvoid}
    function MYSQL_STMT(ptr)
        ptr == C_NULL && error("error creating API.MYSQL_STMT structure; null pointer encountered; probably insufficient memory available")
        stmt = new(ptr)
        finalizer(stmt) do x
            if x.ptr != C_NULL
                mysql_stmt_close(x.ptr)
                x.ptr = C_NULL
            end
        end
        return stmt
    end
end

StmtError(stmt::MYSQL_STMT) = StmtError(stmt.ptr)

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
notnullable(field) = (field.flags & NOT_NULL_FLAG) > 0
isunsigned(field) = (field.flags & UNSIGNED_FLAG) > 0

const MYSQL_FIELD_OFFSET = Cuint
const MYSQL_ROW = Ptr{Ptr{UInt8}}

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

const MYSQL_TIME_FORMAT = Dates.DateFormat("HH:MM:SS.s")
const MYSQL_DATE_FORMAT = Dates.DateFormat("yyyy-mm-dd")
const MYSQL_DATETIME_FORMAT = Dates.DateFormat("yyyy-mm-dd HH:MM:SS.s")

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

# this is a helper struct, because MYSQL_BIND needs
# to know where the bound data should live, by using this helper
# we can bind the data buffer once and early,
# as well as make sure we keep a reference to the bound value
# between bind-time and execute-time
# note that the struct is lazily initialized by only setting
# one field for whatever type of value is being bound
mutable struct BindHelper
    typeset::Bool
    length::Vector{Culong}
    is_null::Vector{Cchar}
    uint8::Vector{UInt8}
    uint16::Vector{UInt16}
    uint32::Vector{UInt32}
    uint64::Vector{UInt64}
    float::Vector{Float32}
    double::Vector{Float64}
    time::Vector{MYSQL_TIME}
    blob::Vector{UInt8}
    string::String
    BindHelper() = new(false, [Culong(0)], [Cchar(0)])
end

struct MYSQL_BIND
    length::Ptr{Culong}
    is_null::Ptr{Cchar}
    buffer::Ptr{Cvoid}
    error::Ptr{Cchar}
    row_ptr::Ptr{Cvoid}
    store_param_func::Ptr{Cvoid}
    fetch_result::Ptr{Cvoid}
    skip_result::Ptr{Cvoid}
    buffer_length::Culong
    offset::Culong
    length_value::Culong
    flags::Cuint
    pack_length::Cuint
    buffer_type::Cint
    error_value::Cchar
    is_unsigned::Cchar
    long_data_used::Cchar
    is_null_value::Cchar
    extension::Ptr{Cvoid}

    function MYSQL_BIND(length::Vector{Culong}, is_null::Vector{Cchar})
        new(pointer(length), pointer(is_null), C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL,
            Culong(0), Culong(0), Culong(0), Cuint(0), Cuint(0), Cint(0),
            Cchar(0), Cchar(0), Cchar(0), Cchar(0), C_NULL)
    end
end

# what's this you may ask? mutating functions on an immutable struct?
# indeed, but before you turn me into the JuliaLang police, here me out
# we only ever allocate arrays of MYSQL_BIND structs, which consists of addressable
# memory that we hold a reference to for the lifetime of each MYSQL_BIND instance
# hence, with some field offset calculations, we know the exact memory addresses of fields
# we need to set. Why not make MYSQL_BIND mutable you may ask? well, because we have to
# bind an entire *array* of MYSQL_BIND, a mutable struct wouldn't be stored inline in the Julia array
# which would violate what the C library is expecting when the array of MYSQL_BINDs are bound
setbuffer!(ptr, x) = unsafe_store!(convert(Ptr{Ptr{Cvoid}}, ptr), convert(Ptr{Cvoid}, x), 3)
setbufferlength!(ptr, x) = unsafe_store!(convert(Ptr{Culong}, ptr), x, div(8 * sizeof(Ptr) + sizeof(Culong), sizeof(Culong)))
setbuffertype!(ptr, x) = unsafe_store!(convert(Ptr{Cint}, ptr), x, div(8 * sizeof(Ptr) + 3 * sizeof(Culong) + 2 * sizeof(Cuint) + 4, 4))
setisunsigned!(ptr, x) = unsafe_store!(convert(Ptr{Cchar}, ptr), x, 8 * sizeof(Ptr) + 3 * sizeof(Culong) + 2 * sizeof(Cuint) + sizeof(Cint) + 2)

