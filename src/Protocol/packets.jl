# MySQL packet framing: `int<3> length` + `int<1> sequence id` + payload.
#
# A logical packet of N bytes is carried in ⌊N / 0xFFFFFF⌋ full chunks of 0xFFFFFF bytes
# followed by one chunk of N mod 0xFFFFFF bytes (which is an empty packet when N is an exact
# multiple). The client and server share one sequence counter per command.

const MAX_CHUNK = 0xFFFFFF % Int
const PACKET_HEADER_LEN = 4

"""
    PacketView

One reassembled logical packet: the window `[lo, hi]` of the reader's buffer, its sequence
id, and how it was chunked on the wire (`nchunks`, `first_chunk_len`) so protocol-validity
decisions (e.g. the `0xFE` terminator rule) can see the physical framing.
The window is valid only until the next `readpacket!`.
"""
struct PacketView
    buf::Vector{UInt8}
    lo::Int
    hi::Int
    seq::UInt8
    nchunks::Int
    first_chunk_len::Int
end

payload_length(p::PacketView) = return p.hi - p.lo + 1
PacketCursor(p::PacketView) = return PacketCursor(p.buf, p.lo, p.hi)
first_byte(p::PacketView) = return payload_length(p) == 0 ? nothing : (@inbounds p.buf[p.lo])
payload(p::PacketView) = return p.buf[p.lo:p.hi]

const READBUF_SIZE = 64 * 1024

"""
    PacketIO

Reader/writer state: one shared sequence counter, a reusable reassembly buffer, a reusable
output buffer, the count of payload bytes consumed since the last `newcommand!` (fed to
`max_response_bytes`), the read buffer that batches small transport reads during the
command phase (`readbuf[readpos:readlim]` holds bytes already taken from the transport), and
the per-operation timeouts (`read_timeout_ns`/`write_timeout_ns`, 0 = none): every transport
read or write re-arms its deadline `timeout` from now, like Connector/C's
`MYSQL_OPT_READ_TIMEOUT`/`MYSQL_OPT_WRITE_TIMEOUT`, so a slowly consumed streaming result
never expires while the server keeps answering.
"""
mutable struct PacketIO
    seq::UInt8
    inbuf::Vector{UInt8}
    header::Vector{UInt8}
    outbuf::Vector{UInt8}
    response_bytes::UInt64
    readbuf::Vector{UInt8}
    readpos::Int
    readlim::Int
    read_timeout_ns::Int64
    write_timeout_ns::Int64
end

PacketIO() = return PacketIO(0x00, UInt8[], zeros(UInt8, PACKET_HEADER_LEN), UInt8[], 0x0000000000000000, Vector{UInt8}(undef, READBUF_SIZE), 1, 0, 0, 0)

buffered_bytes_available(io::PacketIO) = return io.readlim - io.readpos + 1

@inline function deadline_after_ns(timeout_ns::Int64)
    now = Int64(time_ns())
    return timeout_ns > typemax(Int64) - now ? typemax(Int64) : now + timeout_ns
end

# Re-arms the read deadline before a transport read when a per-read timeout is configured
# (a no-op otherwise, so the default path costs nothing).
@inline function arm_read_deadline!(io::PacketIO, transport::Transport)
    io.read_timeout_ns == 0 || set_read_deadline!(transport, deadline_after_ns(io.read_timeout_ns))
    return nothing
end

@inline function arm_write_deadline!(io::PacketIO, transport::Transport)
    io.write_timeout_ns == 0 || set_write_deadline!(transport, deadline_after_ns(io.write_timeout_ns))
    return nothing
end

# Refills the (empty) read buffer with at least `needed` bytes using large partial reads.
function fill_readbuf!(io::PacketIO, transport::Transport, needed::Int)
    io.readpos = 1
    io.readlim = 0
    total = 0
    while total < needed
        arm_read_deadline!(io, transport)
        got = transport_read_some!(transport, io.readbuf, total + 1, length(io.readbuf) - total)
        got == 0 && throw(EOFError())
        total += got
    end
    io.readlim = total
    return nothing
end

"""
    packet_read!(io, transport, dest, offset, n, buffered)

Reads exactly `n` bytes into `dest[offset:offset+n-1]`. With `buffered=true` (command
phase: the byte stream can only carry this connection's current response) small reads are
served from `io.readbuf`, which is refilled with large partial reads; reads of half the
buffer or more bypass it. `buffered=false` (connection phase) reads byte-exact from the
transport, so the STARTTLS empty-reader invariant is untouched.
"""
function packet_read!(io::PacketIO, transport::Transport, dest::Vector{UInt8}, offset::Int, n::Int, buffered::Bool)
    if !buffered || !supports_buffered_reads(transport)
        arm_read_deadline!(io, transport)
        transport_read!(transport, dest, offset, n)
        return nothing
    end
    avail = buffered_bytes_available(io)
    take = min(avail, n)
    if take > 0
        copyto!(dest, offset, io.readbuf, io.readpos, take)
        io.readpos += take
        offset += take
        n -= take
    end
    n == 0 && return nothing
    if n >= length(io.readbuf) >> 1
        arm_read_deadline!(io, transport)
        transport_read!(transport, dest, offset, n)
        return nothing
    end
    fill_readbuf!(io, transport, n)
    copyto!(dest, offset, io.readbuf, io.readpos, n)
    io.readpos += n
    return nothing
end

function newcommand!(io::PacketIO)
    io.seq = 0x00
    io.response_bytes = 0
    return nothing
end

@noinline sequence_mismatch(expected::UInt8, got::UInt8) = return protocol_error("sequence id mismatch: expected $(Int(expected)), got $(Int(got))")

"""
    readpacket!(io, transport, max_payload; max_response=nothing, dest=io.inbuf, buffered=false) -> PacketView

Reads one logical packet, reassembling continuation chunks, validating sequence ids, and
bounding the reassembled size by `max_payload` *before* growing the buffer. `max_response`
bounds the cumulative payload bytes since `newcommand!`. `dest` is the buffer the payload is
read into (a cursor passes its own buffer so rows never alias the shared reader buffer).
`buffered=true` batches transport reads through `io.readbuf` (command phase only).
"""
function readpacket!(io::PacketIO, transport::Transport, max_payload::Int; max_response::Union{Nothing, Int}=nothing, dest::Vector{UInt8}=io.inbuf, buffered::Bool=false)
    total = 0
    nchunks = 0
    first_chunk_len = -1
    seq = io.seq
    while true
        packet_read!(io, transport, io.header, 1, PACKET_HEADER_LEN, buffered)
        len = Int(io.header[1]) | (Int(io.header[2]) << 8) | (Int(io.header[3]) << 16)
        got = io.header[4]
        got == io.seq || sequence_mismatch(io.seq, got)
        io.seq += 0x01
        nchunks += 1
        first_chunk_len < 0 && (first_chunk_len = len)
        check_limit("packet length", total + len, max_payload)
        next_response_bytes = io.response_bytes + UInt64(len)
        max_response === nothing || next_response_bytes <= UInt64(max_response) || throw(ProtocolError("response bytes $(next_response_bytes) exceeds limit $(max_response)"))
        length(dest) < total + len && resize!(dest, total + len)
        packet_read!(io, transport, dest, total + 1, len, buffered)
        total += len
        io.response_bytes = next_response_bytes
        len < MAX_CHUNK && break
    end
    return PacketView(dest, 1, total, seq, nchunks, first_chunk_len)
end

# Frames `payload` into chunks in `io.outbuf` (one write per logical packet), advancing the
# sequence counter per chunk. Any exception escaping `transport_write` leaves the amount
# actually written unknown: callers mark the session Broken.
function sendpacket!(io::PacketIO, transport::Transport, payload::AbstractVector{UInt8})
    out = io.outbuf
    empty!(out)
    n = length(payload)
    offset = 0
    while true
        chunk = min(MAX_CHUNK, n - offset)
        write_u24!(out, chunk)
        push!(out, io.seq)
        io.seq += 0x01
        chunk > 0 && append!(out, view(payload, (offset + 1):(offset + chunk)))
        offset += chunk
        # a payload that is an exact multiple of 0xFFFFFF (including 0) ends with an empty chunk
        (chunk < MAX_CHUNK) && break
    end
    arm_write_deadline!(io, transport)
    transport_write(transport, out)
    return nothing
end

# Number of wire chunks `sendpacket!` produces for a payload of `n` bytes.
chunk_count(n::Integer) = return Int(div(n, MAX_CHUNK)) + 1
