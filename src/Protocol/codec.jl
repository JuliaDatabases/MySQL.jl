# Bounds-checked little-endian codecs over a byte buffer.
#
# Reading goes through `PacketCursor`, a window `[pos, stop]` into a `Vector{UInt8}`; every
# read checks the window first so a malformed packet can only ever raise `ProtocolError`,
# never read out of bounds. Writing appends to a plain `Vector{UInt8}`.

mutable struct PacketCursor
    buf::Vector{UInt8}
    pos::Int
    stop::Int
end

PacketCursor(buf::Vector{UInt8}) = return PacketCursor(buf, 1, length(buf))

# Rebinds a reusable cursor (a fresh `PacketCursor` is a heap allocation; the per-row scan
# paths reuse one per result cursor, §8.9).
function reset!(c::PacketCursor, buf::Vector{UInt8}, lo::Int, hi::Int)
    c.buf = buf
    c.pos = lo
    c.stop = hi
    return c
end

remaining(c::PacketCursor) = return c.stop - c.pos + 1
atend(c::PacketCursor) = return c.pos > c.stop

@noinline truncated(what::String) = return protocol_error("malformed packet: truncated $what")

@inline function need!(c::PacketCursor, n::Int, what::String)
    remaining(c) >= n || truncated(what)
    return nothing
end

@inline function peek_u8(c::PacketCursor)
    need!(c, 1, "byte")
    return @inbounds c.buf[c.pos]
end

@inline function read_u8!(c::PacketCursor)
    need!(c, 1, "int<1>")
    v = @inbounds c.buf[c.pos]
    c.pos += 1
    return v
end

@inline function read_fixed_uint!(c::PacketCursor, nbytes::Int, what::String)
    need!(c, nbytes, what)
    v = UInt64(0)
    @inbounds for i in 0:(nbytes - 1)
        v |= UInt64(c.buf[c.pos + i]) << (8 * i)
    end
    c.pos += nbytes
    return v
end

read_u16!(c::PacketCursor) = return UInt16(read_fixed_uint!(c, 2, "int<2>"))
read_u24!(c::PacketCursor) = return UInt32(read_fixed_uint!(c, 3, "int<3>"))
read_u32!(c::PacketCursor) = return UInt32(read_fixed_uint!(c, 4, "int<4>"))
read_u48!(c::PacketCursor) = return read_fixed_uint!(c, 6, "int<6>")
read_u64!(c::PacketCursor) = return read_fixed_uint!(c, 8, "int<8>")

"""
    read_lenenc!(c) -> UInt64

Length-encoded integer: `< 0xFB` one byte; `0xFC` + int<2>; `0xFD` + int<3>; `0xFE` + int<8>.
`0xFB` (NULL marker) and `0xFF` (ERR header) are not valid integer prefixes here; callers
that need to distinguish them peek first.
"""
function read_lenenc!(c::PacketCursor)
    first = read_u8!(c)
    first < 0xFB && return UInt64(first)
    first == 0xFC && return read_fixed_uint!(c, 2, "int<lenenc> (2-byte form)")
    first == 0xFD && return read_fixed_uint!(c, 3, "int<lenenc> (3-byte form)")
    first == 0xFE && return read_fixed_uint!(c, 8, "int<lenenc> (8-byte form)")
    return protocol_error("malformed packet: invalid length-encoded integer prefix 0x$(string(first, base=16, pad=2))")
end

# Length prefix of a lenenc string, bounded by the remaining bytes *before* any allocation.
function read_lenenc_length!(c::PacketCursor, what::String)
    len = read_lenenc!(c)
    len <= UInt64(remaining(c)) || truncated(what)
    return Int(len)
end

# Returns the (lo, hi) index window of a lenenc string without copying.
function read_lenenc_window!(c::PacketCursor, what::String="string<lenenc>")
    len = read_lenenc_length!(c, what)
    lo = c.pos
    c.pos += len
    return lo, lo + len - 1
end

function read_lenenc_string!(c::PacketCursor, what::String="string<lenenc>")
    lo, hi = read_lenenc_window!(c, what)
    return unsafe_window_string(c.buf, lo, hi)
end

function read_lenenc_bytes!(c::PacketCursor, what::String="string<lenenc>")
    lo, hi = read_lenenc_window!(c, what)
    return c.buf[lo:hi]
end

function read_nul_string!(c::PacketCursor, what::String="string<NUL>")
    atend(c) && truncated(what)
    idx = findnext(==(0x00), c.buf, c.pos)
    (idx === nothing || idx > c.stop) && truncated(what)
    s = unsafe_window_string(c.buf, c.pos, idx - 1)
    c.pos = idx + 1
    return s
end

function read_eof_string!(c::PacketCursor)
    s = unsafe_window_string(c.buf, c.pos, c.stop)
    c.pos = c.stop + 1
    return s
end

function read_eof_bytes!(c::PacketCursor)
    v = c.buf[c.pos:c.stop]
    c.pos = c.stop + 1
    return v
end

function read_fixed_bytes!(c::PacketCursor, n::Int, what::String="string[n]")
    need!(c, n, what)
    v = c.buf[c.pos:(c.pos + n - 1)]
    c.pos += n
    return v
end

function read_fixed_string!(c::PacketCursor, n::Int, what::String="string[n]")
    need!(c, n, what)
    s = unsafe_window_string(c.buf, c.pos, c.pos + n - 1)
    c.pos += n
    return s
end

function skip!(c::PacketCursor, n::Int, what::String="filler")
    need!(c, n, what)
    c.pos += n
    return nothing
end

# Copies buf[lo:hi] into a String (no UTF-8 validation, matching the existing text path).
function unsafe_window_string(buf::Vector{UInt8}, lo::Int, hi::Int)
    n = hi - lo + 1
    n <= 0 && return ""
    s = Base._string_n(n)
    GC.@preserve buf s unsafe_copyto!(pointer(s), pointer(buf, lo), n)
    return s
end

# ---- writers (append to a Vector{UInt8}) ----

write_u8!(buf::Vector{UInt8}, v::Integer) = return (push!(buf, UInt8(v & 0xFF)); nothing)

function write_fixed_uint!(buf::Vector{UInt8}, v::Unsigned, nbytes::Int)
    x = UInt64(v)
    for _ in 1:nbytes
        push!(buf, UInt8(x & 0xFF))
        x >>= 8
    end
    return nothing
end

write_u16!(buf::Vector{UInt8}, v::Integer) = return write_fixed_uint!(buf, UInt16(v), 2)
write_u24!(buf::Vector{UInt8}, v::Integer) = return write_fixed_uint!(buf, UInt32(v), 3)
write_u32!(buf::Vector{UInt8}, v::Integer) = return write_fixed_uint!(buf, UInt32(v), 4)
write_u64!(buf::Vector{UInt8}, v::Integer) = return write_fixed_uint!(buf, UInt64(v), 8)

function lenenc_size(v::Integer)
    x = UInt64(v)
    x < 251 && return 1
    x < (UInt64(1) << 16) && return 3
    x < (UInt64(1) << 24) && return 4
    return 9
end

function write_lenenc!(buf::Vector{UInt8}, v::Integer)
    x = UInt64(v)
    if x < 251
        push!(buf, UInt8(x))
    elseif x < (UInt64(1) << 16)
        push!(buf, 0xFC)
        write_fixed_uint!(buf, x, 2)
    elseif x < (UInt64(1) << 24)
        push!(buf, 0xFD)
        write_fixed_uint!(buf, x, 3)
    else
        push!(buf, 0xFE)
        write_fixed_uint!(buf, x, 8)
    end
    return nothing
end

function write_lenenc_bytes!(buf::Vector{UInt8}, bytes::AbstractVector{UInt8})
    write_lenenc!(buf, length(bytes))
    append!(buf, bytes)
    return nothing
end

write_lenenc_string!(buf::Vector{UInt8}, s::AbstractString) = return write_lenenc_bytes!(buf, codeunits(s))

function write_nul_string!(buf::Vector{UInt8}, s::AbstractString)
    occursin('\0', s) && throw(ArgumentError("string<NUL> value cannot contain a NUL byte"))
    append!(buf, codeunits(s))
    push!(buf, 0x00)
    return nothing
end

write_bytes!(buf::Vector{UInt8}, bytes::AbstractVector{UInt8}) = return (append!(buf, bytes); nothing)
write_string!(buf::Vector{UInt8}, s::AbstractString) = return (append!(buf, codeunits(s)); nothing)

function write_zeros!(buf::Vector{UInt8}, n::Int)
    for _ in 1:n
        push!(buf, 0x00)
    end
    return nothing
end
