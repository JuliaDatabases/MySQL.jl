# Command phase at the framing level: sending commands and walking their responses through
# the phase machine. Value decoding of rows belongs to the cursor layer (M3/M4); here rows
# are raw `PacketView`s.

"""
    ResultHeader

Column definitions of one result set (execute-time metadata is authoritative) and their
wire payload size for retained-buffer accounting.
"""
struct ResultHeader
    columns::Vector{ColumnDef}
    binary::Bool
    metadata_bytes::Int
end

"""
    ResultEnd

The terminator of one result set: status flags, warning count, the OK snapshot when the
terminator was an OK packet (DEPRECATE_EOF), and whether another result set follows.
"""
struct ResultEnd
    status::UInt16
    warnings::UInt16
    ok::Union{Nothing, OKPacket}
    more_results::Bool
end

const CommandResponse = Union{OKPacket, EOFPacket, ResultHeader, LocalInfileRequest}

function command_payload(command::UInt8, payload::AbstractVector{UInt8})
    buf = Vector{UInt8}(undef, 1 + length(payload))
    buf[1] = command
    copyto!(buf, 2, payload, 1, length(payload))
    return buf
end

function check_command_size!(s::Session, payload::AbstractVector{UInt8})
    length(payload) <= max_payload(s) - 1 || throw(fault!(s, ProtocolError("command packet length $(length(payload) + 1) exceeds limit $(max_payload(s))")))
    return nothing
end

"""
    send_command!(s, command, payload=UInt8[]; kind=CMD_QUERY)

Writes a command that expects a response (READY → CMD_SENT). The sequence counter restarts
at 0 and per-command accounting is reset.
"""
function send_command!(s::Session, command::UInt8, payload::AbstractVector{UInt8}=UInt8[]; kind::CommandKind=CMD_QUERY)
    require_phase(s, READY)
    check_command_size!(s, payload)
    newcommand!(s.io)
    s.result_sets = 0
    s.metadata_bytes = 0
    sendpacket!(s, command_payload(command, payload))
    s.command_kind = kind
    transition!(s, :send_command, CMD_SENT)
    return nothing
end

"""
    send_noresponse!(s, command, payload=UInt8[])

Writes a command the server never answers (COM_STMT_CLOSE, COM_STMT_SEND_LONG_DATA); the
session stays READY and must not read.
"""
function send_noresponse!(s::Session, command::UInt8, payload::AbstractVector{UInt8}=UInt8[])
    require_phase(s, READY)
    check_command_size!(s, payload)
    newcommand!(s.io)
    sendpacket!(s, command_payload(command, payload))
    transition!(s, :send_noresponse, READY)
    return nothing
end

query!(s::Session, sql::AbstractString) = send_command!(s, COM_QUERY, codeunits(sql); kind=CMD_QUERY)
ping!(s::Session) = send_command!(s, COM_PING; kind=CMD_SIMPLE)
init_db!(s::Session, db::AbstractString) = send_command!(s, COM_INIT_DB, codeunits(db); kind=CMD_SIMPLE)
reset_connection!(s::Session) = send_command!(s, COM_RESET_CONNECTION; kind=CMD_SIMPLE)

function set_option!(s::Session, option::Integer)
    buf = UInt8[]
    write_u16!(buf, option)
    return send_command!(s, COM_SET_OPTION, buf; kind=CMD_SET_OPTION)
end

function stmt_close!(s::Session, statement_id::Integer)
    buf = UInt8[]
    write_u32!(buf, statement_id)
    return send_noresponse!(s, COM_STMT_CLOSE, buf)
end

"""
    quit!(s)

Best-effort COM_QUIT followed by closing the transport. The server answers a COM_QUIT by
closing the connection, so nothing is read.
"""
function quit!(s::Session)
    if s.phase == READY
        try
            newcommand!(s.io)
            sendpacket!(s.io, s.transport, command_payload(COM_QUIT, UInt8[]))
        catch
        end
        transition!(s, :quit, CLOSED)
    end
    close!(s)
    return nothing
end

# ---- responses ----

"""
    read_command_response!(s; kind=CMD_QUERY) -> OKPacket | EOFPacket | ResultHeader | LocalInfileRequest

Reads the first packet of a command response and advances the phase: an OK returns to READY
(or RESULT_END when MORE_RESULTS_EXISTS is set), an ERR returns to READY and is thrown as
`Error` for connection commands or `StmtError` for prepared commands, a LOCAL INFILE request
enters LOCAL_INFILE, and a column count reads the column definitions (plus the
pre-DEPRECATE_EOF metadata EOF) and enters ROWS.
"""
function read_command_response!(s::Session; kind::CommandKind=s.command_kind)
    require_phase(s, CMD_SENT)
    s.command_kind = kind
    p = readpacket!(s)
    what = guarded(() -> classify_command_response(kind, p), s)
    (what == :ok || what == :eof || what == :column_count) && next_result_set!(s)
    what == :ok && return finish_ok!(s, p)
    what == :eof && return finish_eof!(s, p)
    what == :err && return throw_command_err!(s, p, kind)
    what == :local_infile && return begin_local_infile!(s, p)
    what == :prepare_ok && throw(fault!(s, ProtocolError("COM_STMT_PREPARE responses are not implemented yet")))
    return read_result_header!(s, p, kind == CMD_STMT_EXECUTE)
end

function finish_eof!(s::Session, p::PacketView)
    eof = guarded(() -> parse_eof(p, s.capabilities), s)
    s.status = eof.status
    more = more_results(eof)
    transition!(s, more ? :ok_more : :ok, more ? RESULT_END : READY)
    return eof
end

function finish_ok!(s::Session, p::PacketView)
    ok = guarded(() -> parse_ok(p, s.capabilities, s.limits), s)
    s.status = ok.status
    s.command_kind == CMD_LOCAL_INFILE && (s.command_kind = CMD_QUERY)
    if more_results(ok)
        transition!(s, :ok_more, RESULT_END)
    else
        transition!(s, :ok, READY)
    end
    return ok
end

function throw_command_err!(s::Session, p::PacketView, kind::CommandKind)
    e = guarded(() -> parse_err(p, s.capabilities), s)
    transition!(s, :err, READY)
    if kind == CMD_STMT_PREPARE || kind == CMD_STMT_EXECUTE || kind == CMD_STMT_RESET
        throw(StmtError(e))
    end
    throw(Error(e))
end

function begin_local_infile!(s::Session, p::PacketView)
    has_capability(s, CLIENT_LOCAL_FILES) || throw(fault!(s, ProtocolError("server sent a LOCAL INFILE request although CLIENT_LOCAL_FILES was not negotiated")))
    req = guarded(() -> parse_local_infile_request(p), s)
    transition!(s, :local_infile, LOCAL_INFILE)
    return req
end

# Every response unit of a command (an OK or a result-set header) counts toward max_result_sets.
function next_result_set!(s::Session)
    s.result_sets += 1
    s.result_sets <= s.limits.max_result_sets || throw(fault!(s, ProtocolError("command produced more than $(s.limits.max_result_sets) result sets")))
    return nothing
end

function read_result_header!(s::Session, p::PacketView, binary::Bool)
    cc = PacketCursor(p)
    ncols_wire = guarded(() -> read_lenenc!(cc), s)
    atend(cc) || throw(fault!(s, ProtocolError("malformed column count packet: $(remaining(cc)) trailing bytes")))
    0 < ncols_wire <= UInt64(s.limits.max_columns) || throw(fault!(s, ProtocolError("column count $ncols_wire is outside 1:$(s.limits.max_columns)")))
    ncols = Int(ncols_wire)
    transition!(s, :column_count, COLUMN_DEFS)
    columns = Vector{ColumnDef}(undef, ncols)
    metadata_start = s.metadata_bytes
    for i in 1:ncols
        cp = readpacket!(s; packet_limit=s.limits.max_metadata_bytes - s.metadata_bytes)
        s.metadata_bytes += payload_length(cp)
        s.metadata_bytes <= s.limits.max_metadata_bytes || throw(fault!(s, ProtocolError("column metadata exceeded $(s.limits.max_metadata_bytes) bytes")))
        columns[i] = guarded(() -> parse_column_def(cp), s)
        transition!(s, :column_def, COLUMN_DEFS)
    end
    if deprecate_eof(s)
        transition!(s, :metadata_complete, ROWS)
    else
        ep = readpacket!(s)
        is_eof_packet(ep) || throw(fault!(s, ProtocolError("expected EOF after column definitions")))
        s.status = guarded(() -> parse_eof(ep, s.capabilities), s).status
        transition!(s, :metadata_eof, ROWS)
    end
    return ResultHeader(columns, binary, s.metadata_bytes - metadata_start)
end

"""
    read_row!(s; binary=false, dest=s.io.inbuf) -> PacketView | ResultEnd

Reads the next row packet (returned as a view over `dest`, valid until the next read into
that buffer) or the result-set terminator. A server ERR in row state ends the result set and
returns the session to READY. It is thrown as `StmtError` for a binary prepared response and
as `Error` for a text response.
"""
function read_row!(s::Session; binary::Bool=s.command_kind == CMD_STMT_EXECUTE, dest::Vector{UInt8}=s.io.inbuf)
    require_phase(s, ROWS)
    p = readpacket!(s; dest=dest)
    what = guarded(() -> classify_row(p, binary), s)
    if what == :row
        transition!(s, :row, ROWS)
        return p
    elseif what == :err
        e = guarded(() -> parse_err(p, s.capabilities), s)
        transition!(s, :err, READY)
        throw(binary ? StmtError(e) : Error(e))
    end
    return finish_result!(s, p)
end

function finish_result!(s::Session, p::PacketView)
    if deprecate_eof(s)
        ok = guarded(() -> parse_ok(p, s.capabilities, s.limits), s)
        status, warnings, oksnap = ok.status, ok.warnings, ok
    else
        is_eof_packet(p) || throw(fault!(s, ProtocolError("expected EOF terminator, got a $(payload_length(p))-byte 0xFE packet")))
        eof = guarded(() -> parse_eof(p, s.capabilities), s)
        status, warnings, oksnap = eof.status, eof.warnings, nothing
    end
    s.status = status
    more = more_results(status)
    transition!(s, more ? :terminator_more : :terminator, more ? RESULT_END : READY)
    return ResultEnd(status, warnings, oksnap, more)
end

"""
    next_result!(s; kind=CMD_QUERY) -> OKPacket | ResultHeader | LocalInfileRequest

Advances from RESULT_END to the next result of a multi-result response (the sequence counter
continues; nothing is sent).
"""
function next_result!(s::Session; kind::CommandKind=s.command_kind)
    require_phase(s, RESULT_END)
    s.result_sets < s.limits.max_result_sets || throw(fault!(s, ProtocolError("command produced more than $(s.limits.max_result_sets) result sets")))
    transition!(s, :next_result, CMD_SENT)
    return read_command_response!(s; kind=kind)
end

"""
    drain!(s)

Reads and discards everything the server still has to say about the current command (rows,
terminators, further result sets) until the session is READY. Server errors are swallowed;
protocol faults propagate.
"""
function drain!(s::Session)
    while !is_terminal(s.phase) && s.phase != READY
        try
            drain_step!(s)
        catch err
            err isa ServerError || rethrow()
        end
    end
    return nothing
end

function drain_step!(s::Session)
    if s.phase == CMD_SENT
        read_command_response!(s)
    elseif s.phase == ROWS
        read_row!(s)
    elseif s.phase == RESULT_END
        next_result!(s)
    elseif s.phase == LOCAL_INFILE
        send_local_infile!(s, nothing)
    else
        wrong_phase(s, "a command-response phase")
    end
    return nothing
end

"""
    send_local_infile!(s, source::Union{Nothing, IO}; max_bytes=nothing)

Streams `source` as LOCAL INFILE data packets followed by the empty terminator packet
(LOCAL_INFILE → CMD_SENT); `nothing` sends only the terminator (a refusal at the framing
level — the connection layer turns it into `LocalInfileRefused`). Returns the number of
bytes sent. Any failure after the first data packet faults the session.
"""
function send_local_infile!(s::Session, source::Union{Nothing, IO}; max_bytes::Union{Nothing, Integer}=nothing, chunk_size::Integer=min(MAX_CHUNK - 1, s.limits.max_packet))
    require_phase(s, LOCAL_INFILE)
    1 <= chunk_size <= min(MAX_CHUNK - 1, s.limits.max_packet) || throw(ArgumentError("LOCAL INFILE chunk_size must be in 1:$(min(MAX_CHUNK - 1, s.limits.max_packet))"))
    max_bytes === nothing || max_bytes >= 0 || throw(ArgumentError("LOCAL INFILE max_bytes must be nonnegative or nothing"))
    sent = 0
    if source !== nothing
        chunk = Vector{UInt8}(undef, chunk_size)
        try
            while !eof(source)
                n = readbytes!(source, chunk, chunk_size)
                n == 0 && break
                if max_bytes !== nothing && !(sent <= max_bytes && n <= max_bytes - sent)
                    err = ProtocolError("LOCAL INFILE upload exceeded $max_bytes bytes")
                    sent == 0 ? throw(err) : throw(fault!(s, err))
                end
                sendpacket!(s, view(chunk, 1:n))
                sent += n
            end
        catch err
            sent == 0 && rethrow()
            throw(fault!(s, err))
        end
    end
    sendpacket!(s, UInt8[])
    s.command_kind = CMD_LOCAL_INFILE
    transition!(s, :upload_done, CMD_SENT)
    return sent
end
