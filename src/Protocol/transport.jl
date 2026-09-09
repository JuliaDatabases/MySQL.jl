# Transports the session can own. A concrete union keeps the packet hot path an `isa` split
# (no abstract-typed field). Unix sockets / named pipes are deferred, so there is no
# `Sockets` dependency.

"""
    FaultTransport(inner; fail_read_at=-1, fail_write_at=-1, read_error, write_error, after_write_error=nothing, discard_writes=false)

Test-only transport wrapper that injects faults at byte offsets:

- `fail_read_at = n`: the read that would move the cumulative read count past `n` bytes
  first delivers the bytes up to `n`, then throws `read_error`
- `fail_write_at = n`: the write that would move the cumulative write count past `n` bytes
  first writes the bytes up to `n` (a short write), then throws `write_error`
- `after_write_error`: thrown *after* a write completed in full — models an interruption
  between a successful send and the state advancement that follows it
- `discard_writes`: writes are counted but never forwarded to `inner` (a read-only script)

Byte counters are plain integers (a `FaultTransport` is used from one task); `close_count`
is atomic because the reaper's timer task may race an explicit close in tests.
"""
mutable struct FaultTransport{T <: IO} <: IO
    inner::T
    read_bytes::Int
    write_bytes::Int
    fail_read_at::Int
    fail_write_at::Int
    read_error::Exception
    write_error::Exception
    after_write_error::Union{Nothing, Exception}
    closed::Bool
    discard_writes::Bool
    @atomic close_count::Int
end

function FaultTransport(inner::IO; fail_read_at::Integer=-1, fail_write_at::Integer=-1, read_error::Exception=EOFError(), write_error::Exception=EOFError(), after_write_error::Union{Nothing, Exception}=nothing, discard_writes::Bool=false)
    return FaultTransport{typeof(inner)}(inner, 0, 0, Int(fail_read_at), Int(fail_write_at), read_error, write_error, after_write_error, false, discard_writes, 0)
end

# A closed union of concrete types: the packet hot path stays an `isa` split, `--trim=safe`
# can resolve every transport operation statically, and no transport type (so no `close`
# method) can be defined after the reaper's timer task fixes its world age.
const Transport = Union{Reseau.TCP.Conn, Reseau.TLS.Conn, FaultTransport{IOBuffer}, FaultTransport{Reseau.TCP.Conn}}

function Base.unsafe_read(ft::FaultTransport, ptr::Ptr{UInt8}, nbytes::UInt)
    n = Int(nbytes)
    if ft.fail_read_at >= 0 && ft.read_bytes + n > ft.fail_read_at
        allowed = max(0, ft.fail_read_at - ft.read_bytes)
        allowed > 0 && unsafe_read(ft.inner, ptr, UInt(allowed))
        ft.read_bytes += allowed
        throw(ft.read_error)
    end
    unsafe_read(ft.inner, ptr, nbytes)
    ft.read_bytes += n
    return nothing
end

function Base.read(ft::FaultTransport, ::Type{UInt8})
    ref = Ref{UInt8}(0x00)
    GC.@preserve ref unsafe_read(ft, Base.unsafe_convert(Ptr{UInt8}, ref), UInt(1))
    return ref[]
end

function Base.unsafe_write(ft::FaultTransport, ptr::Ptr{UInt8}, nbytes::UInt)
    n = Int(nbytes)
    if ft.fail_write_at >= 0 && ft.write_bytes + n > ft.fail_write_at
        allowed = max(0, ft.fail_write_at - ft.write_bytes)
        (allowed > 0 && !ft.discard_writes) && unsafe_write(ft.inner, ptr, UInt(allowed))
        ft.write_bytes += allowed
        throw(ft.write_error)
    end
    ft.discard_writes || unsafe_write(ft.inner, ptr, nbytes)
    ft.write_bytes += n
    ft.after_write_error === nothing || throw(ft.after_write_error)
    return n
end

function Base.write(ft::FaultTransport, bytes::Vector{UInt8})
    GC.@preserve bytes unsafe_write(ft, pointer(bytes), UInt(length(bytes)))
    return length(bytes)
end

Base.isopen(ft::FaultTransport) = return !ft.closed && isopen(ft.inner)
Base.eof(ft::FaultTransport) = return eof(ft.inner)
Base.flush(ft::FaultTransport) = return (flush(ft.inner); nothing)

function Base.close(ft::FaultTransport)
    ft.closed = true
    @atomic ft.close_count += 1
    close(ft.inner)
    return nothing
end

# ---- uniform transport operations ----

# Whether the packet reader may batch reads through its read buffer (Reseau's `unsafe_read`
# costs one `recv` per call, so per-packet exact reads dominate large scans; §8.9). The
# test-only `FaultTransport` stays byte-exact so fault byte offsets remain deterministic.
supports_buffered_reads(::Union{Reseau.TCP.Conn, Reseau.TLS.Conn}) = return true
supports_buffered_reads(::FaultTransport) = return false

# Reads 1..n available bytes into `buf[offset:end]` (one transport read); 0 means EOF.
function transport_read_some!(t::Union{Reseau.TCP.Conn, Reseau.TLS.Conn}, buf::Vector{UInt8}, offset::Int, n::Int)
    return Base.readbytes!(t, view(buf, offset:lastindex(buf)), n; all=false)
end

function transport_read_some!(t::FaultTransport, buf::Vector{UInt8}, offset::Int, n::Int)
    if t.fail_read_at >= 0
        allowed = t.fail_read_at - t.read_bytes
        allowed <= 0 && throw(t.read_error)
        n = min(n, allowed)
    end
    dest = view(buf, offset:(offset + n - 1))
    got = t.inner isa IOBuffer ? readbytes!(t.inner, dest, n) : readbytes!(t.inner, dest, n; all=false)
    t.read_bytes += got
    return got
end

@inline transport_write(t::Transport, bytes::Vector{UInt8}) = return (write(t, bytes); nothing)

transport_isopen(t::Transport) = return isopen(t)

function transport_close(t::Transport)
    try
        close(t)
    catch
    end
    return nothing
end

function set_read_deadline!(t::Reseau.TCP.Conn, deadline_ns::Integer)
    Reseau.TCP.set_read_deadline!(t, deadline_ns)
    return nothing
end

function set_read_deadline!(t::Reseau.TLS.Conn, deadline_ns::Integer)
    Reseau.TLS.set_read_deadline!(t, deadline_ns)
    return nothing
end

function set_read_deadline!(t::FaultTransport, deadline_ns::Integer)
    t.inner isa Union{Reseau.TCP.Conn, Reseau.TLS.Conn} && set_read_deadline!(t.inner, deadline_ns)
    return nothing
end

function set_write_deadline!(t::Reseau.TCP.Conn, deadline_ns::Integer)
    Reseau.TCP.set_write_deadline!(t, deadline_ns)
    return nothing
end

function set_write_deadline!(t::Reseau.TLS.Conn, deadline_ns::Integer)
    Reseau.TLS.set_write_deadline!(t, deadline_ns)
    return nothing
end

function set_write_deadline!(t::FaultTransport, deadline_ns::Integer)
    t.inner isa Union{Reseau.TCP.Conn, Reseau.TLS.Conn} && set_write_deadline!(t.inner, deadline_ns)
    return nothing
end

# A deadline expiry surfaces directly on TCP and wrapped in TLSError on TLS (or one level
# deeper inside a resolver OpError). Non-recursive and `@inline` so exception paths carry
# no dynamic `::Any`-argument call under `--trim=safe`.
@inline is_plain_deadline_error(err) = return err isa Reseau.IOPoll.DeadlineExceededError || err isa Reseau.HostResolvers.DialTimeoutError

@inline function is_deadline_error(err)
    is_plain_deadline_error(err) && return true
    if err isa Reseau.HostResolvers.OpError
        e = err.err
        is_plain_deadline_error(e) && return true
        return e isa Reseau.TLS.TLSError && is_plain_deadline_error(e.cause)
    end
    err isa Reseau.TLS.TLSError && return is_plain_deadline_error(err.cause)
    return false
end
