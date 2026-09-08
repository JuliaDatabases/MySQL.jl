# Result cursors: forward-only rows over cursor-owned buffers, the preserved "row valid only
# while current" contract (`wrongrow`), buffered and streaming modes, the multi-result
# contract (one distinct cursor per result), and the LOCAL INFILE state table. One
# implementation serves both wire protocols: `Cursor{binary, buffered}` differs only in how a
# row is scanned into per-column windows and how a value is decoded — `binary=false` is the
# text protocol (`DBInterface.execute(conn, sql)`), `binary=true` the binary protocol of a
# prepared statement (`DBInterface.execute(stmt, params)`).

"""
    MySQL.TextCursor{buffered}
    MySQL.BinaryCursor{buffered}

The cursor returned by `DBInterface.execute`: `TextCursor` for `execute(conn, sql)` (text
protocol), `BinaryCursor` for `execute(stmt, params)` (binary protocol). It iterates rows and
satisfies the Tables.jl row interface. `buffered=true` (`mysql_store_result=true`, the
default) reads the whole result set at execute time under `max_buffered_bytes`;
`buffered=false` streams rows on each `iterate` and ties up the connection until exhausted. A
row is valid only while it is the cursor's current row.
"""
mutable struct Cursor{binary, buffered} <: DBInterface.Cursor
    conn::Connection
    sql::String
    token::Int
    generation::Int
    owner::Union{Nothing, Task}
    names::Vector{Symbol}
    types::Vector{Type}
    lookup::Union{Nothing, Dict{Symbol, Int}}   # built on first name-based access
    coltypes::Vector{UInt8}
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
    scratch::P.PacketCursor
    @atomic epoch::Int
    current_rownumber::Int
    current_resultsetnumber::Int
    finished::Bool
    closed::Bool
    opts::ResultOptions
end

const TextCursor = Cursor{false}
const BinaryCursor = Cursor{true}

struct Row{binary, buffered} <: Tables.AbstractRow
    cursor::Cursor{binary, buffered}
    rownumber::Int
    epoch::Int
end

const TextRow = Row{false}
const BinaryRow = Row{true}

getcursor(r::Row) = return getfield(r, :cursor)
getrownumber(r::Row) = return getfield(r, :rownumber)
getepoch(r::Row) = return getfield(r, :epoch)

@noinline wrongrow(i) = return throw(ArgumentError("row $i is no longer valid; mysql results are forward-only iterators where each row is only valid when iterated"))
@noinline cursor_invalidated() = return throw(P.ProtocolError("cursor invalidated: another command ran on the connection, or it was reconnected or closed"))
@noinline wrong_streaming_task() = return throw(MySQLInterfaceError("a streaming cursor must be consumed by only one task"))

function claim_streaming_owner!(c::Cursor{B, false}) where {B}
    owner = c.owner
    owner === nothing && (c.owner = current_task())
    (owner === nothing || owner === current_task()) || wrong_streaming_task()
    return nothing
end

# A streaming cursor that has not reached its terminator must still own the connection's
# in-flight response and belong to the current session generation.
function check_active(c::Cursor{B, false}) where {B}
    conn = c.conn
    c.owner === current_task() || wrong_streaming_task()
    c.generation == (@atomic conn.generation) || cursor_invalidated()
    c.token == (@atomic conn.active_token) || cursor_invalidated()
    return nothing
end

# Buffered cursors own their bytes: they stay readable after later commands.
check_active(::Cursor{B, true}) where {B} = return nothing

# Scanning one row into per-column windows and decoding one value are the only two points
# where the two protocols differ. The cursor-owned scratch `PacketCursor` is rebound per
# row (a fresh one is a heap allocation, §8.9).
scan_row!(c::Cursor{false}, p::P.PacketView) = return P.scan_text_row!(P.reset!(c.scratch, p.buf, p.lo, p.hi), c.nfields, c.offsets, c.lengths)
scan_row!(c::Cursor{true}, p::P.PacketView) = return P.scan_binary_row!(P.reset!(c.scratch, p.buf, p.lo, p.hi), c.coltypes, c.offsets, c.lengths)

decode_column(c::Cursor{false}, ::Type{T}, i::Int) where {T} = return decode(T, c.buf, c.offsets[i], c.lengths[i], c.opts)
decode_column(c::Cursor{true}, ::Type{T}, i::Int) where {T} = return decode_binary(T, c.buf, c.offsets[i], c.lengths[i], c.opts)

# ---- Tables.jl row interface ----

Tables.columnnames(r::Row) = return getcursor(r).names

function Tables.getcolumn(r::Row, ::Type{T}, i::Int, nm::Symbol) where {T}
    c = getcursor(r)
    getepoch(r) == (@atomic c.epoch) || wrongrow(getrownumber(r))
    check_active(c)
    return decode_column(c, T, i)
end

Tables.getcolumn(r::Row, i::Int) = return Tables.getcolumn(r, getcursor(r).types[i], i, getcursor(r).names[i])
Tables.getcolumn(r::Row, nm::Symbol) = return Tables.getcolumn(r, col_index(getcursor(r), nm))

Tables.isrowtable(::Type{<:Cursor}) = return true
Tables.schema(c::Cursor) = return Tables.Schema(c.names, c.types)

Base.eltype(::Cursor{false}) = return TextRow
Base.eltype(::Cursor{true}) = return BinaryRow
Base.IteratorSize(::Type{Cursor{B, true}}) where {B} = return Base.HasLength()
Base.IteratorSize(::Type{Cursor{B, false}}) where {B} = return Base.SizeUnknown()
Base.length(c::Cursor) = return c.nrows

# ---- construction from a command response ----

# Shared by every result-less cursor (per §8.9 an `executemany` makes one per row) and as
# the never-scanned initial scratch of result cursors. Never mutated.
const EMPTY_NAMES = Symbol[]
const EMPTY_TYPES = Type[]
const EMPTY_COLTYPES = UInt8[]
const EMPTY_BYTES = UInt8[]
const EMPTY_INTS = Int[]

# The name → index Dict is built on first name-based access; positional and schema-typed
# access (the hot paths) never pay for it.
function col_index(c::Cursor, nm::Symbol)
    lk = c.lookup
    if lk === nothing
        lk = Dict{Symbol, Int}(n => i for (i, n) in enumerate(c.names))
        c.lookup = lk
    end
    return lk[nm]
end

function empty_cursor(conn::Connection, sql::String, token::Int, ok::P.OKPacket, ::Val{binary}, ::Val{buffered}, opts::ResultOptions, number::Int) where {binary, buffered}
    c = Cursor{binary, buffered}(conn, sql, token, @atomic(conn.generation), nothing, EMPTY_NAMES, EMPTY_TYPES, nothing, EMPTY_COLTYPES, 0, -1, Core.bitcast(Int64, ok.affected_rows), ok, ok.status, ok.warnings, EMPTY_BYTES, EMPTY_BYTES, EMPTY_INTS, EMPTY_INTS, EMPTY_INTS, P.PacketCursor(EMPTY_BYTES), 0, 0, number, true, false, opts)
    P.more_results(ok) || release_token!(c)
    return c
end

function result_cursor(conn::Connection, sql::String, token::Int, header::P.ResultHeader, ::Val{binary}, ::Val{buffered}, opts::ResultOptions, number::Int) where {binary, buffered}
    names = [Symbol(col.name) for col in header.columns]
    types = Type[juliatype(col, opts) for col in header.columns]
    coltypes = binary ? UInt8[col.type for col in header.columns] : EMPTY_COLTYPES
    return finish_result_cursor!(conn, sql, token, header, Val(binary), Val(buffered), opts, number, names, types, nothing, coltypes)
end

# Construction tail shared with the statement fast path, which passes the statement's
# cached schema containers. Shared containers are never mutated in place (a re-prepare or
# execute-time schema change *replaces* the statement's vectors), so aliasing is safe.
function finish_result_cursor!(conn::Connection, sql::String, token::Int, header::P.ResultHeader, ::Val{binary}, ::Val{buffered}, opts::ResultOptions, number::Int, names::Vector{Symbol}, types::Vector{Type}, lookup::Union{Nothing, Dict{Symbol, Int}}, coltypes::Vector{UInt8}) where {binary, buffered}
    n = length(header.columns)
    s = session(conn)
    if buffered
        charge_buffered!(conn, s, header.metadata_bytes + (2 * n + 1) * sizeof(Int))
        binary && charge_buffered!(conn, s, n * sizeof(UInt8))
    end
    c = Cursor{binary, buffered}(conn, sql, token, @atomic(conn.generation), nothing, names, types, lookup, coltypes, n, buffered ? 0 : -1, Int64(0), nothing, UInt16(0), UInt16(0), UInt8[], UInt8[], Int[], Vector{Int}(undef, n), Vector{Int}(undef, n), P.PacketCursor(EMPTY_BYTES), 0, 0, number, false, false, opts)
    buffered && buffer_rows!(c, s)
    return c
end

# `binary`/`buffered` travel as `Val`s so every cursor construction (and the row scan
# machinery behind it) is concretely typed — `--trim=safe` needs the resolution, and the
# runtime saves the abstract-cursor dispatch.
function make_cursor(conn::Connection, sql::String, token::Int, resp, ::Val{binary}, ::Val{buffered}, opts::ResultOptions, number::Int) where {binary, buffered}
    resp isa P.OKPacket && return empty_cursor(conn, sql, token, resp, Val(binary), Val(buffered), opts, number)
    return result_cursor(conn, sql, token, resp::P.ResultHeader, Val(binary), Val(buffered), opts, number)
end

# The terminator of this cursor's result set. Buffered cursors can release response
# ownership immediately. A streaming cursor retains its token so that its last row can
# distinguish a later foreign command from an ordinary stale-row error.
function finish!(c::Cursor{binary, buffered}, r::P.ResultEnd) where {binary, buffered}
    c.status = r.status
    c.warnings = r.warnings
    c.ok = r.ok
    c.finished = true
    (!r.more_results && buffered) && release_token!(c)
    return nothing
end

function release_token!(c::Cursor)
    conn = c.conn
    (@atomic conn.active_token) == c.token && (@atomic conn.active_token = 0)
    return nothing
end

@noinline buffered_limit_exceeded(limit) = return P.ProtocolError("buffered result exceeded max_buffered_bytes=$limit bytes; use mysql_store_result=false or raise max_buffered_bytes")

function charge_buffered!(conn::Connection, s::P.Session, n::Int)
    current = conn.buffered_bytes
    limit = s.limits.max_buffered_bytes
    (n <= typemax(Int) - current && (limit === nothing || current + n <= limit)) || throw(P.fault!(s, buffered_limit_exceeded(limit)))
    conn.buffered_bytes = current + n
    return nothing
end

# Reads every row of the result into the cursor's contiguous buffer, charging the
# connection's per-command budget (earlier results of the same command count too).
function buffer_rows!(c::Cursor{binary, true}, s::P.Session) where {binary}
    conn = c.conn
    try
        while true
            r = P.read_row!(s)
            if r isa P.ResultEnd
                finish!(c, r)
                break
            end
            scan_row_guarded!(c, r, s)
            n = P.payload_length(r)
            charge_buffered!(conn, s, n + sizeof(Int))
            old = length(c.buf)
            push!(c.rowstarts, old + 1)
            resize!(c.buf, old + n)
            copyto!(c.buf, old + 1, r.buf, r.lo, n)
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
function drain_rows!(c::Cursor{binary, false}, s::P.Session) where {binary}
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

# Per-row guard without a closure (the closure passed to `P.guarded` allocated on every
# streaming row; §8.9 requires allocations per row ≤ String/Vector columns + 1).
@inline function scan_row_guarded!(c::Cursor, p::P.PacketView, s::P.Session)
    try
        scan_row!(c, p)
    catch err
        throw(P.fault!(s, err))
    end
    return nothing
end

function scan_current!(c::Cursor, p::P.PacketView, i::Int, s::Union{Nothing, P.Session}=nothing)
    s === nothing ? scan_row!(c, p) : scan_row_guarded!(c, p, s)
    c.current_rownumber = i
    return nothing
end

function Base.iterate(c::Cursor{binary, true}, i::Int=1) where {binary}
    c.closed && return nothing
    i > c.nrows && return nothing
    lo = c.rowstarts[i]
    hi = c.rowstarts[i + 1] - 1
    @atomic c.epoch += 1
    scan_current!(c, P.PacketView(c.buf, lo, hi, 0x00, 1, hi - lo + 1), i)
    return (Row{binary, true}(c, i, @atomic(c.epoch)), i + 1)
end

# All streaming-row work, under the lock (explicit lock/unlock: a `lock(l) do` closure
# would allocate per row). Returns whether a new current row exists. Kept out of `iterate`
# so the thin wrapper inlines into user loops and the `Union{Nothing, Tuple}` iteration
# protocol return does not heap-allocate on every row (§8.9).
function stream_advance!(c::Cursor{binary, false}, i::Int) where {binary}
    conn = c.conn
    lock(conn.lock)
    try
        (c.closed || c.finished) && return false
        claim_streaming_owner!(c)
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
            return false
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
        return true
    finally
        unlock(conn.lock)
    end
end

@inline function Base.iterate(c::Cursor{binary, false}, i::Int=1) where {binary}
    stream_advance!(c, i) || return nothing
    return (Row{binary, false}(c, i, @atomic(c.epoch)), i + 1)
end

"""
    DBInterface.lastrowid(c::MySQL.Cursor)

The `last_insert_id` the server reported in this cursor's own OK packet (the DML result, or
the result-set terminator), not the connection's current state.
"""
DBInterface.lastrowid(c::Cursor) = return c.ok === nothing ? UInt64(0) : c.ok.last_insert_id

"""
    DBInterface.close!(c::MySQL.Cursor)

Closes `c` and invalidates its current row. Further iteration yields no rows, for both
buffered and streaming cursors. Repeated calls have no effect.

If `c` still owns a pending response, discards the remaining rows and result sets for its
command.
"""
function DBInterface.close!(c::Cursor)
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

function handle_local_infile!(conn::Connection, s::P.Session, req::P.LocalInfileRequest)
    return handle_local_infile!(conn.options.local_infile_handler, conn.options.max_local_infile_bytes, s, req)
end

function read_response!(conn::Connection, s::P.Session)
    resp = P.read_command_response!(s)
    while resp isa P.LocalInfileRequest
        resp = handle_local_infile!(conn, s, resp)
    end
    return resp
end

"""
    DBInterface.execute(conn::MySQL.Connection, sql; mysql_store_result=true, mysql_date_and_time=false) -> TextCursor

Runs `sql` with the text protocol and returns a cursor over the first result. With
`mysql_store_result=false` rows are streamed (the connection is busy until the cursor is
exhausted or closed). Further results of a multi-statement or CALL response are discarded by
the next operation; use `DBInterface.executemultiple` to consume them. Passing `params`
prepares, executes and returns a binary-protocol cursor bound to a one-shot statement.
"""
function DBInterface.execute(conn::Connection, sql::AbstractString, params=(); mysql_store_result::Bool=true, mysql_date_and_time::Bool=false)
    params === () || return execute_params(conn, sql, params; mysql_store_result=mysql_store_result, mysql_date_and_time=mysql_date_and_time)
    opts = mysql_date_and_time ? ResultOptions(; date_and_time=true, zero_dates=conn.results.zero_dates, time_type=conn.results.time_type) : conn.results
    lock(conn.lock) do
        s = begin_command!(conn)
        token = new_token!(conn)
        P.query!(s, sql)
        resp = read_response!(conn, s)
        return mysql_store_result ?
            make_cursor(conn, String(sql), token, resp, Val(false), Val(true), opts, 1) :
            make_cursor(conn, String(sql), token, resp, Val(false), Val(false), opts, 1)
    end
end

# ---- multiple results ----

"""
    DBInterface.executemultiple(conn::MySQL.Connection, sql; kw...) -> Cursors

Iterates every result of a multi-statement (needs `multi_statements=true`) or CALL response
as a **distinct** cursor with its own metadata and OK snapshot; DML results and the final OK
of a CALL yield empty cursors. Advancing past an unconsumed streaming result drains it and
invalidates its rows; a later server error ends the iteration with `MySQL.Protocol.Error` for
text commands or `MySQL.Protocol.StmtError` for prepared commands.
"""
mutable struct Cursors{binary, buffered}
    conn::Connection
    sql::String
    opts::ResultOptions
    current::Cursor{binary, buffered}
end

const TextCursors = Cursors{false}

Base.eltype(::Cursors{binary, buffered}) where {binary, buffered} = return Cursor{binary, buffered}
Base.IteratorSize(::Type{<:Cursors}) = return Base.SizeUnknown()

function DBInterface.executemultiple(conn::Connection, sql::AbstractString, params=(); mysql_store_result::Bool=true, mysql_date_and_time::Bool=false)
    first = DBInterface.execute(conn, sql, params; mysql_store_result=mysql_store_result, mysql_date_and_time=mysql_date_and_time)
    return Cursors(conn, String(sql), first.opts, first)
end

function Base.iterate(tc::Cursors{binary, buffered}, first::Bool=true) where {binary, buffered}
    first && return (tc.current, false)
    conn = tc.conn
    lock(conn.lock) do
        cur = tc.current
        conn.handle === nothing && return nothing
        cur.generation == (@atomic conn.generation) || return nothing
        if !buffered
            if cur.token == (@atomic conn.active_token)
                claim_streaming_owner!(cur)
                check_active(cur)
            end
            @atomic cur.epoch += 1  # advancing the outer iterator stales this result's row
        end
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
        tc.current = make_cursor(conn, tc.sql, new_token!(conn), resp, Val(binary), Val(buffered), tc.opts, cur.current_resultsetnumber + 1)
        return (tc.current, false)
    end
end
