module MySQL

using Dates, DBInterface, Tables, Parsers, DecFP, Reseau
import Random

export DBInterface, DateAndTime

# For errors raised by MySQL.jl itself (not the server or the wire protocol)
struct MySQLInterfaceError
    msg::String
end
Base.showerror(io::IO, e::MySQLInterfaceError) = print(io, e.msg)

# The MySQL client/server wire protocol on Reseau transports; see docs/protocol-notes.md
include("Protocol/Protocol.jl")

const P = Protocol

# The protocol error hierarchy under its 1.x names: `MySQL.Error` / `MySQL.StmtError` are
# what `DBInterface.execute`/`prepare` throw for server errors (`MySQL.API.Error` /
# `MySQL.API.StmtError` before 2.0), rooted at `MySQL.MySQLError`.
const MySQLError = Protocol.MySQLError
const Error = Protocol.Error
const StmtError = Protocol.StmtError

include("types.jl")
include("decode.jl")
include("binary.jl")
include("options.jl")
include("reaper.jl")
include("connect.jl")
include("connection.jl")
include("cursor.jl")
include("statement.jl")
include("load.jl")

# `juliac --trim` compiles only code reachable from registered entrypoints. Runtime-invoked
# callbacks — the reaper's timer tick and atexit hook, GC finalizers, and the bind-resolver
# task — are dispatched dynamically at run time, so their specializations are registered
# explicitly (a no-op cost outside juliac builds).
@static if isdefined(Base.Experimental, :entrypoint)
    Base.Experimental.entrypoint(reaper_tick, (Timer,))
    Base.Experimental.entrypoint(reaper_atexit, ())
    Base.Experimental.entrypoint(finalize_handle, (Handle,))
    Base.Experimental.entrypoint(finalize_statement, (Statement,))
    Base.Experimental.entrypoint(Tuple{BindResolve{typeof(Reseau.HostResolvers.resolve_tcp_addrs)}})
end

end # module
