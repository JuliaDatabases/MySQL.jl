"""
    MySQL.ConnectionPool(host, user, password=nothing; limit=10, connection_options...)

A pool of at most `limit` connections, created lazily. Connection options are resolved
once, as for `DBInterface.connect`. Borrow a connection with [`MySQL.with_connection`](@ref)
and close the pool with `close(pool)`.

Before reuse, each session is reset, its configured database and utf8mb4 settings are
restored, and `init_command` is run again. Use `init_command` only for repeatable session
setup, not one-time writes. Cleanup adds network round trips and uses the configured
read/write timeouts. With no configured database, cleanup also checks `DATABASE()` and
replaces a session that selected a database, since reset cannot clear that selection.
"""
mutable struct ConnectionPool
    options::ConnectOptions
    condition::Threads.Condition
    idle::Vector{Connection}
    total::Int
    limit::Int
    open::Bool
end

function ConnectionPool(host::AbstractString, user::AbstractString, password::Union{Nothing, AbstractString}=nothing; limit::Int=10, kw...)
    limit > 0 || throw(ArgumentError("connection pool limit must be positive"))
    opts = ConnectOptions(strip_scheme(host), user, password; kw...)
    return ConnectionPool(opts, Threads.Condition(), Connection[], 0, limit, true)
end

Base.isopen(pool::ConnectionPool) = lock(() -> pool.open, pool.condition)

function Base.show(io::IO, pool::ConnectionPool)
    state = lock(pool.condition) do
        (pool.open, pool.total, length(pool.idle))
    end
    print(io, "MySQL.ConnectionPool(", state[1] ? "open" : "closed",
        ", limit=", pool.limit, ", connections=", state[2], ", idle=", state[3], ")")
    return nothing
end

@noinline closed_pool() = throw(InvalidStateException("MySQL connection pool is closed", :closed))

function release_reservation!(pool::ConnectionPool)
    lock(pool.condition) do
        pool.total -= 1
        notify(pool.condition; all=false)
    end
    return nothing
end

# Keep the reservation until close finishes: retiring sessions still count against limit.
function retire_connection!(pool::ConnectionPool, conn::Connection)
    try
        DBInterface.close!(conn)
    finally
        release_reservation!(pool)
    end
    return nothing
end

function acquire_connection(pool::ConnectionPool)
    while true
        conn = nothing
        owned = false
        try
            lock(pool.condition)
            try
                while pool.open && isempty(pool.idle) && pool.total >= pool.limit
                    wait(pool.condition)
                end
                pool.open || closed_pool()
                if isempty(pool.idle)
                    pool.total += 1
                else
                    conn = pop!(pool.idle)
                end
                owned = true
            finally
                unlock(pool.condition)
            end
            conn === nothing && (conn = connection(pool.options))
            if !isopen(conn)
                owned = false
                retire_connection!(pool, conn)
                continue
            end
            isopen(pool) || closed_pool()
            owned = false
            return conn
        catch
            if owned
                if conn === nothing
                    release_reservation!(pool)
                else
                    try
                        retire_connection!(pool, conn)
                    catch
                    end
                end
            end
            rethrow()
        end
    end
end

function return_connection!(pool::ConnectionPool, conn::Connection)
    pooled = false
    try
        lock(pool.condition)
        try
            if pool.open
                push!(pool.idle, conn)
                pooled = true
                notify(pool.condition; all=false)
            end
        finally
            unlock(pool.condition)
        end
    finally
        pooled || retire_connection!(pool, conn)
    end
    return nothing
end

# COM_RESET_CONNECTION releases server statements; client generations also have to move
# before later finalizers can park old IDs or a new borrower can prepare another statement.
function reset_pooled_connection!(conn::Connection)
    return lock(conn.lock) do
        h = conn.handle
        h === nothing && return false
        s = h.session
        isopen(s) || return false
        drain_pending!(conn)
        response = try
            P.reset_connection!(s)
            P.read_command_response!(s; kind=P.CMD_SIMPLE)
        catch err
            # Servers without COM_RESET_CONNECTION can only be reused by reconnecting.
            err isa P.Error && err.errno == 1047 && s.phase == P.READY && return false
            rethrow()
        end
        if !(response isa P.OKPacket) || s.phase != P.READY
            throw(P.fault!(s, P.ProtocolError("connection reset did not return one final OK")))
        end
        invalidate_cursors!(conn)
        discard_parked_statements!(conn)
        conn.transaction_owner = nothing
        conn.buffered_bytes = 0
        opts = conn.options
        if !isempty(opts.db)
            P.init_db!(s, opts.db)
            selected = P.read_command_response!(s; kind=P.CMD_SIMPLE)
            if !(selected isa P.OKPacket) || s.phase != P.READY
                throw(P.fault!(s, P.ProtocolError("database restoration did not return one final OK")))
            end
            conn.db = opts.db
        end
        h.bootstrapped = bootstrap_charset!(s, response)
        opts.init_command === nothing || run_init_command!(s, opts)
        if isempty(opts.db)
            row = first(DBInterface.execute(conn, "SELECT DATABASE()"))
            ismissing(Tables.getcolumn(row, Union{Missing, String}, 1, Symbol("DATABASE()"))) || return false
        end
        return true
    end
end

"""
    MySQL.with_connection(f, pool)
    MySQL.with_connection(pool) do conn
        # Related operations use this one session.
    end

Call `f(conn)` with an exclusively borrowed connection, then clean up its session before
returning `f`'s value. An uncaught callback error retires the connection and is rethrown
unchanged. Reset failures also retire the connection and propagate; callbacks are never
replayed. A local open check does not guarantee that the server is still reachable.
Consume results inside the callback to observe SQL errors; unread responses are discarded
with the driver's ordinary draining behavior.

Finish all work using `conn` before returning. Connections, statements and unfinished
streamed results must not be used outside the callback. Owned buffered results and
materialized values remain readable. The Connection is not a revocable lease: escaped
statements can still auto-reprepare under the ordinary driver rules. Nested leases take
separate capacity and can block; pass the borrowed connection into nested work instead.
"""
function with_connection(f, pool::ConnectionPool)
    conn = nothing
    completed = false
    reusable = false
    try
        conn = acquire_connection(pool)
        result = f(conn)
        reusable = isopen(pool) && reset_pooled_connection!(conn)
        completed = true
        return result
    finally
        if conn === nothing
            # Acquisition either took no reservation or retired it before throwing.
        elseif completed
            reusable ? return_connection!(pool, conn) : retire_connection!(pool, conn)
        else
            try
                retire_connection!(pool, conn)
            catch
                # Preserve the callback or reset exception and its original backtrace.
            end
        end
    end
end

"""
    close(pool::MySQL.ConnectionPool)

Reject new leases, wake waiting callers, and close idle connections. Already acquired
leases are not interrupted, even if their callbacks start after a racing close; their
connections close on return. Connections still being created or reset also close instead
of entering the closed pool. Repeated close is harmless.
All idle closes are attempted, with failures reported in a `CompositeException`.
"""
function Base.close(pool::ConnectionPool)
    idle = lock(pool.condition) do
        pool.open || return Connection[]
        pool.open = false
        detached = pool.idle
        pool.idle = Connection[]
        notify(pool.condition; all=true)
        detached
    end
    errors = Any[]
    for conn in idle
        try
            retire_connection!(pool, conn)
        catch err
            push!(errors, err)
        end
    end
    isempty(errors) || throw(CompositeException(errors))
    return nothing
end
