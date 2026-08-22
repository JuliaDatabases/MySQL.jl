"""
    MySQL.Native

Connection orchestration for the native wire-protocol backend: option validation (the
compatibility truth table, option files), the single connection-establishment deadline,
STARTTLS, authentication, the utf8mb4 bootstrap, and the finalizer-free reaper. The
DBInterface-facing `Native.Connection` arrives in M3; M2 exposes `Native.connect` returning a
`Handle` around a `Protocol.Session`.
"""
module Native

using ..Protocol
using Reseau

const P = Protocol

include("options.jl")
include("reaper.jl")
include("connect.jl")

end # module
