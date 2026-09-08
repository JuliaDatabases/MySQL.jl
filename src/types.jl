# The public value types and the 1.x result-type mapping (`MySQL.Bit`, `MySQL.DateAndTime`,
# `MySQL.juliatype`), kept byte-for-byte compatible with the Connector/C backend's mapping.

"""
    MySQL.Bit

The value of a `BIT(n)` column (`n ≤ 64`): the big-endian value of all bytes the server
sent, stored in `bits::UInt64`. (`MySQL.API.Bit` before 2.0.)
"""
struct Bit
    bits::UInt64
end
Base.string(b::Bit) = String(lstrip(bitstring(b.bits), '0'))
Base.show(io::IO, b::Bit) = print(io, "MySQL.Bit(\"$(string(b))\")")
Base.unsigned(::Type{Bit}) = Bit

"""
    MySQL.DateAndTime

A DATETIME/TIMESTAMP value with microsecond precision, as produced by
`mysql_date_and_time=true` (`Dates.DateTime` only carries milliseconds).
"""
struct DateAndTime <: Dates.AbstractDateTime
    date::Date
    time::Time
end

Dates.Date(x::DateAndTime) = x.date
Dates.Time(x::DateAndTime) = x.time
Dates.year(x::DateAndTime) = Dates.year(Date(x))
Dates.month(x::DateAndTime) = Dates.month(Date(x))
Dates.day(x::DateAndTime) = Dates.day(Date(x))
Dates.hour(x::DateAndTime) = Dates.hour(Time(x))
Dates.minute(x::DateAndTime) = Dates.minute(Time(x))
Dates.second(x::DateAndTime) = Dates.second(Time(x))
Dates.millisecond(x::DateAndTime) = Dates.millisecond(Time(x))
Dates.microsecond(x::DateAndTime) = Dates.microsecond(Time(x))

import Base.==
==(a::DateAndTime, b::DateAndTime) = ==(a.date, b.date) && ==(a.time, b.time)

@noinline dateandtime_warning() = @warn """a datetime value from a column has a microsecond precision > 3,
which cannot be represented by a `Dates.DateTime`; pass `mysql_date_and_time=true` to
`DBInterface.execute` or `DBInterface.prepare` to get `MySQL.DateAndTime` values that
preserve the full microsecond precision""" maxlog=1

# The wire type maps to a host type. DECIMAL uses an exact 256-bit coefficient.
function juliatype(field_type)
    t = UInt32(field_type)
    if t == P.MYSQL_TYPE_BIT
        return Bit
    elseif t == P.MYSQL_TYPE_TINY || t == P.MYSQL_TYPE_ENUM
        return Cchar
    elseif t == P.MYSQL_TYPE_SHORT
        return Cshort
    elseif t == P.MYSQL_TYPE_LONG || t == P.MYSQL_TYPE_INT24
        return Cint
    elseif t == P.MYSQL_TYPE_LONGLONG
        return Int64
    elseif t == P.MYSQL_TYPE_FLOAT
        return Cfloat
    elseif t == P.MYSQL_TYPE_DECIMAL || t == P.MYSQL_TYPE_NEWDECIMAL
        return DataDecimals.DecimalValue{DataDecimals.Int256}
    elseif t == P.MYSQL_TYPE_DOUBLE
        return Cdouble
    elseif t == P.MYSQL_TYPE_TINY_BLOB || t == P.MYSQL_TYPE_MEDIUM_BLOB ||
           t == P.MYSQL_TYPE_LONG_BLOB || t == P.MYSQL_TYPE_BLOB ||
           t == P.MYSQL_TYPE_GEOMETRY
        return Vector{UInt8}
    elseif t == P.MYSQL_TYPE_YEAR
        return Clong
    elseif t == P.MYSQL_TYPE_TIMESTAMP || t == P.MYSQL_TYPE_DATETIME
        return DateTime
    elseif t == P.MYSQL_TYPE_DATE
        return Date
    elseif t == P.MYSQL_TYPE_TIME
        return Dates.Time
    else
        return String
    end
end

# The unsigned counterpart of a wire-mapped base type (`===` branches over the closed set
# of types `juliatype` produces, so `--trim=safe` resolves it; `Base.unsigned(::Type)` on a
# runtime type would be a dynamic call).
@inline function unsigned_type(T::Type)::Type
    T === Cchar && return Cuchar
    T === Cshort && return Cushort
    T === Cint && return Cuint
    T === Int64 && return UInt64
    T === Clong && return Culong
    return T
end

"""
    MySQL.juliatype(field_type, notnullable, isunsigned, isbinary, date_and_time) -> Type

The Julia type a result column decodes to, given its wire type and flags: the 1.x mapping,
with exact DataDecimals values at 2.0 (unsigned integer widening, binary BLOB vs `String`, `DateAndTime` under
`mysql_date_and_time=true`, `Union{Missing, T}` for nullable columns).
"""
function juliatype(field_type, notnullable, isunsigned, isbinary, date_and_time)
    T = juliatype(field_type)
    T2 = isunsigned && !(T === Cfloat || T === Cdouble || T === Dec64) ? unsigned_type(T) : T
    T3 = !isbinary && T2 === Vector{UInt8} ? String : T2
    T4 = date_and_time && T3 === DateTime ? DateAndTime : T3
    return notnullable ? T4 : Union{Missing, T4}
end
