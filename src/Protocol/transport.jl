# Transports the session can own. A concrete union keeps the packet hot path an `isa` split
# (no abstract-typed field). Unix sockets / named pipes are deferred, so there is no
# `Sockets` dependency.

"""
    FaultTransport(inner; fail_read_at=-1, fail_write_at=-1, read_error, write_error, after_write_error=nothing)

Test-only transport wrapper that injects faults at byte offsets:

- `fail_read_at = n`: the read that would move the cumulative read count past `n` bytes
  first delivers the bytes up to `n`, then throws `read_error`
- `fail_write_at = n`: the write that would move the cumulative write count past `n` bytes
  first writes the bytes up to `n` (a short write), then throws `write_error`
- `after_write_error`: thrown *after* a write completed in full — models an interruption
  between a successful send and the state advancement that follows it

Counters are plain integers; a `FaultTransport` is used from one task.
"""
mutable struct FaultTransport <: IO
    inner::IO
    read_bytes::Int
    write_bytes::Int
    fail_read_at::Int
    fail_write_at::Int
    read_error::Exception
    write_error::Exception
    after_write_error::Union{Nothing, Exception}
    closed::Bool
end

function FaultTransport(inner::IO; fail_read_at::Integer=-1, fail_write_at::Integer=-1, read_error::Exception=EOFError(), write_error::Exception=EOFError(), after_write_error::Union{Nothing, Exception}=nothing)
    return FaultTransport(inner, 0, 0, Int(fail_read_at), Int(fail_write_at), read_error, write_error, after_write_error, false)
end

const Transport = Union{Reseau.TCP.Conn, Reseau.TLS.Conn, FaultTransport}

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
        allowed > 0 && unsafe_write(ft.inner, ptr, UInt(allowed))
        ft.write_bytes += allowed
        throw(ft.write_error)
    end
    unsafe_write(ft.inner, ptr, nbytes)
    ft.write_bytes += n
    ft.after_write_error === nothing || throw(ft.after_write_error)
    return n
end

function Base.write(ft::FaultTransport, bytes::Vector{UInt8})
    GC.@preserve bytes unsafe_write(ft, pointer(bytes), UInt(length(bytes)))
    return length(bytes)
end

Base.isopen(ft::FaultTransport) = !ft.closed && isopen(ft.inner)
Base.eof(ft::FaultTransport) = eof(ft.inner)
Base.flush(ft::FaultTransport) = (flush(ft.inner); nothing)

function Base.close(ft::FaultTransport)
    ft.closed = true
    close(ft.inner)
    return nothing
end

# ---- uniform transport operations ----

@inline function transport_read!(t::Transport, buf::Vector{UInt8}, offset::Int, n::Int)
    n == 0 && return nothing
    GC.@preserve buf unsafe_read(t, pointer(buf, offset), UInt(n))
    return nothing
end

@inline transport_write(t::Transport, bytes::Vector{UInt8}) = (write(t, bytes); nothing)

transport_isopen(t::Transport) = isopen(t)

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

# A deadline expiry surfaces directly on TCP and wrapped in TLSError on TLS.
function is_deadline_error(err)
    err isa Reseau.IOPoll.DeadlineExceededError && return true
    err isa Reseau.HostResolvers.DialTimeoutError && return true
    err isa Reseau.HostResolvers.OpError && return is_deadline_error(err.err)
    err isa Reseau.TLS.TLSError && return is_deadline_error(err.cause)
    return false
end
