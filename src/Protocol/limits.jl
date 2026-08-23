const MAX_PACKET_CAP = 1024 * 1024 * 1024          # 1 GiB: the server-side max_allowed_packet ceiling
const DEFAULT_MAX_PACKET = 16 * 1024 * 1024
const DEFAULT_MAX_PREAUTH_PACKET = 1024 * 1024
const DEFAULT_MAX_BUFFERED_BYTES = 256 * 1024 * 1024

"""
    Limits(; kw...)

Resource bounds enforced by the packet reader and the phase machine. Every declared length
is checked against these *before* allocation.

- `max_packet` (16 MiB, cap 1 GiB): one logical (reassembled) packet after authentication
- `max_preauth_packet` (1 MiB): one logical packet before authentication completes
- `max_auth_rounds` (8) / `max_auth_bytes` (64 KiB): authentication exchange bounds
- `max_columns` (4096): columns per result set
- `max_result_sets` (1024): result sets per command
- `max_metadata_bytes` (16 MiB): column-definition bytes per command
- `max_buffered_bytes` (256 MiB, `nothing` = unlimited): all retained buffered storage of
  one command (row bytes, offsets, NULL masks, metadata, retained multi-result cursors)
- `max_response_bytes` (`nothing` = unlimited): optional aggregate cap over an entire
  response, streaming rows included
- `max_session_state_bytes` (1 MiB): session-state blocks in one OK packet
"""
struct Limits
    max_packet::Int
    max_preauth_packet::Int
    max_auth_rounds::Int
    max_auth_bytes::Int
    max_columns::Int
    max_result_sets::Int
    max_metadata_bytes::Int
    max_buffered_bytes::Union{Nothing, Int}
    max_response_bytes::Union{Nothing, Int}
    max_session_state_bytes::Int
end

function Limits(;
        max_packet::Integer=DEFAULT_MAX_PACKET,
        max_preauth_packet::Integer=min(DEFAULT_MAX_PREAUTH_PACKET, max_packet),
        max_auth_rounds::Integer=8,
        max_auth_bytes::Integer=64 * 1024,
        max_columns::Integer=4096,
        max_result_sets::Integer=1024,
        max_metadata_bytes::Integer=16 * 1024 * 1024,
        max_buffered_bytes::Union{Nothing, Integer}=DEFAULT_MAX_BUFFERED_BYTES,
        max_response_bytes::Union{Nothing, Integer}=nothing,
        max_session_state_bytes::Integer=1024 * 1024,
    )
    1 <= max_packet <= MAX_PACKET_CAP || throw(ArgumentError("max_packet must be in 1:$(MAX_PACKET_CAP)"))
    1 <= max_preauth_packet <= max_packet || throw(ArgumentError("max_preauth_packet must be in 1:max_packet"))
    max_auth_rounds >= 1 || throw(ArgumentError("max_auth_rounds must be >= 1"))
    max_auth_bytes >= 1 || throw(ArgumentError("max_auth_bytes must be >= 1"))
    max_columns >= 1 || throw(ArgumentError("max_columns must be >= 1"))
    max_result_sets >= 1 || throw(ArgumentError("max_result_sets must be >= 1"))
    max_metadata_bytes >= 1 || throw(ArgumentError("max_metadata_bytes must be >= 1"))
    max_buffered_bytes === nothing || max_buffered_bytes >= 1 || throw(ArgumentError("max_buffered_bytes must be >= 1 or nothing"))
    max_response_bytes === nothing || max_response_bytes >= 1 || throw(ArgumentError("max_response_bytes must be >= 1 or nothing"))
    max_session_state_bytes >= 1 || throw(ArgumentError("max_session_state_bytes must be >= 1"))
    max_auth_rounds <= typemax(Int) || throw(ArgumentError("max_auth_rounds exceeds typemax(Int)"))
    max_auth_bytes <= typemax(Int) || throw(ArgumentError("max_auth_bytes exceeds typemax(Int)"))
    max_columns <= typemax(Int) || throw(ArgumentError("max_columns exceeds typemax(Int)"))
    max_result_sets <= typemax(Int) || throw(ArgumentError("max_result_sets exceeds typemax(Int)"))
    max_metadata_bytes <= typemax(Int) || throw(ArgumentError("max_metadata_bytes exceeds typemax(Int)"))
    max_buffered_bytes === nothing || max_buffered_bytes <= typemax(Int) || throw(ArgumentError("max_buffered_bytes exceeds typemax(Int)"))
    max_response_bytes === nothing || max_response_bytes <= typemax(Int) || throw(ArgumentError("max_response_bytes exceeds typemax(Int)"))
    max_session_state_bytes <= typemax(Int) || throw(ArgumentError("max_session_state_bytes exceeds typemax(Int)"))
    return Limits(Int(max_packet), Int(max_preauth_packet), Int(max_auth_rounds), Int(max_auth_bytes), Int(max_columns), Int(max_result_sets), Int(max_metadata_bytes), max_buffered_bytes === nothing ? nothing : Int(max_buffered_bytes), max_response_bytes === nothing ? nothing : Int(max_response_bytes), Int(max_session_state_bytes))
end

@noinline limit_exceeded(what::String, value::Integer, limit::Integer) = return protocol_error("$what $value exceeds limit $limit")

@inline function check_limit(what::String, value::Integer, limit::Integer)
    value <= limit || limit_exceeded(what, value, limit)
    return nothing
end

@inline function check_limit(what::String, value::Integer, limit::Nothing)
    return nothing
end
