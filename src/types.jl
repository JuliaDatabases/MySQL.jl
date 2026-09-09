# Public value types and result-type mapping (`MySQL.Bit`, `MySQL.DecimalResult`,
# `MySQL.juliatype`). Text and binary string columns decode to DataStrings.jl's
# `DataString`/`DataBytes` — zero-copy views of the cursor's row buffer (Arrow Utf8View /
# BinaryView layout) — DATETIME/TIMESTAMP to `Timestamp{P}` (Durations.jl's Unix-epoch
# instant, the type proposed for the Dates stdlib) at the column's declared fractional
# precision, and DECIMAL to exact DataDecimals values.

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

"""
    MySQL.DecimalResult

The type DECIMAL/NUMERIC columns decode to: `DataDecimals.DecimalValue{DataDecimals.Int256}`,
which holds all 65 digits and the column's scale exactly.
"""
const DecimalResult = DataDecimals.DecimalValue{DataDecimals.Int256}

"""
    MySQL.timestamp_type(decimals) -> Type{<:Timestamp}

The `Timestamp{P}` a DATETIME/TIMESTAMP column with `decimals` fractional-second digits
(its `fsp`, 0–6) decodes to: `Timestamp{Second}` for 0, `Timestamp{Millisecond}` for 1–3,
`Timestamp{Microsecond}` for 4–6. Every MySQL value is represented exactly.
"""
timestamp_type(decimals::Integer) = return decimals == 0 ? Timestamp{Second} : decimals <= 3 ? Timestamp{Millisecond} : Timestamp{Microsecond}

# The wire type maps to a host type. DATETIME/TIMESTAMP is given at full precision here;
# the column-aware overload narrows it to the declared fractional precision.
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
        return DecimalResult
    elseif t == P.MYSQL_TYPE_DOUBLE
        return Cdouble
    elseif t == P.MYSQL_TYPE_TINY_BLOB || t == P.MYSQL_TYPE_MEDIUM_BLOB ||
           t == P.MYSQL_TYPE_LONG_BLOB || t == P.MYSQL_TYPE_BLOB ||
           t == P.MYSQL_TYPE_GEOMETRY
        return DataBytes
    elseif t == P.MYSQL_TYPE_YEAR
        return Clong
    elseif t == P.MYSQL_TYPE_TIMESTAMP || t == P.MYSQL_TYPE_DATETIME
        return Timestamp{Microsecond}
    elseif t == P.MYSQL_TYPE_DATE
        return Date
    elseif t == P.MYSQL_TYPE_TIME
        return Dates.Time
    else
        return DataString
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
    MySQL.juliatype(field_type, notnullable, isunsigned, isbinary, decimals=6) -> Type

The Julia type a result column decodes to, given its wire type, flags, and fractional
precision: unsigned integer widening, binary BLOB (`DataBytes`) vs text (`DataString`), DATETIME/TIMESTAMP as
`Timestamp{P}` per `decimals` (see `MySQL.timestamp_type`), exact DataDecimals values for
DECIMAL, and `Union{Missing, T}` for nullable columns.
"""
function juliatype(field_type, notnullable, isunsigned, isbinary, decimals=6)
    T = juliatype(field_type)
    T2 = isunsigned ? unsigned_type(T) : T
    T3 = !isbinary && T2 === DataBytes ? DataString : T2
    T4 = T3 === Timestamp{Microsecond} ? timestamp_type(decimals) : T3
    return notnullable ? T4 : Union{Missing, T4}
end
