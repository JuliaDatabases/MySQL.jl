# Binary-protocol value codecs. Decoding maps a prepared-statement result value (a content
# window produced by `Protocol.scan_binary_row!`) to the same Julia type the text path
# produces (`MySQL.juliatype`), preserving the 1.x prepared-statement observable behaviour
# except for the documented Fixes (behavior table in docs/src/migration.md: BIT big-endian,
# TIME range/days/sign, unified zero-date policy). Encoding serialises a bound parameter to its wire `(type, unsigned)` and value
# bytes for `COM_STMT_EXECUTE`, mirroring the 1.x `mysqltype`/`bind!` mapping.

@noinline function invalid_binary_span(pos, len, n)
    throw(P.ConversionError(
        "invalid binary value span: offset=$pos, length=$len, buffer_length=$n",
    ))
end

@inline function check_binary_span(buf::Vector{UInt8}, pos::Int, len::Int)
    if len < 0 || pos < 1 || pos > length(buf) + 1 || len > length(buf) - pos + 1
        invalid_binary_span(pos, len, length(buf))
    end
    return nothing
end

@inline function read_le_uint(buf::Vector{UInt8}, pos::Int, len::Int)
    0 <= len <= 8 || invalid_binary_span(pos, len, length(buf))
    check_binary_span(buf, pos, len)
    v = UInt64(0)
    @inbounds for i in 0:(len - 1)
        v |= UInt64(buf[pos + i]) << (8 * i)
    end
    return v
end

# ---- decode ----

function decode_binary(::Type{T}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) where {T}
    if Missing <: T
        len < 0 && return missing
        check_binary_span(buf, pos, len)
        return decode_binary_missing_aware(nonmissingtype(T), buf, pos, len, opts)
    end
    len < 0 && null_in_not_null(T)
    check_binary_span(buf, pos, len)
    return decode_binary_value(T, buf, pos, len, opts)
end

decode_binary(::Type{Missing}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) = return missing

function decode_binary_missing_aware(::Type{T}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) where {T}
    if is_date_type(T) && opts.zero_dates == :missing
        parts = binary_temporal_parts(T, buf, pos, len)
        parts !== nothing && zero_date_kind(parts) != :none && return missing
    end
    return decode_binary_value(T, buf, pos, len, opts)
end

# String, bytes, decimal and BIT are the same content bytes on both protocols (BIT is the
# big-endian value of all bytes; DECIMAL is the ASCII form), so the text decoders apply.
decode_binary_value(::Type{DataString}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) = return decode_value(DataString, buf, pos, len, opts)
decode_binary_value(::Type{DataBytes}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) = return decode_value(DataBytes, buf, pos, len, opts)
decode_binary_value(::Type{String}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) = return decode_value(String, buf, pos, len, opts)
decode_binary_value(::Type{Vector{UInt8}}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) = return decode_value(Vector{UInt8}, buf, pos, len, opts)
decode_binary_value(::Type{DecimalResult}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) = return decode_value(DecimalResult, buf, pos, len, opts)
decode_binary_value(::Type{Bit}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) = return decode_value(Bit, buf, pos, len, opts)

function decode_binary_value(::Type{T}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions) where {T <: Base.BitInteger}
    u = read_le_uint(buf, pos, min(len, sizeof(T)))
    return T <: Signed ? Core.bitcast(T, (unsigned(T))(u)) : T(u)
end

function decode_binary_value(::Type{Float32}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions)
    len == 4 || conversion_error(Float32, "binary FLOAT value has width $len instead of 4")
    return Core.bitcast(Float32, UInt32(read_le_uint(buf, pos, len)))
end

function decode_binary_value(::Type{Float64}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions)
    len == 8 || conversion_error(Float64, "binary DOUBLE value has width $len instead of 8")
    return Core.bitcast(Float64, read_le_uint(buf, pos, len))
end

# ---- binary temporal ----

@inline read_u16le(buf, pos) = return UInt16(buf[pos]) | (UInt16(buf[pos + 1]) << 8)
@inline read_u32le(buf, pos) = return UInt32(read_le_uint(buf, pos, 4))

# DATE/DATETIME/TIMESTAMP content window (length prefix already stripped; `len ∈ {0,4,7,11}`)
# → (year, month, day, hour, minute, second, micros), or `nothing` if the length is invalid.
function binary_date_parts(buf::Vector{UInt8}, pos::Int, len::Int)
    len == 0 && return (0, 0, 0, 0, 0, 0, 0)
    (len == 4 || len == 7 || len == 11) || return nothing
    y = Int(read_u16le(buf, pos))
    mo = Int(buf[pos + 2])
    d = Int(buf[pos + 3])
    h = mi = s = 0
    micros = 0
    if len >= 7
        h = Int(buf[pos + 4]); mi = Int(buf[pos + 5]); s = Int(buf[pos + 6])
        (h < 24 && mi < 60 && s < 60) || return nothing
    end
    if len == 11
        micros = Int(read_u32le(buf, pos + 7))
        micros < 1_000_000 || return nothing
    end
    return (y, mo, d, h, mi, s, micros)
end

# TIME content window (length prefix stripped; `len ∈ {0,8,12}`) → signed total microseconds,
# or `nothing` if the length is invalid.
function binary_time_micros(buf::Vector{UInt8}, pos::Int, len::Int)
    len == 0 && return Int64(0)
    (len == 8 || len == 12) || return nothing
    negbyte = buf[pos]
    negbyte <= 0x01 || return nothing
    days = Int64(read_u32le(buf, pos + 1))
    h = Int64(buf[pos + 5]); mi = Int64(buf[pos + 6]); s = Int64(buf[pos + 7])
    micros = len == 12 ? Int64(read_u32le(buf, pos + 8)) : Int64(0)
    (h < 24 && mi < 60 && s < 60 && micros < 1_000_000) || return nothing
    hours = days * 24 + h
    hours <= 838 || return nothing
    total = ((hours * 60 + mi) * 60 + s) * 1_000_000 + micros
    return negbyte == 0x01 ? -total : total
end

# Shared with the `zero_dates=:missing` widening check.
binary_temporal_parts(::Type{T}, buf, pos, len) where {T <: Union{Date, Timestamp}} = return binary_date_parts(buf, pos, len)
binary_temporal_parts(::Type, buf, pos, len) = return nothing

function decode_binary_value(::Type{Date}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions)
    (len == 0 || len == 4) || conversion_error(Date, "binary DATE value has invalid length $len")
    parts = binary_date_parts(buf, pos, len)
    parts === nothing && conversion_error(Date, buf, pos, len)
    kind = zero_date_kind(parts)
    kind == :zero && return zero_date_value(Date, buf, pos, len, opts)
    kind == :partial && conversion_error(Date, "partial zero date in a binary DATE value (use zero_dates=:missing)")
    y, mo, d = parts
    Dates.validargs(Date, y, mo, d) === nothing || conversion_error(Date, buf, pos, len)
    return Date(y, mo, d)
end

function decode_binary_value(::Type{Timestamp{P}}, buf::Vector{UInt8}, pos::Int, len::Int, opts::ResultOptions) where {P}
    parts = binary_date_parts(buf, pos, len)
    parts === nothing && conversion_error(Timestamp{P}, buf, pos, len)
    kind = zero_date_kind(parts)
    kind == :zero && return zero_date_value(Timestamp{P}, buf, pos, len, opts)
    kind == :partial && conversion_error(Timestamp{P}, "partial zero date in a binary DATETIME value (use zero_dates=:missing)")
    y, mo, d, h, mi, s, micros = parts
    Dates.validargs(Date, y, mo, d) === nothing || conversion_error(Timestamp{P}, buf, pos, len)
    micros % timestamp_micros_unit(P) == 0 || conversion_error(Timestamp{P}, buf, pos, len)
    return timestamp_from_parts(Timestamp{P}, y, mo, d, h, mi, s, micros)
end

function decode_binary_value(::Type{Dates.Time}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions)
    micros = binary_time_micros(buf, pos, len)
    micros === nothing && conversion_error(Dates.Time, buf, pos, len)
    (0 <= micros < 24 * 3_600_000_000) || conversion_error(Dates.Time, "binary TIME value is outside 0 ≤ t < 24h; use time_type=Dates.Microsecond")
    return Dates.Time(Dates.Nanosecond(micros * 1000))
end

function decode_binary_value(::Type{Dates.Microsecond}, buf::Vector{UInt8}, pos::Int, len::Int, ::ResultOptions)
    micros = binary_time_micros(buf, pos, len)
    micros === nothing && conversion_error(Dates.Microsecond, buf, pos, len)
    return Dates.Microsecond(micros)
end

# ---- parameter encoding (COM_STMT_EXECUTE) ----

# `(wire type, unsigned)` of a bound parameter, mirroring the 1.x `mysqltype` mapping.
param_type(::Missing) = return (P.MYSQL_TYPE_NULL, false)
param_type(::Nothing) = return (P.MYSQL_TYPE_NULL, false)
param_type(::Bool) = return (P.MYSQL_TYPE_TINY, false)
param_type(::Int8) = return (P.MYSQL_TYPE_TINY, false)
param_type(::UInt8) = return (P.MYSQL_TYPE_TINY, true)
param_type(::Int16) = return (P.MYSQL_TYPE_SHORT, false)
param_type(::UInt16) = return (P.MYSQL_TYPE_SHORT, true)
param_type(::Int32) = return (P.MYSQL_TYPE_LONG, false)
param_type(::UInt32) = return (P.MYSQL_TYPE_LONG, true)
param_type(::Int64) = return (P.MYSQL_TYPE_LONGLONG, false)
param_type(::UInt64) = return (P.MYSQL_TYPE_LONGLONG, true)
param_type(::Float32) = return (P.MYSQL_TYPE_FLOAT, false)
param_type(::Float64) = return (P.MYSQL_TYPE_DOUBLE, false)
param_type(::DataDecimals.AbstractDecimal) = return (P.MYSQL_TYPE_STRING, false)
param_type(::Bit) = return (P.MYSQL_TYPE_BLOB, false)
param_type(::Vector{UInt8}) = return (P.MYSQL_TYPE_BLOB, false)
param_type(::DataBytes) = return (P.MYSQL_TYPE_BLOB, false)
param_type(::Timestamp) = return (P.MYSQL_TYPE_DATETIME, false)
param_type(::DateTime) = return (P.MYSQL_TYPE_TIMESTAMP, false)
param_type(::Date) = return (P.MYSQL_TYPE_DATE, false)
param_type(::Dates.Time) = return (P.MYSQL_TYPE_TIME, false)
param_type(::AbstractString) = return (P.MYSQL_TYPE_STRING, false)

@noinline unbindable_param(x) = return throw(MySQLInterfaceError("cannot bind a value of type $(typeof(x)) as a MySQL parameter"))
param_type(x) = return unbindable_param(x)

# The `(type, unsigned)` signature code of one bound parameter (bit 15 = unsigned).
@inline function param_code(x)::UInt16
    t, uns = param_type(x)
    return uns ? UInt16(t) | 0x8000 : UInt16(t)
end

# The `(type, unsigned)` signature the server caches: a change forces `new_params_bind_flag`.
param_signature(values) = return UInt16[param_code(x) for x in values]

# Whether `sig` is exactly the signature of `values` (also validates every parameter is
# bindable, like `param_signature`), without materializing a vector.
function signature_matches(sig::Vector{UInt16}, values)::Bool
    matches = length(sig) == length(values)
    for (i, x) in enumerate(values)
        code = param_code(x)
        matches = matches && sig[i] == code
    end
    return matches
end

encode_param_value!(buf::Vector{UInt8}, x::Union{Bool, Int8, UInt8}) = return (P.write_u8!(buf, Core.bitcast(UInt8, x isa Bool ? UInt8(x) : x)); nothing)
encode_param_value!(buf::Vector{UInt8}, x::Union{Int16, UInt16}) = return (P.write_u16!(buf, Core.bitcast(UInt16, x)); nothing)
encode_param_value!(buf::Vector{UInt8}, x::Union{Int32, UInt32}) = return (P.write_u32!(buf, Core.bitcast(UInt32, x)); nothing)
encode_param_value!(buf::Vector{UInt8}, x::Union{Int64, UInt64}) = return (P.write_u64!(buf, Core.bitcast(UInt64, x)); nothing)
encode_param_value!(buf::Vector{UInt8}, x::Float32) = return (P.write_u32!(buf, Core.bitcast(UInt32, x)); nothing)
encode_param_value!(buf::Vector{UInt8}, x::Float64) = return (P.write_u64!(buf, Core.bitcast(UInt64, x)); nothing)
encode_param_value!(buf::Vector{UInt8}, x::AbstractString) = return (P.write_lenenc_string!(buf, x); nothing)
encode_param_value!(buf::Vector{UInt8}, x::Vector{UInt8}) = return (P.write_lenenc_bytes!(buf, x); nothing)
# DataStrings values append their inline or viewed bytes directly (no per-byte `codeunit` walk).
encode_param_value!(buf::Vector{UInt8}, x::DataString) = return (P.write_lenenc!(buf, ncodeunits(x)); append_payload!(buf, x.p, x.data); nothing)
encode_param_value!(buf::Vector{UInt8}, x::DataBytes) = return (P.write_lenenc!(buf, length(x)); append_payload!(buf, x.p, x.data); nothing)

function append_payload!(buf::Vector{UInt8}, p::DataStrings.StringPayload, data::Vector{UInt8})
    n = Int(DataStrings.payloadlength(p))
    if n <= DataStrings.INLINE_MAX
        a, b = p.a, p.b
        for i in 1:min(n, 4)
            push!(buf, (a >> (32 + 8 * (i - 1))) % UInt8)
        end
        for i in 5:n
            push!(buf, (b >> (8 * (i - 5))) % UInt8)
        end
    else
        pos = DataStrings.payloadpos(p)
        append!(buf, view(data, pos:(pos + n - 1)))
    end
    return nothing
end
# Decimals travel as their exact ASCII form (a MYSQL_TYPE_STRING parameter).
# A decimal parameter is its plain decimal text, written in place (no `string(x)` copy).
function encode_param_value!(buf::Vector{UInt8}, x::DataDecimals.AbstractDecimal)
    n = DataDecimals.decimallength(x)
    P.write_lenenc!(buf, n)
    pos = length(buf) + 1
    resize!(buf, pos + n - 1)
    DataDecimals.writedecimal!(buf, pos, x)
    return nothing
end
# A BIT parameter is the big-endian binary string of its value (no leading zero bytes, at
# least one byte), matching the big-endian BIT *decode*. (Connector/C's 1.x `bitvalue`
# encoding was little-endian; documented as a Fix in the migration guide.)
function bit_param_bytes(x::Bit)
    v = x.bits
    n = max(1, cld(64 - leading_zeros(v), 8))
    bytes = Vector{UInt8}(undef, n)
    for i in n:-1:1
        @inbounds bytes[i] = v % UInt8
        v >>= 8
    end
    return bytes
end
encode_param_value!(buf::Vector{UInt8}, x::Bit) = return (P.write_lenenc_bytes!(buf, bit_param_bytes(x)); nothing)

function encode_param_value!(buf::Vector{UInt8}, x::Date)
    P.write_u8!(buf, 4)
    P.write_u16!(buf, Dates.year(x)); P.write_u8!(buf, Dates.month(x)); P.write_u8!(buf, Dates.day(x))
    return nothing
end

# DATETIME/TIMESTAMP: 11-byte form when it carries sub-second precision, else 7-byte.
function encode_datetime_value!(buf::Vector{UInt8}, y, mo, d, h, mi, s, micros)
    if micros != 0
        P.write_u8!(buf, 11)
        P.write_u16!(buf, y); P.write_u8!(buf, mo); P.write_u8!(buf, d)
        P.write_u8!(buf, h); P.write_u8!(buf, mi); P.write_u8!(buf, s)
        P.write_u32!(buf, micros)
    else
        P.write_u8!(buf, 7)
        P.write_u16!(buf, y); P.write_u8!(buf, mo); P.write_u8!(buf, d)
        P.write_u8!(buf, h); P.write_u8!(buf, mi); P.write_u8!(buf, s)
    end
    return nothing
end

function encode_param_value!(buf::Vector{UInt8}, x::DateTime)
    return encode_datetime_value!(buf, Dates.year(x), Dates.month(x), Dates.day(x), Dates.hour(x), Dates.minute(x), Dates.second(x), Dates.millisecond(x) * 1000)
end

# The wire carries microseconds: a `Timestamp{Nanosecond}` with a sub-microsecond part
# raises `InexactError` (round it first) rather than losing digits silently.
function encode_param_value!(buf::Vector{UInt8}, x::Timestamp)
    t = Timestamp{Microsecond}(x)
    return encode_datetime_value!(buf, Dates.year(t), Dates.month(t), Dates.day(t), Dates.hour(t), Dates.minute(t), Dates.second(t), Dates.millisecond(t) * 1000 + Dates.microsecond(t))
end

function encode_param_value!(buf::Vector{UInt8}, x::Dates.Time)
    micros = Dates.millisecond(x) * 1000 + Dates.microsecond(x)
    if micros != 0
        P.write_u8!(buf, 12)
        P.write_u8!(buf, 0); P.write_u32!(buf, 0)   # is_negative, days
        P.write_u8!(buf, Dates.hour(x)); P.write_u8!(buf, Dates.minute(x)); P.write_u8!(buf, Dates.second(x))
        P.write_u32!(buf, micros)
    else
        P.write_u8!(buf, 8)
        P.write_u8!(buf, 0); P.write_u32!(buf, 0)
        P.write_u8!(buf, Dates.hour(x)); P.write_u8!(buf, Dates.minute(x)); P.write_u8!(buf, Dates.second(x))
    end
    return nothing
end

"""
    encode_param_block(values, signature, send_types; skip=()) -> Vector{UInt8}

Builds the `COM_STMT_EXECUTE` parameter section: the NULL bitmap (bit offset 0), the
`new_params_bind_flag`, the `(type, unsigned)` pair per parameter when `send_types` is set,
then the value bytes of every non-NULL parameter. Parameters whose 1-based index is in
`skip` (already delivered with `COM_STMT_SEND_LONG_DATA`) contribute their type but no value.
Returns an empty block when there are no parameters.
"""
function encode_param_block(values, signature::Vector{UInt16}, send_types::Bool; skip=())
    buf = UInt8[]
    encode_params_into!(buf, values, signature, send_types, skip)
    return buf
end

# In-place variant appending straight to `buf` (the framed command buffer on the hot path).
function encode_params_into!(buf::Vector{UInt8}, values, signature::Vector{UInt16}, send_types::Bool, skip=())
    n = length(values)
    n == 0 && return nothing
    nullbase = length(buf)
    nullbytes = (n + 7) >> 3
    resize!(buf, nullbase + nullbytes)
    for i in (nullbase + 1):(nullbase + nullbytes)
        @inbounds buf[i] = 0x00
    end
    for (i, x) in enumerate(values)
        (x === missing || x === nothing) && (buf[nullbase + ((i - 1) >> 3) + 1] |= UInt8(1) << ((i - 1) & 7))
    end
    P.write_u8!(buf, send_types ? 0x01 : 0x00)
    if send_types
        for t in signature
            P.write_u16!(buf, t)
        end
    end
    for (i, x) in enumerate(values)
        (x === missing || x === nothing || i in skip) && continue
        encode_param_value!(buf, x)
    end
    return nothing
end
