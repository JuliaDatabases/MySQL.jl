# Text-protocol value decoding: `MySQL.juliatype` selects the Julia type, and each value
# is parsed from its window in the row buffer. Changes from 1.x, including exact DECIMAL
# values, are documented in docs/src/migration.md.

"""
    ResultOptions(; zero_dates=:sentinel, time_type=Dates.Time)

Per-result decoding policy. `zero_dates` decides what `0000-00-00` values become
(`:sentinel` → `Date(0)` / `Timestamp{P}(0, 1, 1)`, `:missing` → `missing` and every date
column is typed `Union{Missing, T}`, `:error` → `ConversionError`); `time_type` is
`Dates.Time` (values outside `0 ≤ t < 24h` raise `ConversionError`) or `Dates.Microsecond`
(lossless, signed, up to ±838 h).
"""
struct ResultOptions
    zero_dates::Symbol
    time_type::Type
end

function ResultOptions(; zero_dates::Symbol=:sentinel, time_type::Type=Dates.Time)
    zero_dates in (:sentinel, :missing, :error) || throw(ArgumentError("zero_dates must be :sentinel, :missing or :error"))
    (time_type === Dates.Time || time_type === Dates.Microsecond) || throw(ArgumentError("time_type must be Dates.Time or Dates.Microsecond"))
    return ResultOptions(zero_dates, time_type)
end

const DEFAULT_RESULT_OPTIONS = ResultOptions()

field_type_enum(def::P.ColumnDef) = return UInt32(def.type)

"""
    juliatype(def::Protocol.ColumnDef, opts::ResultOptions) -> Type

The column's Julia type: `MySQL.juliatype` applied to the wire type, flags, and fractional
precision (`decimals`), then the decoding policies: `time_type`, and `zero_dates=:missing`
widening every date column to `Union{Missing, T}` regardless of `NOT NULL`.
"""
function juliatype(def::P.ColumnDef, opts::ResultOptions)
    T = juliatype(field_type_enum(def), P.is_not_null(def), P.is_unsigned(def), P.is_binary(def), Int(def.decimals))
    base = nonmissingtype(T)
    base === Dates.Time && opts.time_type !== Dates.Time && (T = T === base ? opts.time_type : Union{Missing, opts.time_type})
    is_date_type(base) && opts.zero_dates == :missing && (T = Union{Missing, base})
    return T
end

is_date_type(T) = return T === Date || T <: Timestamp

@noinline conversion_error(T, buf::Vector{UInt8}, pos::Int, len::Int) = return throw(P.ConversionError("cannot convert \"$(String(buf[pos:(pos + len - 1)]))\" to $T"))
@noinline conversion_error(T, msg::AbstractString) = return throw(P.ConversionError("cannot convert to $T: $msg"))
@noinline null_in_not_null(T) = return throw(P.ConversionError("the server sent NULL for a NOT NULL column of type $T"))

"""
    decode(T, buf, pos, len, opts) -> T

Decodes the text-protocol value occupying `buf[pos:pos+len-1]`; `len == -1` is NULL.
"""
function decode(::Type{T}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) where {T}
    if Missing <: T
        len < 0 && return missing
        return decode_missing_aware(nonmissingtype(T), buf, pos, len, opts)
    end
    len < 0 && null_in_not_null(T)
    return decode_value(T, buf, pos, len, opts)
end

decode(::Type{Missing}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) = return missing

# Under `zero_dates=:missing` a zero date decodes to `missing` even though the column type
# says `T`; this is the only place the decoder may answer `missing` for a non-NULL value.
function decode_missing_aware(::Type{T}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) where {T}
    if is_date_type(T) && opts.zero_dates == :missing
        parts = parse_date_parts(T, buf, pos, len)
        parts !== nothing && zero_date_kind(parts) != :none && return missing
    end
    return decode_value(T, buf, pos, len, opts)
end

# ---- strings, bytes, decimals ----

# Strings and bytes decode to DataStrings views: values of up to 12 bytes are stored inline,
# longer ones reference the cursor's buffer (which a buffered cursor never mutates and a
# streaming cursor appends rows to retained arenas), so no heap payload is copied or allocated.
# Requesting `String`/`Vector{UInt8}` explicitly (`Tables.getcolumn(row, String, i, name)`)
# still yields a copy.
function decode_value(::Type{DataString}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions)
    len <= DataStrings.INLINE_MAX && return DataString(DataStrings.inline_payload(buf, pos, len), NO_BYTES)
    return DataString(DataStrings.view_payload(buf, pos, len, 0, pos - 1), buf)
end

function decode_value(::Type{DataBytes}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions)
    len <= DataStrings.INLINE_MAX && return DataBytes(DataStrings.inline_payload(buf, pos, len), NO_BYTES)
    return DataBytes(DataStrings.view_payload(buf, pos, len, 0, pos - 1), buf)
end

const NO_BYTES = UInt8[]

function decode_value(::Type{String}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions)
    return GC.@preserve buf unsafe_string(pointer(buf, pos), len)
end

decode_value(::Type{Vector{UInt8}}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions) = return buf[pos:(pos + len - 1)]

# DECIMAL (up to 65 digits) arrives as its ASCII form; the coefficient and scale are kept exactly.
function decode_value(::Type{DecimalResult}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions)
    x = tryparse(DecimalResult, decode_value(String, buf, pos, len, opts))
    x === nothing && conversion_error(DecimalResult, buf, pos, len)
    return x
end

# BIT(n): the text protocol sends the big-endian bytes of the value (1.x used only the first byte).
function decode_value(::Type{Bit}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions)
    len <= 8 || conversion_error(Bit, "BIT values wider than 64 bits are not supported ($len bytes)")
    v = UInt64(0)
    @inbounds for i in pos:(pos + len - 1)
        v = (v << 8) | buf[i]
    end
    return Bit(v)
end

# ---- numbers (Parsers) ----

function decode_value(::Type{T}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions) where {T <: Union{Integer, AbstractFloat}}
    len == 0 && conversion_error(T, buf, pos, len)
    (T <: Unsigned && buf[pos] == UInt8('-')) && conversion_error(T, buf, pos, len)
    x = Parsers.tryparse(T, buf, pos, pos + len - 1)
    x === nothing && conversion_error(T, buf, pos, len)
    return x
end

# ---- dates and times ----

# Reads `n` ASCII digits at `i`; returns (value, next index) or (-1, i) on a non-digit.
function digits_at(buf::Vector{UInt8}, i::Int, stop::Int, n::Int)
    v = 0
    i + n - 1 <= stop || return (-1, i)
    @inbounds for k in 0:(n - 1)
        b = buf[i + k]
        (UInt8('0') <= b <= UInt8('9')) || return (-1, i)
        v = v * 10 + (b - UInt8('0'))
    end
    return (v, i + n)
end

# One to six fraction digits after a '.', scaled to microseconds.
function fraction_micros(buf::Vector{UInt8}, i::Int, stop::Int)
    micros = 0
    ndigits = 0
    while i <= stop
        b = @inbounds buf[i]
        (UInt8('0') <= b <= UInt8('9')) || return (-1, i)
        ndigits < 6 || return (-1, i)
        micros = micros * 10 + (b - UInt8('0'))
        ndigits += 1
        i += 1
    end
    ndigits > 0 || return (-1, i)
    while ndigits < 6
        micros *= 10
        ndigits += 1
    end
    return (micros, i)
end

# YYYY-MM-DD[ HH:MM:SS[.ffffff]] → (year, month, day, hour, minute, second, micros) or nothing
function parse_datetime_parts(buf::Vector{UInt8}, pos::Int, len::Int)
    stop = pos + len - 1
    y, i = digits_at(buf, pos, stop, 4)
    (y < 0 || i > stop || buf[i] != UInt8('-')) && return nothing
    mo, i = digits_at(buf, i + 1, stop, 2)
    (mo < 0 || i > stop || buf[i] != UInt8('-')) && return nothing
    d, i = digits_at(buf, i + 1, stop, 2)
    d < 0 && return nothing
    i > stop && return (y, mo, d, 0, 0, 0, 0)
    buf[i] == UInt8(' ') || return nothing
    h, i = digits_at(buf, i + 1, stop, 2)
    (h < 0 || i > stop || buf[i] != UInt8(':')) && return nothing
    mi, i = digits_at(buf, i + 1, stop, 2)
    (mi < 0 || i > stop || buf[i] != UInt8(':')) && return nothing
    s, i = digits_at(buf, i + 1, stop, 2)
    s < 0 && return nothing
    i > stop && return (y, mo, d, h, mi, s, 0)
    buf[i] == UInt8('.') || return nothing
    micros, i = fraction_micros(buf, i + 1, stop)
    (micros < 0 || i <= stop) && return nothing
    return (y, mo, d, h, mi, s, micros)
end

function parse_date_parts(::Type{Date}, buf::Vector{UInt8}, pos::Int, len::Int)
    len == 10 || return nothing
    return parse_datetime_parts(buf, pos, len)
end

function parse_date_parts(::Type{<:Timestamp}, buf::Vector{UInt8}, pos::Int, len::Int)
    len >= 19 || return nothing
    return parse_datetime_parts(buf, pos, len)
end

# `:zero` is the all-zero value, `:partial` a zero month or day (`NO_ZERO_IN_DATE`); year
# 0000 with a real month and day is a legal date (`0000-01-01`), not a partial zero.
function zero_date_kind(parts)
    y, mo, d, h, mi, s, micros = parts
    y == 0 && mo == 0 && d == 0 && h == 0 && mi == 0 && s == 0 && micros == 0 && return :zero
    return mo == 0 || d == 0 ? :partial : :none
end

# The `:sentinel` for `0000-00-00`: `Date(0)` / `0000-01-01T00:00:00`, as 1.x produced.
function zero_date_value(::Type{T}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) where {T}
    opts.zero_dates == :error && conversion_error(T, "zero dates are rejected (zero_dates=:error)")
    T === Date && return Date(0)
    return timestamp_from_parts(T, 0, 1, 1, 0, 0, 0, 0)
end

const UNIX_EPOCH_DAYS = Dates.value(Date(1970, 1, 1))   # rata die of the Unix epoch

timestamp_ticks_per_second(::Type{Second}) = return Int64(1)
timestamp_ticks_per_second(::Type{Millisecond}) = return Int64(1_000)
timestamp_ticks_per_second(::Type{Microsecond}) = return Int64(1_000_000)
timestamp_ticks_per_second(::Type{Nanosecond}) = return Int64(1_000_000_000)

# Already-validated (year, month, day, hour, minute, second, micros) parts as `Timestamp{P}`:
# the Unix tick count is computed here and wrapped in its `UTInstant`, which skips the
# parts constructor's second validation (and its error-message formatting, which is not
# resolvable under `--trim=safe`).
@inline function timestamp_from_parts(::Type{Timestamp{P}}, y, mo, d, h, mi, s, micros) where {P}
    per_second = timestamp_ticks_per_second(P)
    seconds = (Int64(Dates.totaldays(y, mo, d)) - UNIX_EPOCH_DAYS) * Int64(86_400) + Int64(h) * 3600 + Int64(mi) * 60 + Int64(s)
    fraction = per_second >= 1_000_000 ? Int64(micros) * (per_second ÷ 1_000_000) : Int64(micros) ÷ (1_000_000 ÷ per_second)
    return Timestamp{P}(Dates.UTInstant(P(seconds * per_second + fraction)))
end

function decode_value(::Type{Date}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions)
    parts = parse_date_parts(Date, buf, pos, len)
    parts === nothing && conversion_error(Date, buf, pos, len)
    kind = zero_date_kind(parts)
    kind == :zero && return zero_date_value(Date, buf, pos, len, opts)
    kind == :partial && conversion_error(Date, "partial zero date \"$(String(buf[pos:(pos + len - 1)]))\" (use zero_dates=:missing)")
    y, mo, d = parts
    Dates.validargs(Date, y, mo, d) === nothing || conversion_error(Date, buf, pos, len)
    return Date(y, mo, d)
end

# DATETIME/TIMESTAMP → `Timestamp{P}`: every digit the server sent is kept (a value finer
# than the column's declared precision, which servers never send, is a `ConversionError`).
function decode_value(::Type{Timestamp{P}}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) where {P}
    parts = parse_date_parts(Timestamp{P}, buf, pos, len)
    parts === nothing && conversion_error(Timestamp{P}, buf, pos, len)
    kind = zero_date_kind(parts)
    kind == :zero && return zero_date_value(Timestamp{P}, buf, pos, len, opts)
    kind == :partial && conversion_error(Timestamp{P}, "partial zero date \"$(String(buf[pos:(pos + len - 1)]))\" (use zero_dates=:missing)")
    y, mo, d, h, mi, s, micros = parts
    Dates.validargs(Date, y, mo, d) === nothing || conversion_error(Timestamp{P}, buf, pos, len)
    (h < 24 && mi < 60 && s < 60 && micros % timestamp_micros_unit(P) == 0) || conversion_error(Timestamp{P}, buf, pos, len)
    return timestamp_from_parts(Timestamp{P}, y, mo, d, h, mi, s, micros)
end

# Microseconds per tick of a `Timestamp{P}` resolution (a value must be a whole number of ticks).
timestamp_micros_unit(::Type{Second}) = return 1_000_000
timestamp_micros_unit(::Type{Millisecond}) = return 1_000
timestamp_micros_unit(::Type{Microsecond}) = return 1
timestamp_micros_unit(::Type{Nanosecond}) = return 1

# TIME: [-]H+:MM:SS[.ffffff], hours up to 838. Returns the signed total in microseconds.
function parse_time_micros(buf::Vector{UInt8}, pos::Int, len::Int)
    stop = pos + len - 1
    i = pos
    negative = false
    if i <= stop && buf[i] == UInt8('-')
        negative = true
        i += 1
    end
    h = 0
    nd = 0
    while i <= stop && UInt8('0') <= buf[i] <= UInt8('9')
        h = h * 10 + (buf[i] - UInt8('0'))
        nd += 1
        i += 1
    end
    (nd == 0 || nd > 3 || i > stop || buf[i] != UInt8(':')) && return nothing
    h <= 838 || return nothing
    mi, i = digits_at(buf, i + 1, stop, 2)
    (mi < 0 || mi > 59 || i > stop || buf[i] != UInt8(':')) && return nothing
    s, i = digits_at(buf, i + 1, stop, 2)
    (s < 0 || s > 59) && return nothing
    micros = 0
    if i <= stop
        buf[i] == UInt8('.') || return nothing
        micros, i = fraction_micros(buf, i + 1, stop)
        (micros < 0 || i <= stop) && return nothing
    end
    total = ((Int64(h) * 60 + mi) * 60 + s) * 1_000_000 + micros
    return negative ? -total : total
end

function decode_value(::Type{Dates.Time}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions)
    micros = parse_time_micros(buf, pos, len)
    micros === nothing && conversion_error(Dates.Time, buf, pos, len)
    (0 <= micros < 24 * 3_600_000_000) || conversion_error(Dates.Time, "TIME value \"$(String(buf[pos:(pos + len - 1)]))\" is outside 0 ≤ t < 24h; use time_type=Dates.Microsecond")
    return Dates.Time(Dates.Nanosecond(micros * 1000))
end

function decode_value(::Type{Dates.Microsecond}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions)
    micros = parse_time_micros(buf, pos, len)
    micros === nothing && conversion_error(Dates.Microsecond, buf, pos, len)
    return Dates.Microsecond(micros)
end
