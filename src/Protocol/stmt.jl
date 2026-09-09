# Prepared-statement command phase at the framing level: COM_STMT_PREPARE and its
# PREPARE_OK response (statement id, parameter and column definitions), COM_STMT_EXECUTE
# (the driver layer serialises the parameter block; here we only frame it), COM_STMT_RESET,
# COM_STMT_SEND_LONG_DATA and COM_STMT_CLOSE. Binary row *values* are decoded by the driver
# layer; here rows are raw `PacketView`s, exactly as for the text protocol.

"""
    PrepareOK

The result of `COM_STMT_PREPARE`: the server-assigned `statement_id`, the parameter and
result-column definitions (execute-time metadata stays authoritative for decoding), and the
prepare-time warning count.
"""
struct PrepareOK
    statement_id::UInt32
    params::Vector{ColumnDef}
    columns::Vector{ColumnDef}
    warnings::UInt16
end

num_params(ok::PrepareOK) = return length(ok.params)
num_columns(ok::PrepareOK) = return length(ok.columns)

"""
    stmt_prepare!(s, sql)

Sends `COM_STMT_PREPARE`; read the answer with `read_prepare_response!`.
"""
function stmt_prepare!(s::Session, sql::AbstractString)
    out = start_command!(s, COM_STMT_PREPARE)
    append!(out, codeunits(sql))
    return finish_command!(s, CMD_STMT_PREPARE)
end

# Reads one metadata block (`n` column definitions, then the EOF that closes it unless
# DEPRECATE_EOF), bounded by `max_metadata_bytes` before every allocation.
function read_definition_block!(s::Session, n::Int)
    defs = ColumnDef[]
    for _ in 1:n
        cp = readpacket!(s; packet_limit=s.limits.max_metadata_bytes - s.metadata_bytes)
        s.metadata_bytes += payload_length(cp)
        s.metadata_bytes <= s.limits.max_metadata_bytes || throw(fault!(s, ProtocolError("prepared-statement metadata exceeded $(s.limits.max_metadata_bytes) bytes")))
        push!(defs, guarded(() -> parse_column_def(cp), s))
    end
    if !deprecate_eof(s)
        ep = readpacket!(s)
        is_eof_packet(ep) || throw(fault!(s, ProtocolError("expected EOF after prepared-statement definitions")))
        s.status = guarded(() -> parse_eof(ep, s.capabilities), s).status
    end
    return defs
end

"""
    read_prepare_response!(s) -> PrepareOK

Reads the `COM_STMT_PREPARE` response: the PREPARE_OK header, then (when present) the
parameter definitions and their EOF, then the column definitions and their EOF. Returns the
session to `READY`. A server ERR is thrown as `StmtError`.
"""
function read_prepare_response!(s::Session)
    require_phase(s, CMD_SENT)
    p = readpacket!(s)
    b = first_byte(p)
    if b == ERR_HEADER
        e = guarded(() -> parse_err(p, s.capabilities), s)
        transition!(s, :err, READY)
        throw(StmtError(e))
    end
    b == OK_HEADER || throw(fault!(s, ProtocolError("expected COM_STMT_PREPARE_OK, got header 0x$(string(something(b, 0xFF), base=16, pad=2))")))
    header = guarded(() -> parse_prepare_ok_header(p), s)
    statement_id, ncols, nparams, warnings = header
    (ncols <= s.limits.max_columns && nparams <= s.limits.max_columns) || throw(fault!(s, ProtocolError("prepared statement declares $ncols columns / $nparams parameters, above max_columns=$(s.limits.max_columns)")))
    s.metadata_bytes = 0
    params = nparams > 0 ? read_definition_block!(s, nparams) : ColumnDef[]
    columns = ncols > 0 ? read_definition_block!(s, ncols) : ColumnDef[]
    transition!(s, :prepare_ok, READY)
    return PrepareOK(statement_id, params, columns, warnings)
end

# PREPARE_OK fixed header: status(1) statement_id(4) num_columns(2) num_params(2)
# reserved(1) [warning_count(2) metadata_follows(1)]. `metadata_follows` only appears with
# CLIENT_OPTIONAL_RESULTSET_METADATA, which 2.0 never negotiates.
function parse_prepare_ok_header(p::PacketView)
    c = PacketCursor(p)
    read_u8!(c) == OK_HEADER || protocol_error("malformed COM_STMT_PREPARE_OK header")
    statement_id = read_u32!(c)
    ncols = Int(read_u16!(c))
    nparams = Int(read_u16!(c))
    read_u8!(c) == 0x00 || protocol_error("malformed COM_STMT_PREPARE_OK reserved byte")
    warnings = if atend(c)
        UInt16(0)
    elseif remaining(c) == 2
        read_u16!(c)
    else
        protocol_error("malformed COM_STMT_PREPARE_OK header: expected a 10- or 12-byte payload, got $(payload_length(p)) bytes")
    end
    atend(c) || protocol_error("malformed COM_STMT_PREPARE_OK header: $(remaining(c)) trailing bytes")
    return (statement_id, ncols, nparams, warnings)
end

"""
    build_stmt_execute(statement_id, param_block) -> Vector{UInt8}

Frames a `COM_STMT_EXECUTE` payload: `statement_id`, `flags=CURSOR_TYPE_NO_CURSOR`,
`iteration_count=1`, then the caller-built parameter block (NULL bitmap, the
`new_params_bind_flag`, the per-parameter type signature when it is set, and the non-NULL
values — all produced by the driver layer's binary encoders).
"""
function build_stmt_execute(statement_id::Integer, param_block::AbstractVector{UInt8})
    buf = UInt8[]
    write_u32!(buf, statement_id)
    write_u8!(buf, CURSOR_TYPE_NO_CURSOR)
    write_u32!(buf, 1)
    append!(buf, param_block)
    return buf
end

function stmt_execute!(s::Session, statement_id::Integer, param_block::AbstractVector{UInt8})
    out = start_stmt_execute!(s, statement_id)
    append!(out, param_block)
    return finish_command!(s, CMD_STMT_EXECUTE)
end

# Direct-framing variant: begins COM_STMT_EXECUTE in `io.outbuf` (statement id,
# `CURSOR_TYPE_NO_CURSOR`, `iteration_count=1`) and returns the buffer so the driver layer
# can append the parameter block in place; finish with `finish_command!(s, CMD_STMT_EXECUTE)`.
function start_stmt_execute!(s::Session, statement_id::Integer)
    out = start_command!(s, COM_STMT_EXECUTE)
    write_u32!(out, statement_id)
    write_u8!(out, CURSOR_TYPE_NO_CURSOR)
    write_u32!(out, 1)
    return out
end

"""
    stmt_reset!(s, statement_id)

`COM_STMT_RESET`: drops any accumulated long data and closes an open cursor. Answered with a
single OK/ERR; an ERR is classified as `StmtError`.
"""
function stmt_reset!(s::Session, statement_id::Integer)
    out = start_command!(s, COM_STMT_RESET)
    write_u32!(out, statement_id)
    return finish_command!(s, CMD_STMT_RESET)
end

"""
    stmt_send_long_data!(s, statement_id, param_id, data)

`COM_STMT_SEND_LONG_DATA`: appends `data` to parameter `param_id` of a prepared statement
before it is executed. The server never answers, so the session stays `READY`.
"""
function stmt_send_long_data!(s::Session, statement_id::Integer, param_id::Integer, data::AbstractVector{UInt8})
    out = start_command!(s, COM_STMT_SEND_LONG_DATA)
    write_u32!(out, statement_id)
    write_u16!(out, param_id)
    append!(out, data)
    return finish_noresponse!(s)
end
