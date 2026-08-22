"""
    MySQL.Native

The native wire-protocol backend's driver layer: option validation (the compatibility truth
table, option files), the single connection-establishment deadline, STARTTLS,
authentication, the utf8mb4 bootstrap, the finalizer-free reaper, and the DBInterface
surface (`Native.Connection`, prepared statements, and text/binary cursors). Opt-in during 1.x:
`DBInterface.connect(MySQL.Native.Connection, host, user, password; kw...)`.
"""
module Native

using ..Protocol
using ..MySQL: MySQL, API, DateAndTime, MySQLInterfaceError
using Reseau, Dates, DBInterface, Tables, Parsers, DecFP

const P = Protocol

include("decode.jl")
include("binary.jl")
include("options.jl")
include("reaper.jl")
include("connect.jl")
include("connection.jl")
include("cursor.jl")
include("statement.jl")

end # module
