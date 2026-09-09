module MySQL

import DataDecimals
import DataStrings
using DataStrings: DataString, DataBytes
using Dates, DBInterface, Tables, Parsers, Reseau
using Durations: Timestamp
import Random

# `Timestamp` is re-exported from Durations.jl (the `Dates.Timestamp` proposed for Julia
# 1.14): every DATETIME/TIMESTAMP column decodes to it.
export DBInterface, Timestamp

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
include("precompile.jl")

end # module
