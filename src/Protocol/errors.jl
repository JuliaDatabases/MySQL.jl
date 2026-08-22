"""
    MySQLError

Root of the native backend's exception hierarchy.

- `ServerError` (`Error`, `StmtError`): an ERR packet sent by the server
- `ProtocolError`: the byte stream violated the protocol (or a limit); the connection is closed
- `AuthError` / `UnsupportedAuthError`: authentication policy or plugin problems
- `TimeoutError`: a deadline expired
- `ConversionError`: a wire value cannot be represented by the requested Julia type
- `LocalInfileRefused`: the LOCAL INFILE handler declined a server request
"""
abstract type MySQLError <: Exception end

abstract type ServerError <: MySQLError end

"""
    Error(errno, msg, sqlstate="")

Server ERR packet raised by connection-level operations. `errno::Cuint` and `msg` keep the
field names and types of the Connector/C-backed `MySQL.API.Error`; `sqlstate` is new.
"""
struct Error <: ServerError
    errno::Cuint
    msg::String
    sqlstate::String
end

Error(errno::Integer, msg::AbstractString, sqlstate::AbstractString="") = Error(Cuint(errno), String(msg), String(sqlstate))

"""
    StmtError(errno, msg, sqlstate="")

Server ERR packet raised by prepared-statement operations (distinct type on purpose so
`@test_throws MySQL.API.StmtError` style dispatch keeps working).
"""
struct StmtError <: ServerError
    errno::Cuint
    msg::String
    sqlstate::String
end

StmtError(errno::Integer, msg::AbstractString, sqlstate::AbstractString="") = StmtError(Cuint(errno), String(msg), String(sqlstate))

Base.showerror(io::IO, e::ServerError) = print(io, "(", e.errno, "): ", e.msg)

struct ProtocolError <: MySQLError
    msg::String
end

struct AuthError <: MySQLError
    msg::String
end

struct UnsupportedAuthError <: MySQLError
    plugin::String
    msg::String
end

UnsupportedAuthError(plugin::AbstractString) = UnsupportedAuthError(String(plugin), "authentication plugin '$plugin' is not supported")

struct TimeoutError <: MySQLError
    msg::String
end

struct TLSNegotiationError <: MySQLError
    msg::String
    cause::Union{Nothing, Exception}
end

struct ConversionError <: MySQLError
    msg::String
end

struct LocalInfileRefused <: MySQLError
    filename::String
    msg::String
    cause::Union{Nothing, ServerError}
end

LocalInfileRefused(filename::AbstractString, msg::AbstractString) = LocalInfileRefused(String(filename), String(msg), nothing)

function Base.showerror(io::IO, e::Union{ProtocolError, AuthError, TimeoutError, ConversionError, TLSNegotiationError})
    print(io, nameof(typeof(e)), ": ", e.msg)
    return nothing
end

function Base.showerror(io::IO, e::UnsupportedAuthError)
    print(io, "UnsupportedAuthError: ", e.msg)
    return nothing
end

function Base.showerror(io::IO, e::LocalInfileRefused)
    print(io, "LocalInfileRefused: ", e.msg)
    return nothing
end

@noinline protocol_error(msg::String) = throw(ProtocolError(msg))
