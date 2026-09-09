"""
    MySQL.Protocol

Native implementation of the MySQL client/server wire protocol on top of Reseau transports:
constants generated from the server headers, bounded codecs, packet framing with
reassembly, the phase machine, handshake and capability negotiation, authentication plugins
(`mysql_native_password`, `caching_sha2_password`, `sha256_password`,
`mysql_clear_password`) with OpenSSL-backed RSA-OAEP, STARTTLS, generic responses, column
definitions, text and binary row scanning, and the command/response framing of COM_QUERY,
the COM_STMT_* family, LOCAL INFILE and the simple commands. It has no DBInterface/Tables
dependency; the `MySQL` driver layer (value decoding, connections, cursors, statements)
builds on it. See `docs/protocol-notes.md`.
"""
module Protocol

using Reseau, SHA
using OpenSSL_jll: libcrypto

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
include("stmt.jl")
include("crypto.jl")
include("auth.jl")
include("tls.jl")

end # module
