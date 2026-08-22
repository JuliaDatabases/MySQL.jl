"""
    MySQL.Protocol

Native implementation of the MySQL client/server wire protocol (packet framing, connection
phase, command phase) on top of Reseau transports. This module has no DBInterface/Tables
dependency; the public driver layer builds on it.

M1: constants, bounded codecs, packet reader/writer, the phase machine, handshake packets,
generic response packets, column definitions, command/response framing. Authentication
plugins, TLS orchestration, value decoding and the DBInterface layer follow later.
"""
module Protocol

using Reseau

include("errors.jl")
include("codec.jl")
include("limits.jl")
include("constants.jl")
include("transport.jl")
include("packets.jl")
include("phases.jl")
include("handshake.jl")
include("columns.jl")
include("responses.jl")
include("session.jl")
include("commands.jl")

end # module
