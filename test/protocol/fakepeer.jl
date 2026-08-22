# A scripted MySQL "server" on a loopback Reseau TCP listener. A test supplies a handler
# that reads/writes raw packets on the accepted connection while the client side drives a
# `Protocol.Session`. No real server is needed, so this runs on every CI platform.
module FakePeer

using Reseau

const TCP = Reseau.TCP

struct Peer
    listener::TCP.Listener
    port::Int
    task::Task
    error::Ref{Any}
end

# Parses "0a 35 2e ..." (whitespace/pipes ignored) into bytes.
function hexbytes(s::AbstractString)
    cleaned = replace(s, r"[\s|]+" => "")
    isodd(length(cleaned)) && error("odd hex length")
    return [parse(UInt8, cleaned[i:(i + 1)]; base=16) for i in 1:2:length(cleaned)]
end

# Raw framing helpers used by handlers (server side).
function send_packet(conn::IO, seq::Integer, payload::AbstractVector{UInt8})
    n = length(payload)
    header = UInt8[n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, seq & 0xFF]
    write(conn, vcat(header, payload))
    return nothing
end

send_raw(conn::IO, bytes::AbstractVector{UInt8}) = (write(conn, Vector{UInt8}(bytes)); nothing)

function read_exact(conn::IO, n::Integer)
    buf = Vector{UInt8}(undef, n)
    n == 0 && return buf
    GC.@preserve buf unsafe_read(conn, pointer(buf), UInt(n))
    return buf
end

# Reads one wire chunk: returns (seq, payload).
function read_chunk(conn::IO)
    h = read_exact(conn, 4)
    len = Int(h[1]) | (Int(h[2]) << 8) | (Int(h[3]) << 16)
    return h[4], read_exact(conn, len)
end

# Reads one logical packet (reassembling 0xFFFFFF chunks): returns (first_seq, payload).
function read_packet(conn::IO)
    seq, payload = read_chunk(conn)
    total = payload
    while length(payload) == 0xFFFFFF
        _, payload = read_chunk(conn)
        append!(total, payload)
    end
    return seq, total
end

# Drains one client command packet and returns (seq, command byte, payload without it).
function read_command(conn::IO)
    seq, payload = read_packet(conn)
    return seq, payload[1], payload[2:end]
end

"""
    serve(handler) -> Peer

Starts a loopback listener; the first accepted connection is handed to `handler(conn)` on a
task. Exceptions thrown by the handler are stored in `peer.error`.
"""
function serve(handler::Function)
    listener = TCP.listen(TCP.loopback_addr(0))
    port = Int(TCP.addr(listener).port)
    err = Ref{Any}(nothing)
    task = Threads.@spawn begin
        conn = nothing
        try
            conn = TCP.accept(listener)
            handler(conn)
        catch e
            err[] = e
        finally
            conn === nothing || close(conn)
        end
    end
    errormonitor(task)
    return Peer(listener, port, task, err)
end

function Base.close(peer::Peer)
    close(peer.listener)
    wait(peer.task)
    return nothing
end

"""
    with_peer(f, handler; connect_timeout_ns=5_000_000_000)

Runs `handler` as the server and `f(client_conn)` as the client, then tears everything down.
Returns `f`'s result; rethrows a handler error after `f` finishes.
"""
function with_peer(f::Function, handler::Function; connect_timeout_ns::Integer=5_000_000_000)
    peer = serve(handler)
    client = nothing
    result = nothing
    try
        client = TCP.connect("127.0.0.1:$(peer.port)"; timeout_ns=connect_timeout_ns)
        result = f(client)
    finally
        client === nothing || close(client)
        close(peer)
    end
    peer.error[] === nothing || throw(peer.error[])
    return result
end

end # module
