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

payload_length(p::PacketView) = p.hi - p.lo + 1
PacketCursor(p::PacketView) = PacketCursor(p.buf, p.lo, p.hi)
first_byte(p::PacketView) = payload_length(p) == 0 ? nothing : (@inbounds p.buf[p.lo])
payload(p::PacketView) = p.buf[p.lo:p.hi]

"""
    PacketIO

Reader/writer state: one shared sequence counter, a reusable reassembly buffer, a reusable
output buffer, and the count of payload bytes consumed since the last `newcommand!` (fed to
`max_response_bytes`).
"""
mutable struct PacketIO
    seq::UInt8
    inbuf::Vector{UInt8}
    header::Vector{UInt8}
    outbuf::Vector{UInt8}
    response_bytes::Int
end

PacketIO() = PacketIO(0x00, UInt8[], zeros(UInt8, PACKET_HEADER_LEN), UInt8[], 0)

function newcommand!(io::PacketIO)
    io.seq = 0x00
    io.response_bytes = 0
    return nothing
end

@noinline sequence_mismatch(expected::UInt8, got::UInt8) = protocol_error("sequence id mismatch: expected $(Int(expected)), got $(Int(got))")

"""
    readpacket!(io, transport, max_payload; max_response=nothing, dest=io.inbuf) -> PacketView

Reads one logical packet, reassembling continuation chunks, validating sequence ids, and
bounding the reassembled size by `max_payload` *before* growing the buffer. `max_response`
bounds the cumulative payload bytes since `newcommand!`. `dest` is the buffer the payload is
read into (a cursor passes its own buffer so rows never alias the shared reader buffer).
"""
function readpacket!(io::PacketIO, transport::Transport, max_payload::Int; max_response::Union{Nothing, Int}=nothing, dest::Vector{UInt8}=io.inbuf)
    total = 0
    nchunks = 0
    first_chunk_len = -1
    seq = io.seq
    while true
        transport_read!(transport, io.header, 1, PACKET_HEADER_LEN)
        len = Int(io.header[1]) | (Int(io.header[2]) << 8) | (Int(io.header[3]) << 16)
        got = io.header[4]
        got == io.seq || sequence_mismatch(io.seq, got)
        io.seq += 0x01
        nchunks += 1
        first_chunk_len < 0 && (first_chunk_len = len)
        check_limit("packet length", total + len, max_payload)
        check_limit("response bytes", io.response_bytes + len, max_response)
        length(dest) < total + len && resize!(dest, total + len)
        transport_read!(transport, dest, total + 1, len)
        total += len
        io.response_bytes += len
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
    transport_write(transport, out)
    return nothing
end

# Number of wire chunks `sendpacket!` produces for a payload of `n` bytes.
chunk_count(n::Integer) = Int(div(n, MAX_CHUNK)) + 1
