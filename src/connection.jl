# The DBInterface connection of the native backend: lock-serialized use of one
# `Protocol.Session`, pending-response draining, cursor invalidation tokens, the narrow
# reconnect rule, transactions that hold the lock, and `escape`.

# A closed statement's COM_STMT_CLOSE, parked until the next command (never sent from a
# finalizer); allocated with its Statement so parking never allocates.
mutable struct StatementReapEntry
    statement_id::UInt32
    generation::Int
    next::Union{Nothing, StatementReapEntry}
    parked::Bool
end

"""
    MySQL.Connection

A MySQL connection. Obtain one with
`DBInterface.connect(MySQL.Connection, host, user, password; kw...)`; see
`MySQL.ConnectOptions` for the accepted keywords (removed 1.x ones explain why they fail).
Operations are serialized by the connection lock; a streaming cursor and a transaction are
owned by the task that created them.
"""
mutable struct Connection <: DBInterface.Connection
    handle::Union{Nothing, Handle}
    options::ConnectOptions
    host::String
    user::String
    port::Int
    db::String
    lock::ReentrantLock
    @atomic generation::Int
    @atomic active_token::Int
    next_token::Int
    buffered_bytes::Int
    transaction_owner::Union{Nothing, Task}
    results::ResultOptions
    reaplock::ReentrantLock
    stmts_to_close::Union{Nothing, StatementReapEntry}
    @atomic statement_reaping_open::Bool
end

# A leading `mysql://` scheme prefix on the host is stripped (2.0 change: 1.x stripped up
# to a `mysql://` substring found *anywhere* in the host).
function strip_scheme(host::AbstractString)
    return startswith(host, "mysql://") ? String(SubString(host, ncodeunits("mysql://") + 1)) : String(host)
end

"""
    DBInterface.connect(MySQL.Connection, host, user, passwd=nothing; db=nothing, port=nothing, kw...)

Connects to a MySQL server. Keywords are the 1.x connection options plus
`ssl_mode=:preferred`, `get_server_public_key`, `tls_version`, `zero_dates`, `time_type`,
`local_infile_handler`, `max_buffered_bytes`, …; see `MySQL.ConnectOptions`. An omitted
`db`/`port` falls back to the option files' `database`/`port` (when option files are read),
like `host`/`user`/`password`.
"""
function DBInterface.connect(::Type{Connection}, host::AbstractString, user::AbstractString, passwd::Union{AbstractString, Nothing}=nothing; db::Union{AbstractString, Nothing}=nothing, port::Union{Integer, Nothing}=nothing, kw...)
    opts = ConnectOptions(strip_scheme(host), user, passwd; db=db, port=port, kw...)
    h = connect(opts)
    results = ResultOptions(; zero_dates=opts.zero_dates, time_type=opts.time_type)
    return Connection(
        h,
        opts,
        opts.host,
        opts.user,
        opts.port,
        opts.db,
        ReentrantLock(),
        1,
        0,
        0,
        0,
        nothing,
        results,
        ReentrantLock(),
        nothing,
        true,
    )
end

# Status queries (`show`, `isopen`) read the handle field without the connection lock: a
# transaction or a long command on another task must not block a REPL display.
function Base.show(io::IO, conn::Connection)
    opts = conn.handle === nothing ? "disconnected" : "host=\"$(conn.host)\", user=\"$(conn.user)\", port=$(conn.port), db=\"$(conn.db)\""
    print(io, "MySQL.Connection($opts)")
    return nothing
end

@noinline closed_connection() = return error("mysql connection has been closed or disconnected")

function checkconn(conn::Connection)
    conn.handle === nothing && closed_connection()
    return nothing
end

session(conn::Connection) = return (checkconn(conn); conn.handle.session)

"""
    Base.isopen(conn)

A local check (the transport is open and the session is not closed or broken); it does not
detect a peer that went away silently — use `MySQL.ping`.
"""
function Base.isopen(conn::Connection)
    h = conn.handle
    return h !== nothing && isopen(h)
end

"""
    DBInterface.close!(conn)

Sends COM_QUIT (best effort) and closes the transport. Idempotent; unfinished streaming
cursors become invalid. Buffered cursors retain their own bytes and remain readable.
"""
function DBInterface.close!(conn::Connection)
    lock(conn.lock) do
        h = conn.handle
        h === nothing && return nothing
        @atomic conn.statement_reaping_open = false
        discard_parked_statements!(conn)
        conn.handle = nothing
        invalidate_cursors!(conn)
        close!(h)
        return nothing
    end
    return nothing
end

Base.close(conn::Connection) = return DBInterface.close!(conn)

# ---- response ownership ----

function invalidate_cursors!(conn::Connection)
    @atomic conn.generation += 1
    @atomic conn.active_token = 0
    return nothing
end

function new_token!(conn::Connection)
    conn.next_token += 1
    @atomic conn.active_token = conn.next_token
    return conn.next_token
end

# Reads and discards whatever the server still has to say about the previous command, and
# withdraws ownership from the cursor that was consuming it.
function drain_pending!(conn::Connection)
    s = session(conn)
    @atomic conn.active_token = 0
    if !P.is_terminal(s.phase) && s.phase != P.READY
        P.drain!(s)
    end
    return nothing
end

# Reconnect only before a send, once the session is known dead (closed, or broken by a
# fault such as the server dropping an idle connection), and never inside a transaction:
# the command that hit the failure reports it, the next one reconnects — the libmysqlclient
# contract. Statements and cursors of the old session are invalidated by the generation
# bump. A failed reconnect keeps the (dead) handle so the next command reports the
# connection error again and retries, instead of reporting a closed connection.
function ensure_live!(conn::Connection)
    h = conn.handle
    isopen(h.session) && return nothing
    can_reconnect = conn.options.reconnect && conn.transaction_owner === nothing && !P.in_transaction(h.session.status)
    can_reconnect || throw(P.Error(P.CR_SERVER_GONE_ERROR, "MySQL server has gone away", "HY000"))
    close!(h)
    conn.handle = connect(conn.options)
    invalidate_cursors!(conn)
    return nothing
end

# Every command starts here (under the lock): live connection, no pending response, fresh
# per-command buffered budget. `read_timeout`/`write_timeout` need no work here: the
# session re-arms them before every transport read and write.
function begin_command!(conn::Connection)
    checkconn(conn)
    if isopen(conn.handle.session)
        drain_pending!(conn)
    else
        # A transport already known closed cannot be drained. Reconnect before any byte of
        # the new command is sent and invalidate the abandoned response with its session.
        ensure_live!(conn)
    end
    s = conn.handle.session
    reap_statements!(conn, s)
    conn.buffered_bytes = 0
    return s
end

# The entry is allocated with its Statement, not by its finalizer. Caller holds reaplock.
function enqueue_statement!(conn::Connection, entry::StatementReapEntry)
    (@atomic conn.statement_reaping_open) || return nothing
    entry.parked && return nothing
    entry.parked = true
    entry.next = conn.stmts_to_close
    conn.stmts_to_close = entry
    return nothing
end

function discard_parked_statements!(conn::Connection)
    entry = nothing
    lock(conn.reaplock)
    try
        entry = conn.stmts_to_close
        conn.stmts_to_close = nothing
    finally
        unlock(conn.reaplock)
    end
    while entry !== nothing
        next = entry.next
        entry.next = nothing
        entry = next
    end
    return nothing
end

# Explicit close can block. It must never discard a statement because a finalizer briefly
# owns the queue lock.
function park_statement!(conn::Connection, entry::StatementReapEntry)
    lock(conn.reaplock)
    try
        enqueue_statement!(conn, entry)
    finally
        unlock(conn.reaplock)
    end
    return nothing
end

# A finalizer may only trylock (never block or yield). The caller re-registers the finalizer
# when this returns false.
function try_park_statement!(conn::Connection, entry::StatementReapEntry)
    if trylock(conn.reaplock)
        try
            enqueue_statement!(conn, entry)
        finally
            unlock(conn.reaplock)
        end
        return true
    end
    return false
end

# Sends COM_STMT_CLOSE (no response) for every parked statement of the current generation.
# Called under the connection lock with the session READY (drain/reconnect already ran).
function reap_statements!(conn::Connection, s::P.Session)
    entry = nothing
    lock(conn.reaplock)
    try
        entry = conn.stmts_to_close
        conn.stmts_to_close = nothing
    finally
        unlock(conn.reaplock)
    end
    gen = @atomic conn.generation
    while entry !== nothing
        next = entry.next
        entry.next = nothing
        entry.generation == gen && P.stmt_close!(s, entry.statement_id)
        entry = next
    end
    return nothing
end

# Runs a statement that must answer with OK (no result set) and returns the OK packet.
function execute_ok!(conn::Connection, sql::AbstractString)
    s = begin_command!(conn)
    P.query!(s, sql)
    resp = P.read_command_response!(s)
    if !(resp isa P.OKPacket)
        P.drain!(s)
        throw(MySQLInterfaceError("expected `$sql` to return OK"))
    end
    P.drain!(s)
    return resp
end

"""
    MySQL.ping(conn) -> Bool

COM_PING round trip; throws when the connection is unusable.
"""
function ping(conn::Connection)
    lock(conn.lock) do
        s = begin_command!(conn)
        P.ping!(s)
        P.read_command_response!(s; kind=P.CMD_SIMPLE)
        return true
    end
end

"""
    MySQL.connection_id(conn) -> Int

The server-side id of this connection (what `CONNECTION_ID()` returns), e.g. to cancel a
long-running statement with `KILL QUERY <id>` from another connection.
"""
connection_id(conn::Connection) = return Int((session(conn).server::P.ServerInfo).connection_id)

"""
    MySQL.server_version(conn) -> VersionNumber

The server version announced in the greeting (a MariaDB `5.5.5-` prefix is stripped), for
gating on server features; `MySQL.server_kind(conn)` tells `:mysql` from `:mariadb`.
"""
server_version(conn::Connection) = return (session(conn).server::P.ServerInfo).version

"""
    MySQL.server_kind(conn) -> Symbol

`:mysql`, `:mariadb`, `:tidb`, or `:vitess`, detected from the greeting.
"""
server_kind(conn::Connection) = return (session(conn).server::P.ServerInfo).kind

# ---- transactions ----

"""
    DBInterface.transaction(f, conn)

Runs `f()` inside `START TRANSACTION` / `COMMIT` (or `ROLLBACK` when `f` throws) and returns
`f()`'s value. The connection lock is held for the whole callback: other tasks block until
the transaction ends, so `f` must not wait on tasks that need this connection.
"""
function DBInterface.transaction(f, conn::Connection)
    lock(conn.lock)
    owns_transaction = false
    try
        conn.transaction_owner === nothing || throw(MySQLInterfaceError("a transaction is already active on this connection"))
        execute_ok!(conn, "START TRANSACTION")
        conn.transaction_owner = current_task()
        owns_transaction = true
        try
            result = f()
            execute_ok!(conn, "COMMIT")
            return result
        catch
            try
                execute_ok!(conn, "ROLLBACK")
            catch
            end
            rethrow()
        end
    finally
        owns_transaction && (conn.transaction_owner = nothing)
        unlock(conn.lock)
    end
end

# ---- escaping ----

"""
    MySQL.escape(conn, str) -> String

Escapes `str` for use inside a single-quoted SQL literal on this connection's character set
(utf8mb4): `\\`, `'`, `"`, NUL, newline, carriage return and Control-Z are backslash-escaped;
under the session's `NO_BACKSLASH_ESCAPES` mode only `'` is doubled.
"""
function escape(conn::Connection, str::AbstractString)
    return lock(conn.lock) do
        s = session(conn)
        escape_literal(str, (s.status & P.SERVER_STATUS_NO_BACKSLASH_ESCAPES) != 0)
    end
end

function escape_literal(str::AbstractString, no_backslash_escapes::Bool)
    out = IOBuffer(; sizehint=ncodeunits(str) + 8)
    for b in codeunits(str)
        if no_backslash_escapes
            b == UInt8('\'') && write(out, UInt8('\''))
            write(out, b)
        elseif b == 0x00
            write(out, "\\0")
        elseif b == UInt8('\n')
            write(out, "\\n")
        elseif b == UInt8('\r')
            write(out, "\\r")
        elseif b == UInt8('\\') || b == UInt8('\'') || b == UInt8('"')
            write(out, UInt8('\\'))
            write(out, b)
        elseif b == 0x1A
            write(out, "\\Z")
        else
            write(out, b)
        end
    end
    return String(take!(out))
end

"""
    MySQL.escape_identifier(name) -> String

Backtick-quotes an identifier, doubling embedded backticks.
"""
escape_identifier(name::AbstractString) = return string('`', replace(String(name), "`" => "``"), '`')
