# Generic response packets and the phase-aware first-byte classification.
#
# The same first byte means different things in different phases (0x00 is OK in a command
# response but a binary row header in row state; 0xFB is a LOCAL INFILE request in a COM_QUERY
# response but NULL inside a text row; 0xFE is an EOF/OK terminator only when the logical
# packet is shorter than 0xFFFFFF), so every classifier takes the phase explicitly.

struct SessionStateChange
    type::UInt8
    data::Vector{UInt8}
end

"""
    OKPacket

`is_eof` is true when the packet carried the `0xFE` header (an OK acting as the
DEPRECATE_EOF result-set terminator).
"""
struct OKPacket
    is_eof::Bool
    affected_rows::UInt64
    last_insert_id::UInt64
    status::UInt16
    warnings::UInt16
    info::String
    session_state::Vector{SessionStateChange}
end

struct EOFPacket
    warnings::UInt16
    status::UInt16
end

struct ERRPacket
    code::UInt16
    sqlstate::String
    msg::String
end

struct LocalInfileRequest
    filename::Vector{UInt8}
end

struct AuthSwitchRequest
    plugin::String
    data::Vector{UInt8}
end

struct AuthMoreData
    data::Vector{UInt8}
end

more_results(status::UInt16) = (status & SERVER_MORE_RESULTS_EXISTS) != 0
more_results(ok::OKPacket) = more_results(ok.status)
more_results(eof::EOFPacket) = more_results(eof.status)
in_transaction(status::UInt16) = (status & SERVER_STATUS_IN_TRANS) != 0

Error(e::ERRPacket) = Error(e.code, e.msg, e.sqlstate)
StmtError(e::ERRPacket) = StmtError(e.code, e.msg, e.sqlstate)

# ---- OK ----

"""
    parse_ok(p::PacketView, caps, limits) -> OKPacket

Layout depends on the negotiated capabilities: status/warnings need `CLIENT_PROTOCOL_41`,
the `info` field is length-encoded (and optional) under `CLIENT_SESSION_TRACK` and
`string<EOF>` otherwise; session-state blocks follow only when
`SERVER_SESSION_STATE_CHANGED` is set.
"""
function parse_ok(p::PacketView, caps::UInt64, limits::Limits)
    c = PacketCursor(p)
    header = read_u8!(c)
    (header == OK_HEADER || header == EOF_HEADER) || protocol_error("expected OK packet, got header 0x$(string(header, base=16, pad=2))")
    affected_rows = read_lenenc!(c)
    last_insert_id = read_lenenc!(c)
    status = 0x0000
    warnings = 0x0000
    if has_capability(caps, CLIENT_PROTOCOL_41)
        status = read_u16!(c)
        warnings = read_u16!(c)
    elseif has_capability(caps, CLIENT_TRANSACTIONS)
        status = read_u16!(c)
    end
    info = ""
    state = SessionStateChange[]
    if has_capability(caps, CLIENT_SESSION_TRACK)
        remaining(c) > 0 && (info = read_lenenc_string!(c, "info"))
        if (status & SERVER_SESSION_STATE_CHANGED) != 0
            remaining(c) > 0 || truncated("session state info")
            len = read_lenenc_length!(c, "session state info")
            check_limit("session state bytes", len, limits.max_session_state_bytes)
            parse_session_state!(state, PacketCursor(c.buf, c.pos, c.pos + len - 1))
            c.pos += len
        end
    else
        info = read_eof_string!(c)
    end
    atend(c) || protocol_error("malformed OK packet: $(remaining(c)) trailing bytes")
    return OKPacket(header == EOF_HEADER, affected_rows, last_insert_id, status, warnings, info, state)
end

function parse_session_state!(state::Vector{SessionStateChange}, c::PacketCursor)
    while remaining(c) > 0
        type = read_u8!(c)
        data = read_lenenc_bytes!(c, "session state block")
        validate_session_state(type, data)
        push!(state, SessionStateChange(type, data))
    end
    return nothing
end

function validate_one_session_value(type::UInt8, data::Vector{UInt8}, what::String)
    c = PacketCursor(data)
    read_lenenc_window!(c, what)
    atend(c) || protocol_error("malformed session-state block type $(Int(type)): $(remaining(c)) trailing bytes")
    return nothing
end

function validate_session_state(type::UInt8, data::Vector{UInt8})
    if type == SESSION_TRACK_SYSTEM_VARIABLES
        c = PacketCursor(data)
        while remaining(c) > 0
            read_lenenc_window!(c, "system variable name")
            read_lenenc_window!(c, "system variable value")
        end
    elseif type == SESSION_TRACK_GTIDS
        c = PacketCursor(data)
        read_lenenc!(c) # extensible encoding specification
        read_lenenc_window!(c, "GTID value")
        atend(c) || protocol_error("malformed GTID session-state block: $(remaining(c)) trailing bytes")
    elseif type == SESSION_TRACK_SCHEMA
        validate_one_session_value(type, data, "schema name")
    elseif type == SESSION_TRACK_STATE_CHANGE
        validate_one_session_value(type, data, "state-change value")
    elseif type == SESSION_TRACK_TRANSACTION_CHARACTERISTICS
        validate_one_session_value(type, data, "transaction characteristics")
    elseif type == SESSION_TRACK_TRANSACTION_STATE
        validate_one_session_value(type, data, "transaction state")
    end
    return nothing
end

"""
    system_variables(ok::OKPacket) -> Vector{Pair{String, String}}

Tracked `SESSION_TRACK_SYSTEM_VARIABLES` changes (MySQL sends one pair per block; MariaDB
may pack several pairs into one block).
"""
function system_variables(ok::OKPacket)
    vars = Pair{String, String}[]
    for block in ok.session_state
        block.type == SESSION_TRACK_SYSTEM_VARIABLES || continue
        c = PacketCursor(block.data)
        while remaining(c) > 0
            name = read_lenenc_string!(c, "system variable name")
            value = read_lenenc_string!(c, "system variable value")
            push!(vars, name => value)
        end
    end
    return vars
end

function schema_change(ok::OKPacket)
    for block in ok.session_state
        block.type == SESSION_TRACK_SCHEMA || continue
        return read_lenenc_string!(PacketCursor(block.data), "schema name")
    end
    return nothing
end

# ---- EOF / ERR ----

function validate_server_errno(code::UInt16)
    code == MARIADB_ER_PROGRESS && protocol_error("unexpected MariaDB progress packet (MARIADB_CLIENT_PROGRESS was not negotiated)")
    is_client_reserved_errno(code) && protocol_error("server ERR packet carries client-reserved error code $(Int(code))")
    return nothing
end

function parse_eof(p::PacketView, caps::UInt64)
    c = PacketCursor(p)
    read_u8!(c) == EOF_HEADER || protocol_error("expected EOF packet")
    if !has_capability(caps, CLIENT_PROTOCOL_41)
        atend(c) || protocol_error("malformed EOF packet: $(remaining(c)) trailing bytes")
        return EOFPacket(0x0000, 0x0000)
    end
    warnings = read_u16!(c)
    status = read_u16!(c)
    atend(c) || protocol_error("malformed EOF packet: $(remaining(c)) trailing bytes")
    return EOFPacket(warnings, status)
end

# EOF packets are at most 5 bytes (header + warnings + status); longer 0xFE packets are OK
# packets (DEPRECATE_EOF) or rows.
is_eof_packet(p::PacketView) = first_byte(p) == EOF_HEADER && payload_length(p) < 9

function parse_err(p::PacketView, caps::UInt64)
    c = PacketCursor(p)
    read_u8!(c) == ERR_HEADER || protocol_error("expected ERR packet")
    code = read_u16!(c)
    validate_server_errno(code)
    sqlstate = ""
    if has_capability(caps, CLIENT_PROTOCOL_41) && remaining(c) > 0 && peek_u8(c) == SQLSTATE_MARKER
        remaining(c) >= 1 + SQLSTATE_LENGTH || truncated("SQL state")
        skip!(c, 1, "SQL state marker")
        sqlstate = read_fixed_string!(c, SQLSTATE_LENGTH, "SQL state")
    end
    return ERRPacket(code, sqlstate, read_eof_string!(c))
end

# ---- auth & LOCAL INFILE ----

function parse_local_infile_request(p::PacketView)
    c = PacketCursor(p)
    read_u8!(c) == LOCAL_INFILE_HEADER || protocol_error("expected LOCAL INFILE request")
    return LocalInfileRequest(read_eof_bytes!(c))
end

function parse_auth_switch(p::PacketView)
    c = PacketCursor(p)
    read_u8!(c) == AUTH_SWITCH_HEADER || protocol_error("expected AuthSwitchRequest")
    plugin = read_nul_string!(c, "auth plugin name")
    return AuthSwitchRequest(plugin, read_eof_bytes!(c))
end

function parse_auth_more_data(p::PacketView)
    c = PacketCursor(p)
    read_u8!(c) == AUTH_MORE_DATA_HEADER || protocol_error("expected AuthMoreData")
    return AuthMoreData(read_eof_bytes!(c))
end

# ---- classification ----

@enum CommandKind begin
    CMD_SIMPLE        # COM_PING, COM_INIT_DB, COM_RESET_CONNECTION
    CMD_STMT_RESET    # COM_STMT_RESET: OK | statement ERR
    CMD_QUERY         # COM_QUERY: OK | ERR | LOCAL INFILE | text result set
    CMD_LOCAL_INFILE  # upload response: OK | ERR; restores CMD_QUERY before later results
    CMD_STMT_PREPARE  # COM_STMT_PREPARE: PREPARE_OK | ERR
    CMD_STMT_EXECUTE  # COM_STMT_EXECUTE: OK | ERR | binary result set
    CMD_SET_OPTION    # COM_SET_OPTION: MySQL OK | MariaDB EOF | ERR
end

@noinline function unexpected_packet(phase::Phase, p::PacketView)
    b = first_byte(p)
    desc = b === nothing ? "an empty packet" : "header byte 0x$(string(b, base=16, pad=2)) (length $(payload_length(p)))"
    return protocol_error("unexpected packet in phase $phase: $desc")
end

"""
    classify_greeting(p) -> :greeting | :initial_err
"""
function classify_greeting(p::PacketView)
    b = first_byte(p)
    b == HANDSHAKE_PROTOCOL_VERSION && return :greeting
    b == ERR_HEADER && return :initial_err
    return unexpected_packet(CONNECTING, p)
end

"""
    classify_auth(p, mariadb::Bool) -> :ok | :err | :auth_switch | :old_auth_switch | :auth_more | :auth_next_factor | :plugin_data

MySQL wraps plugin data in the `0x01` envelope and reserves `0x02` for multi-factor
requests; MariaDB sends plugin payloads unwrapped (an optional leading `0x01` must be
skipped), so for MariaDB every non-OK/ERR/switch packet is plugin data.
"""
function classify_auth(p::PacketView, mariadb::Bool)
    b = first_byte(p)
    b === nothing && return unexpected_packet(AUTH, p)
    b == OK_HEADER && return :ok
    b == ERR_HEADER && return :err
    b == AUTH_SWITCH_HEADER && return payload_length(p) == 1 ? :old_auth_switch : :auth_switch
    mariadb && return :plugin_data
    b == AUTH_MORE_DATA_HEADER && return :auth_more
    b == AUTH_NEXT_FACTOR_HEADER && return :auth_next_factor
    return unexpected_packet(AUTH, p)
end

"""
    classify_command_response(kind, p) -> :ok | :err | :local_infile | :column_count | :prepare_ok
"""
function classify_command_response(kind::CommandKind, p::PacketView)
    b = first_byte(p)
    b === nothing && return unexpected_packet(CMD_SENT, p)
    b == ERR_HEADER && return :err
    if kind == CMD_SIMPLE || kind == CMD_STMT_RESET || kind == CMD_LOCAL_INFILE
        b == OK_HEADER && return :ok
        return unexpected_packet(CMD_SENT, p)
    elseif kind == CMD_SET_OPTION
        b == OK_HEADER && return :ok
        if b == EOF_HEADER
            n = payload_length(p)
            (n == 1 || n == 5) && return :eof
            return :ok
        end
        return unexpected_packet(CMD_SENT, p)
    elseif kind == CMD_STMT_PREPARE
        b == OK_HEADER && return :prepare_ok
        return unexpected_packet(CMD_SENT, p)
    end
    b == OK_HEADER && return :ok
    b == LOCAL_INFILE_HEADER && kind == CMD_QUERY && return :local_infile
    b == NULL_VALUE && return unexpected_packet(CMD_SENT, p)
    b == EOF_HEADER && return unexpected_packet(CMD_SENT, p)
    return :column_count
end

# A 0xFE-headed packet is a terminator only when the logical packet is shorter than
# 0xFFFFFF: a text row whose first value is an 8-byte-lenenc string is ≥ 2^24 bytes and is
# therefore carried in a full-size first chunk.
is_row_terminator(p::PacketView) = first_byte(p) == EOF_HEADER && p.first_chunk_len < MAX_CHUNK

"""
    classify_row(p, binary::Bool) -> :row | :terminator | :err
"""
function classify_row(p::PacketView, binary::Bool)
    b = first_byte(p)
    b === nothing && return unexpected_packet(ROWS, p)
    b == ERR_HEADER && return :err
    is_row_terminator(p) && return :terminator
    binary || return :row
    b == OK_HEADER && return :row
    return unexpected_packet(ROWS, p)
end

"""
    scan_text_row!(p, offsets, lengths)

Splits a text row into per-column windows of the packet buffer: `offsets[i]`/`lengths[i]`
describe column `i`; NULL columns get `lengths[i] == -1`. Both vectors are resized to the
number of columns found and reused across rows.
"""
scan_text_row!(p::PacketView, ncols::Int, offsets::Vector{Int}, lengths::Vector{Int}) =
    scan_text_row!(PacketCursor(p), ncols, offsets, lengths)

function scan_text_row!(c::PacketCursor, ncols::Int, offsets::Vector{Int}, lengths::Vector{Int})
    resize!(offsets, ncols)
    resize!(lengths, ncols)
    for i in 1:ncols
        if peek_u8(c) == NULL_VALUE
            skip!(c, 1, "NULL marker")
            offsets[i] = c.pos
            lengths[i] = -1
        else
            lo, hi = read_lenenc_window!(c, "text row value")
            offsets[i] = lo
            lengths[i] = hi - lo + 1
        end
    end
    atend(c) || protocol_error("malformed text row: $(remaining(c)) trailing bytes after $ncols columns")
    return nothing
end

# Width of a fixed-size binary value; `nothing` for the length-encoded and self-describing
# (temporal) types, which are measured from the wire.
function fixed_binary_width(type::UInt8)
    (type == MYSQL_TYPE_TINY) && return 1
    (type == MYSQL_TYPE_SHORT || type == MYSQL_TYPE_YEAR) && return 2
    (type == MYSQL_TYPE_LONG || type == MYSQL_TYPE_INT24 || type == MYSQL_TYPE_FLOAT) && return 4
    (type == MYSQL_TYPE_LONGLONG || type == MYSQL_TYPE_DOUBLE) && return 8
    return nothing
end

is_binary_temporal(type::UInt8) = type == MYSQL_TYPE_DATE || type == MYSQL_TYPE_DATETIME ||
    type == MYSQL_TYPE_TIMESTAMP || type == MYSQL_TYPE_TIME

function is_binary_lenenc(type::UInt8)
    (type == MYSQL_TYPE_STRING || type == MYSQL_TYPE_VARCHAR || type == MYSQL_TYPE_VAR_STRING) && return true
    (type == MYSQL_TYPE_ENUM || type == MYSQL_TYPE_SET || type == MYSQL_TYPE_GEOMETRY) && return true
    (type == MYSQL_TYPE_TINY_BLOB || type == MYSQL_TYPE_MEDIUM_BLOB || type == MYSQL_TYPE_LONG_BLOB || type == MYSQL_TYPE_BLOB) && return true
    return type == MYSQL_TYPE_BIT || type == MYSQL_TYPE_DECIMAL || type == MYSQL_TYPE_NEWDECIMAL ||
        type == MYSQL_TYPE_NEWDATE || type == MYSQL_TYPE_JSON
end

function valid_binary_temporal_length(type::UInt8, len::Int)
    type == MYSQL_TYPE_TIME && return len == 0 || len == 8 || len == 12
    return len == 0 || len == 4 || len == 7 || len == 11
end

# Advances `c` past one binary value of wire `type` and returns the (offset, length) window
# of its *content* bytes: the fixed-width little-endian bytes for numbers, the raw bytes of a
# `string<lenenc>` for everything else, and — for the temporal types — the bytes that follow
# the one-byte length prefix (so `length ∈ {0,4,7,11}` for date/datetime, `{0,8,12}` for time
# and the driver re-reads the same length from the window).
function binary_value_span!(c::PacketCursor, type::UInt8)
    w = fixed_binary_width(type)
    if w !== nothing
        need!(c, w, "binary value")
        off = c.pos
        c.pos += w
        return (off, w)
    end
    if is_binary_temporal(type)
        len = Int(read_u8!(c))
        valid_binary_temporal_length(type, len) || protocol_error("malformed binary temporal value: type $(field_type_name(type)) has invalid length $len")
        off = c.pos
        need!(c, len, "binary temporal value")
        c.pos += len
        return (off, len)
    end
    is_binary_lenenc(type) || protocol_error("unsupported binary protocol column type $(field_type_name(type))")
    return read_lenenc_window_len!(c, "binary value")
end

# Like `read_lenenc_window!` but returns (offset, length) instead of (lo, hi).
function read_lenenc_window_len!(c::PacketCursor, what::String)
    len = read_lenenc_length!(c, what)
    off = c.pos
    c.pos += len
    return (off, len)
end

"""
    scan_binary_row!(coltypes, p, offsets, lengths)

Splits a binary protocol resultset row into per-column content windows of the packet buffer,
just like `scan_text_row!` does for text rows: `offsets[i]`/`lengths[i]` describe column `i`,
`lengths[i] == -1` marks a NULL (its bit is set in the row's NULL bitmap, which uses bit
offset 2). `coltypes` supplies each column's wire type so the self-describing temporal and
fixed-width values can be measured. Both vectors are resized to the column count and reused.
"""
scan_binary_row!(coltypes::Vector{UInt8}, p::PacketView, offsets::Vector{Int}, lengths::Vector{Int}) =
    scan_binary_row!(PacketCursor(p), coltypes, offsets, lengths)

function scan_binary_row!(c::PacketCursor, coltypes::Vector{UInt8}, offsets::Vector{Int}, lengths::Vector{Int})
    ncols = length(coltypes)
    resize!(offsets, ncols)
    resize!(lengths, ncols)
    read_u8!(c) == OK_HEADER || protocol_error("malformed binary row: header byte is not 0x00")
    nullbytes = (ncols + 7 + 2) >> 3
    need!(c, nullbytes, "binary row NULL bitmap")
    nullmap_pos = c.pos
    c.pos += nullbytes
    buf = c.buf
    for i in 1:ncols
        bit = i - 1 + 2
        isnull = (@inbounds buf[nullmap_pos + (bit >> 3)] >> (bit & 7)) & 0x01 != 0
        if isnull
            offsets[i] = c.pos
            lengths[i] = -1
        else
            off, len = binary_value_span!(c, coltypes[i])
            offsets[i] = off
            lengths[i] = len
        end
    end
    atend(c) || protocol_error("malformed binary row: $(remaining(c)) trailing bytes after $ncols columns")
    return nothing
end
