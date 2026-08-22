# Text-protocol cursors: forward-only rows over cursor-owned buffers, the preserved
# "row valid only while current" contract (`wrongrow`), buffered and streaming modes, the
# multi-result contract (one distinct cursor per result), and the LOCAL INFILE state table.

"""
    MySQL.Native.TextCursor{buffered}

The cursor returned by `DBInterface.execute(conn, sql)`. Iterates `TextRow`s and satisfies
the Tables.jl row interface. `buffered=true` (`mysql_store_result=true`, the default) reads
the whole result set at execute time under `max_buffered_bytes`; `buffered=false` streams
rows from the server on each `iterate` and ties up the connection until exhausted.
A row is valid only while it is the cursor's current row.
"""
mutable struct TextCursor{buffered} <: DBInterface.Cursor
    conn::Connection
    sql::String
    token::Int
    generation::Int
    names::Vector{Symbol}
    types::Vector{Type}
    lookup::Dict{Symbol, Int}
    nfields::Int
    nrows::Int
    rows_affected::Int64
    ok::Union{Nothing, P.OKPacket}
    status::UInt16
    warnings::UInt16
    buf::Vector{UInt8}
    spare::Vector{UInt8}
    rowstarts::Vector{Int}
    offsets::Vector{Int}
    lengths::Vector{Int}
    @atomic epoch::Int
    current_rownumber::Int
    current_resultsetnumber::Int
    finished::Bool
    closed::Bool
    opts::ResultOptions
end

struct TextRow{buffered} <: Tables.AbstractRow
    cursor::TextCursor{buffered}
    rownumber::Int
    epoch::Int
end

getcursor(r::TextRow) = getfield(r, :cursor)
getrownumber(r::TextRow) = getfield(r, :rownumber)
getepoch(r::TextRow) = getfield(r, :epoch)

@noinline wrongrow(i) = throw(ArgumentError("row $i is no longer valid; mysql results are forward-only iterators where each row is only valid when iterated"))
@noinline cursor_invalidated() = throw(P.ProtocolError("cursor invalidated: another command ran on the connection, or it was reconnected or closed"))

# A streaming cursor that has not reached its terminator must still own the connection's
# in-flight response and belong to the current session generation.
function check_active(c::TextCursor{false})
    conn = c.conn
    c.generation == (@atomic conn.generation) || cursor_invalidated()
    c.token == (@atomic conn.active_token) || cursor_invalidated()
    return nothing
end

# Buffered cursors own their bytes: they stay readable after later commands.
check_active(::TextCursor{true}) = nothing

# ---- Tables.jl row interface ----

Tables.columnnames(r::TextRow) = getcursor(r).names

function Tables.getcolumn(r::TextRow, ::Type{T}, i::Int, nm::Symbol) where {T}
    c = getcursor(r)
    getepoch(r) == (@atomic c.epoch) || wrongrow(getrownumber(r))
    check_active(c)
    return decode(T, c.buf, c.offsets[i], c.lengths[i], c.opts)
end

Tables.getcolumn(r::TextRow, i::Int) = Tables.getcolumn(r, getcursor(r).types[i], i, getcursor(r).names[i])
Tables.getcolumn(r::TextRow, nm::Symbol) = Tables.getcolumn(r, getcursor(r).lookup[nm])

Tables.isrowtable(::Type{<:TextCursor}) = true
Tables.schema(c::TextCursor) = Tables.Schema(c.names, c.types)

Base.eltype(::TextCursor) = TextRow
Base.IteratorSize(::Type{TextCursor{true}}) = Base.HasLength()
Base.IteratorSize(::Type{TextCursor{false}}) = Base.SizeUnknown()
Base.length(c::TextCursor) = c.nrows

# ---- construction from a command response ----

function empty_cursor(conn::Connection, sql::String, token::Int, ok::P.OKPacket, buffered::Bool, opts::ResultOptions, number::Int)
    c = TextCursor{buffered}(conn, sql, token, @atomic(conn.generation), Symbol[], Type[], Dict{Symbol, Int}(), 0, 0, Core.bitcast(Int64, ok.affected_rows), ok, ok.status, ok.warnings, UInt8[], UInt8[], Int[], Int[], Int[], 0, 0, number, true, false, opts)
    P.more_results(ok) || release_token!(c)
    return c
end

function result_cursor(conn::Connection, sql::String, token::Int, header::P.ResultHeader, buffered::Bool, opts::ResultOptions, number::Int)
    n = length(header.columns)
    s = session(conn)
    buffered && charge_buffered!(conn, s, header.metadata_bytes + (2 * n + 1) * sizeof(Int))
    names = [Symbol(col.name) for col in header.columns]
    types = Type[juliatype(col, opts) for col in header.columns]
    lookup = Dict{Symbol, Int}(nm => i for (i, nm) in enumerate(names))
    c = TextCursor{buffered}(conn, sql, token, @atomic(conn.generation), names, types, lookup, n, buffered ? 0 : -1, Int64(0), nothing, UInt16(0), UInt16(0), UInt8[], UInt8[], Int[], Vector{Int}(undef, n), Vector{Int}(undef, n), 0, 0, number, false, false, opts)
    buffered && buffer_rows!(c, s)
    return c
end

function make_cursor(conn::Connection, sql::String, token::Int, resp, buffered::Bool, opts::ResultOptions, number::Int)
    resp isa P.OKPacket && return empty_cursor(conn, sql, token, resp, buffered, opts, number)
    return result_cursor(conn, sql, token, resp::P.ResultHeader, buffered, opts, number)
end

# The terminator of this cursor's result set. Buffered cursors can release response
# ownership immediately. A streaming cursor retains its token so that its last row can
# distinguish a later foreign command from an ordinary stale-row error.
function finish!(c::TextCursor{buffered}, r::P.ResultEnd) where {buffered}
    c.status = r.status
    c.warnings = r.warnings
    c.ok = r.ok
    c.finished = true
    (!r.more_results && buffered) && release_token!(c)
    return nothing
end

function release_token!(c::TextCursor)
    conn = c.conn
    (@atomic conn.active_token) == c.token && (@atomic conn.active_token = 0)
    return nothing
end

@noinline buffered_limit_exceeded(limit) = P.ProtocolError("buffered result exceeded max_buffered_bytes=$limit bytes; use mysql_store_result=false or raise max_buffered_bytes")

function charge_buffered!(conn::Connection, s::P.Session, n::Int)
    current = conn.buffered_bytes
    limit = s.limits.max_buffered_bytes
    (n <= typemax(Int) - current && (limit === nothing || current + n <= limit)) || throw(P.fault!(s, buffered_limit_exceeded(limit)))
    conn.buffered_bytes = current + n
    return nothing
end

# Reads every row of the result into the cursor's contiguous buffer, charging the
# connection's per-command budget (earlier results of the same command count too).
function buffer_rows!(c::TextCursor{true}, s::P.Session)
    conn = c.conn
    try
        while true
            r = P.read_row!(s)
            if r isa P.ResultEnd
                finish!(c, r)
                break
            end
            P.guarded(() -> P.scan_text_row!(r, c.nfields, c.offsets, c.lengths), s)
            n = P.payload_length(r)
            charge_buffered!(conn, s, n + sizeof(Int))
            push!(c.rowstarts, length(c.buf) + 1)
            append!(c.buf, view(r.buf, r.lo:r.hi))
            c.nrows += 1
        end
    catch
        c.finished = true
        rethrow()
    end
    push!(c.rowstarts, length(c.buf) + 1)
    return nothing
end

# Consumes the rest of a streaming result (the connection needs it for the next result or
# command); the rows handed out so far become stale.
function drain_rows!(c::TextCursor{false}, s::P.Session)
    try
        while !c.finished
            r = P.read_row!(s; dest=c.spare)
            r isa P.ResultEnd && finish!(c, r)
        end
    catch
        c.finished = true
        rethrow()
    end
    return nothing
end

# ---- iteration ----

function scan_current!(c::TextCursor, p::P.PacketView, i::Int, s::Union{Nothing, P.Session}=nothing)
    if s === nothing
        P.scan_text_row!(p, c.nfields, c.offsets, c.lengths)
    else
        P.guarded(() -> P.scan_text_row!(p, c.nfields, c.offsets, c.lengths), s)
    end
    c.current_rownumber = i
    return nothing
end

function Base.iterate(c::TextCursor{true}, i::Int=1)
    c.closed && return nothing
    i > c.nrows && return nothing
    lo = c.rowstarts[i]
    hi = c.rowstarts[i + 1] - 1
    @atomic c.epoch += 1
    scan_current!(c, P.PacketView(c.buf, lo, hi, 0x00, 1, hi - lo + 1), i)
    return (TextRow{true}(c, i, @atomic(c.epoch)), i + 1)
end

function Base.iterate(c::TextCursor{false}, i::Int=1)
    conn = c.conn
    lock(conn.lock) do
        (c.closed || c.finished) && return nothing
        check_active(c)
        s = session(conn)
        r = try
            P.read_row!(s; dest=c.spare)
        catch
            c.finished = true
            rethrow()
        end
        if r isa P.ResultEnd
            finish!(c, r)
            return nothing
        end
        # Stale the old row before replacing any state that it can observe. If scanning the
        # new row fails, the old row must not decode with partially replaced offsets.
        @atomic c.epoch += 1
        c.buf, c.spare = c.spare, c.buf
        try
            scan_current!(c, r, i, s)
        catch
            c.finished = true
            rethrow()
        end
        return (TextRow{false}(c, i, @atomic(c.epoch)), i + 1)
    end
end

"""
    DBInterface.lastrowid(c::MySQL.Native.TextCursor)

The `last_insert_id` the server reported in this cursor's own OK packet (the DML result, or
the result-set terminator), not the connection's current state.
"""
DBInterface.lastrowid(c::TextCursor) = c.ok === nothing ? UInt64(0) : c.ok.last_insert_id

"""
    DBInterface.close!(c::MySQL.Native.TextCursor)

Discards whatever the server still has to send for the command that produced `c` (remaining
rows and result sets). The cursor's retained buffered rows stay readable; a streaming cursor
yields no more rows.
"""
function DBInterface.close!(c::TextCursor)
    conn = c.conn
    lock(conn.lock) do
        c.closed && return nothing
        @atomic c.epoch += 1
        c.closed = true
        c.finished = true
        conn.handle === nothing && return nothing
        (c.generation == (@atomic conn.generation) && c.token == (@atomic conn.active_token)) || return nothing
        drain_pending!(conn)
        return nothing
    end
    return nothing
end

# ---- execute ----

# LOCAL INFILE state table (docs/protocol-notes.md, plan §5.6).
function resync_local_infile!(s::P.Session)
    P.send_local_infile!(s, nothing)
    try
        return P.read_command_response!(s)
    catch server_err
        server_err isa P.ServerError || rethrow()
        return server_err
    end
end

function handle_local_infile!(conn::Connection, s::P.Session, req::P.LocalInfileRequest)
    handler = conn.options.local_infile_handler
    handler === nothing && throw(P.fault!(s, P.ProtocolError("the server requested a LOCAL INFILE upload but no local_infile_handler is configured")))
    filename = req.filename isa AbstractString ? String(req.filename) : String(copy(req.filename))
    source = try
        handler(filename)
    catch
        # nothing sent yet: resynchronize with the empty packet, then raise the handler error
        reply = resync_local_infile!(s)
        reply isa P.ServerError && @debug "LOCAL INFILE refused after a handler error" filename=filename server=reply
        rethrow()
    end
    if source === nothing
        reply = resync_local_infile!(s)
        detail = if reply isa P.ServerError
            "the server replied: $(sprint(showerror, reply))"
        else
            "the server accepted the empty upload"
        end
        cause = reply isa P.ServerError ? reply : nothing
        throw(P.LocalInfileRefused(filename, "the LOCAL INFILE upload of \"$filename\" was refused by local_infile_handler; $detail", cause))
    end
    if !(source isa IO)
        err = ArgumentError("local_infile_handler must return an IO or nothing, got $(typeof(source))")
        resync_local_infile!(s)
        throw(err)
    end
    try
        P.send_local_infile!(s, source; max_bytes=conn.options.max_local_infile_bytes)
    catch err
        if !P.is_terminal(s.phase)
            resync_local_infile!(s)
        end
        rethrow()
    end
    return P.read_command_response!(s)
end

function read_response!(conn::Connection, s::P.Session)
    resp = P.read_command_response!(s)
    while resp isa P.LocalInfileRequest
        resp = handle_local_infile!(conn, s, resp)
    end
    return resp
end

"""
    DBInterface.execute(conn::MySQL.Native.Connection, sql; mysql_store_result=true, mysql_date_and_time=false) -> TextCursor

Runs `sql` with the text protocol and returns a cursor over the first result. With
`mysql_store_result=false` rows are streamed (the connection is busy until the cursor is
exhausted or closed). Further results of a multi-statement or CALL response are discarded by
the next operation; use `DBInterface.executemultiple` to consume them. Parameters require
prepared statements, which the native backend does not provide yet.
"""
function DBInterface.execute(conn::Connection, sql::AbstractString, params=(); mysql_store_result::Bool=true, mysql_date_and_time::Bool=false)
    params == () || throw(MySQLInterfaceError("parameter binding requires prepared statements, which the native backend does not provide yet"))
    opts = ResultOptions(; date_and_time=mysql_date_and_time, zero_dates=conn.results.zero_dates, time_type=conn.results.time_type)
    lock(conn.lock) do
        s = begin_command!(conn)
        token = new_token!(conn)
        P.query!(s, sql)
        resp = read_response!(conn, s)
        return make_cursor(conn, String(sql), token, resp, mysql_store_result, opts, 1)
    end
end

# ---- multiple results ----

"""
    DBInterface.executemultiple(conn::MySQL.Native.Connection, sql; kw...) -> TextCursors

Iterates every result of a multi-statement (needs `multi_statements=true`) or CALL response
as a **distinct** cursor with its own metadata and OK snapshot; DML results and the final OK
of a CALL yield empty cursors. Advancing past an unconsumed streaming result drains it and
invalidates its rows; a later server error ends the iteration with `MySQL.Protocol.Error`.
"""
mutable struct TextCursors{buffered}
    conn::Connection
    sql::String
    opts::ResultOptions
    current::TextCursor{buffered}
end

Base.eltype(::TextCursors{buffered}) where {buffered} = TextCursor{buffered}
Base.IteratorSize(::Type{<:TextCursors}) = Base.SizeUnknown()

function DBInterface.executemultiple(conn::Connection, sql::AbstractString, params=(); mysql_store_result::Bool=true, mysql_date_and_time::Bool=false)
    first = DBInterface.execute(conn, sql, params; mysql_store_result=mysql_store_result, mysql_date_and_time=mysql_date_and_time)
    return TextCursors{mysql_store_result}(conn, String(sql), first.opts, first)
end

function Base.iterate(tc::TextCursors{buffered}, first::Bool=true) where {buffered}
    first && return (tc.current, false)
    conn = tc.conn
    lock(conn.lock) do
        cur = tc.current
        conn.handle === nothing && return nothing
        cur.generation == (@atomic conn.generation) || return nothing
        buffered || (@atomic cur.epoch += 1)  # advancing the outer iterator stales this result's row
        if !cur.finished
            # an unconsumed streaming result: it must still own the response, then it is drained
            cur.token == (@atomic conn.active_token) || cursor_invalidated()
            drain_rows!(cur, session(conn))
        end
        (P.more_results(cur.status) && cur.token == (@atomic conn.active_token)) || return nothing
        s = session(conn)
        s.phase == P.RESULT_END || return nothing
        resp = P.next_result!(s)
        while resp isa P.LocalInfileRequest
            resp = handle_local_infile!(conn, s, resp)
        end
        tc.current = make_cursor(conn, tc.sql, new_token!(conn), resp, buffered, tc.opts, cur.current_resultsetnumber + 1)
        return (tc.current, false)
    end
end
