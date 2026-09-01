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

# The server's own DECIMAL limits; they bound the `Decimal{P,S,T}` a column definition can name.
const MAX_DECIMAL_PRECISION = 65
const MAX_DECIMAL_SCALE = 30

# `DECIMAL` with no `(M, D)` is `DECIMAL(10, 0)`; the metadata-free `juliatype(field_type)`
# has no column to read a precision and scale from and answers with that default.
const DEFAULT_DECIMAL_PRECISION = 10
const DEFAULT_DECIMAL_SCALE = 0

"""
    MySQL.decimaltype(precision, scale) -> Type{<:Decimals.Decimal}

`Decimal{precision, scale, T}` with the storage integer of the precision tier: `Int32` up to
9 digits, `Int64` up to 18, `Int128` up to 38, `Int256` beyond. The server's maximum
precision is 65, so `Int256` always suffices.
"""
function decimaltype(precision::Int, scale::Int)
    precision <= 9 && return Decimals.Decimal{precision, scale, Int32}
    precision <= 18 && return Decimals.Decimal{precision, scale, Int64}
    precision <= 38 && return Decimals.Decimal{precision, scale, Int128}
    return Decimals.Decimal{precision, scale, Decimals.Int256}
end

# The precision a DECIMAL column definition names. The server sends the *display* length,
# from which the C API recovers the precision: `length == precision + (scale > 0) +
# (unsigned ? 0 : 1)` (`my_decimal_precision_to_length_no_truncation`, sql/my_decimal.h), so
# a signed DECIMAL(5, 3) arrives as length 7 and a DECIMAL(10, 0) UNSIGNED as length 10.
# Metadata outside the server's own range is clamped to a representable `Decimal` rather
# than faulting the connection; a value that then does not fit raises `ConversionError`.
function decimal_precision(column_length::Integer, scale::Int, isunsigned::Bool)
    precision = Int(column_length) - (scale > 0 ? 1 : 0) - (isunsigned ? 0 : 1)
    return clamp(precision, max(scale, 1), MAX_DECIMAL_PRECISION)
end

decimal_scale(decimals::Integer) = return clamp(Int(decimals), 0, MAX_DECIMAL_SCALE)

# The wire type of a `ColumnDef` → base Julia type, exactly as 1.x computed it except for
# DECIMAL/NEWDECIMAL, which carry their precision and scale (1.x mapped both to `Dec64`).
function juliatype(field_type, precision::Int=DEFAULT_DECIMAL_PRECISION, scale::Int=DEFAULT_DECIMAL_SCALE)
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
        return decimaltype(precision, scale)
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
    MySQL.juliatype(field_type, notnullable, isunsigned, isbinary, date_and_time, precision, scale) -> Type

The Julia type a result column decodes to, given its wire type, flags and (for
DECIMAL/NEWDECIMAL) precision and scale: the 1.x mapping (unsigned integer widening, binary
BLOB vs `String`, `DateAndTime` under `mysql_date_and_time=true`, `Union{Missing, T}` for
nullable columns), with DECIMAL columns mapping to `Decimals.Decimal{precision, scale, T}`
instead of 1.x's `DecFP.Dec64`.
"""
function juliatype(field_type, notnullable, isunsigned, isbinary, date_and_time, precision::Int=DEFAULT_DECIMAL_PRECISION, scale::Int=DEFAULT_DECIMAL_SCALE)
    T = juliatype(field_type, precision, scale)
    # `unsigned_type` is the identity on every non-integer mapped type, decimals included.
    T2 = isunsigned && !(T === Cfloat || T === Cdouble) ? unsigned_type(T) : T
    T3 = !isbinary && T2 === Vector{UInt8} ? String : T2
    T4 = date_and_time && T3 === DateTime ? DateAndTime : T3
    return notnullable ? T4 : Union{Missing, T4}
end
