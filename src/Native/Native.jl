"""
    MySQL.Native

The native wire-protocol backend's driver layer: option validation (the compatibility truth
table, option files), the single connection-establishment deadline, STARTTLS,
authentication, the utf8mb4 bootstrap, the finalizer-free reaper, and text-protocol value decoding (`decode.jl`).
"""
module Native

using ..Protocol
using ..MySQL: MySQL, API, DateAndTime, MySQLInterfaceError
using Reseau, Dates, DBInterface, Tables, Parsers, DecFP

const P = Protocol

include("decode.jl")
include("options.jl")
include("reaper.jl")
include("connect.jl")

end # module
