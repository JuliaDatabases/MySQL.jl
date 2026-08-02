struct Error <: Exception
    errno::Cuint
    msg::String
    Error(ptr) = new(mysql_errno(ptr), unsafe_string(mysql_error(ptr)))
end
Base.showerror(io::IO, e::Error) = print(io, "($(e.errno)): $(e.msg)")

# wraps a MYSQL opaque pointer
mutable struct MYSQL
    ptr::Ptr{Cvoid}
    # Statement/result handles whose Julia wrappers were garbage-collected before
    # being explicitly closed. mysql_stmt_close and mysql_free_result are not
    # client-side frees: they can write to / read from the connection's socket.
    # Finalizers run on whatever thread happens to trigger GC — concurrently with
    # an in-flight mysql_* call on another thread — and a MYSQL* is not
    # thread-safe, so finalizers must never call into libmariadb on a live
    # connection (https://github.com/JuliaDatabases/MySQL.jl/issues/220). They
    # park raw handles here instead; reap!() closes them from inside the next
    # user-initiated operation, which the caller already serializes with all
    # other use of the connection.
    reaplock::Threads.SpinLock       # guards the two vectors below and `closed`
    stmts_to_close::Vector{Ptr{Cvoid}}
    results_to_free::Vector{Ptr{Cvoid}}
    closed::Bool                     # set once mysql_close has run
    function MYSQL(ptr)
        ptr == C_NULL && error("error creating API.MYSQL structure; null pointer encountered; probably insufficient memory available")
        mysql = new(ptr, Threads.SpinLock(), Ptr{Cvoid}[], Ptr{Cvoid}[], false)
        finalizer(finalize_mysql, mysql)
        return mysql
    end
end

Error(mysql::MYSQL) = Error(mysql.ptr)

# Runs with x.reaplock held. Frees parked results first (flushing an un-drained
# result reads from the socket, which needs the connection alive), then parked
# statements, then the connection itself.
function _teardown(x::MYSQL)
    if x.ptr != C_NULL
        for p in x.results_to_free
            mysql_free_result(p)
        end
        empty!(x.results_to_free)
        for p in x.stmts_to_close
            mysql_stmt_close(p)
        end
        empty!(x.stmts_to_close)
        mysql_close(x.ptr)
        x.ptr = C_NULL
    end
    x.closed = true
    return
end

# GC finalizer for MYSQL. If the wrapper is unreachable no user call on this
# connection can be in flight, so the teardown I/O is single-threaded and safe.
# Finalizers may only trylock: if the lock is busy (another thread is mid-reap!),
# re-register and retry at a later GC — the pattern from the Julia manual for
# finalizers that need locks.
function finalize_mysql(x::MYSQL)
    if trylock(x.reaplock)
        try
            _teardown(x)
        finally
            unlock(x.reaplock)
        end
    else
        finalizer(finalize_mysql, x)
    end
    return
end

# Explicit close (DBInterface.close!(conn)). Blocking on the lock is fine here:
# finalizers only ever trylock, so there is no self-deadlock if GC runs while we
# hold it.
function close!(x::MYSQL)
    lock(x.reaplock)
    try
        _teardown(x)
    finally
        unlock(x.reaplock)
    end
    return
end

"""
    reap!(mysql::MYSQL)

Close statement handles and free result handles that were abandoned to the
garbage collector. Must be called from a user-initiated operation on the
connection, i.e. in a context the caller already serializes with all other use
of the connection — never from a finalizer.
"""
function reap!(x::MYSQL)
    # unlocked fast path: a stale answer just delays the reap to the next call
    isempty(x.stmts_to_close) && isempty(x.results_to_free) && return
    stmts = Ptr{Cvoid}[]
    results = Ptr{Cvoid}[]
    lock(x.reaplock)
    try
        append!(results, x.results_to_free)
        empty!(x.results_to_free)
        append!(stmts, x.stmts_to_close)
        empty!(x.stmts_to_close)
    finally
        unlock(x.reaplock)
    end
    # the socket-touching calls happen outside the spinlock; we're in the
    # caller's serialized context like any other mysql_* call
    for p in results
        mysql_free_result(p)
    end
    for p in stmts
        mysql_stmt_close(p)
    end
    return
end

# wraps a MYSQL_RES opaque pointer
mutable struct MYSQL_RES
    ptr::Ptr{Cvoid}
    conn::MYSQL
    function MYSQL_RES(ptr, conn::MYSQL)
        res = new(ptr, conn)
        if ptr != C_NULL
            finalizer(finalize_result, res)
        end
        return res
    end
end

# GC finalizer for MYSQL_RES: park the handle for reap!() instead of calling
# mysql_free_result, which may read pending rows off the shared socket.
function finalize_result(x::MYSQL_RES)
    x.ptr == C_NULL && return
    conn = x.conn
    if trylock(conn.reaplock)
        try
            if !conn.closed
                push!(conn.results_to_free, x.ptr)
            end
            # if the connection is already closed, mysql_free_result on an
            # un-drained result would read through the freed MYSQL* — leak the
            # handle rather than touch freed memory
            x.ptr = C_NULL
        finally
            unlock(conn.reaplock)
        end
    else
        finalizer(finalize_result, x)
    end
    return
end

# immediate free, for explicit cleanup from user-serialized contexts; the still-
# registered finalizer becomes a no-op once ptr is C_NULL
function free!(x::MYSQL_RES)
    if x.ptr != C_NULL
        mysql_free_result(x.ptr)
        x.ptr = C_NULL
    end
    return
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
    conn::MYSQL
    function MYSQL_STMT(ptr, conn::MYSQL)
        ptr == C_NULL && error("error creating API.MYSQL_STMT structure; null pointer encountered; probably insufficient memory available")
        stmt = new(ptr, conn)
        finalizer(finalize_stmt, stmt)
        return stmt
    end
end

# GC finalizer for MYSQL_STMT: park the handle for reap!() instead of calling
# mysql_stmt_close, which sends COM_STMT_CLOSE over the shared socket.
function finalize_stmt(x::MYSQL_STMT)
    x.ptr == C_NULL && return
    conn = x.conn
    if trylock(conn.reaplock)
        try
            if conn.closed
                # mysql_close already invalidated the statement handles, so this
                # is a purely local free — no socket I/O
                mysql_stmt_close(x.ptr)
            else
                push!(conn.stmts_to_close, x.ptr)
            end
            x.ptr = C_NULL
        finally
            unlock(conn.reaplock)
        end
    else
        finalizer(finalize_stmt, x)
    end
    return
end

# immediate close, for explicit cleanup (DBInterface.close!(stmt)) from user-
# serialized contexts; the still-registered finalizer becomes a no-op once ptr
# is C_NULL
function close!(x::MYSQL_STMT)
    if x.ptr != C_NULL
        mysql_stmt_close(x.ptr)
        x.ptr = C_NULL
    end
    return
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
isunsigned(field) = (field.flags & NUM_FLAG) > 0 && (field.flags & UNSIGNED_FLAG) > 0
isbinary(field) = (field.flags & BINARY_FLAG) > 0

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

@noinline dateandtime_warning() = @warn """a datetime value from a column has a microsecond precision > 3,
by default, MySQL.jl attempts to return a DateTime object, which only supports millisecond precision.
To avoid loss in precision or InexactErrors, pass `mysql_date_and_time=true` to `DBInterface.execute(stmt, sql; mysql_date_and_time=true)` or `DBInterface.prepare(stmt, sql; mysql_date_and_time=true)`.
This will result in a column element type of `DateAndTime`, which is a simple struct of separate Date and Time parts, accessed like `dt.date` and `dt.time`.
"""

function Base.convert(::Type{DateTime}, mtime::MYSQL_TIME)
    millis, micros = divrem(mtime.second_part, 1000)
    if mtime.year == 0 || mtime.month == 0 || mtime.day == 0
        dt = DateTime(1970, 1, 1,
                 mtime.hour, mtime.minute, mtime.second, millis)
    else
        dt = DateTime(mtime.year, mtime.month, mtime.day,
                 mtime.hour, mtime.minute, mtime.second, millis)
    end
    micros > 0 && dateandtime_warning()
    return dt
end
Base.convert(::Type{Dates.Time}, mtime::MYSQL_TIME) =
    Dates.Time(mtime.hour, mtime.minute, mtime.second, divrem(mtime.second_part, 1000)...)
Base.convert(::Type{Date}, mtime::MYSQL_TIME) =
    Date(mtime.year, mtime.month, mtime.day)
Base.convert(::Type{DateAndTime}, mtime::MYSQL_TIME) =
    DateAndTime(Date(mtime.year, mtime.month, mtime.day),
                Time(mtime.hour, mtime.minute, mtime.second, divrem(mtime.second_part, 1000)...))

Base.convert(::Type{MYSQL_TIME}, t::Dates.Time) =
    MYSQL_TIME(0, 0, 0, Dates.hour(t), Dates.minute(t), Dates.second(t), Dates.millisecond(t) * 1000 + Dates.microsecond(t), 0, 0)
Base.convert(::Type{MYSQL_TIME}, dt::Date) =
    MYSQL_TIME(Dates.year(dt), Dates.month(dt), Dates.day(dt), 0, 0, 0, 0, 0, 0)

Base.convert(::Type{MYSQL_TIME}, dtime::DateTime) =
    MYSQL_TIME(Dates.year(dtime), Dates.month(dtime), Dates.day(dtime),
               Dates.hour(dtime), Dates.minute(dtime), Dates.second(dtime), Dates.millisecond(dtime) * 1000, 0, 0)

Base.convert(::Type{MYSQL_TIME}, dat::DateAndTime) =
    MYSQL_TIME(Dates.year(dat), Dates.month(dat), Dates.day(dat),
               Dates.hour(dat), Dates.minute(dat), Dates.second(dat), Dates.millisecond(dat) * 1000 + Dates.microsecond(dat), 0, 0)

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

