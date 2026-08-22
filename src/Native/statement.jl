# Prepared statements: COM_STMT_PREPARE with the parameter/column definitions, parameter
# binding and the `(type, unsigned)` signature that drives `new_params_bind_flag`,
# COM_STMT_EXECUTE returning a binary-protocol cursor, the single `ER_NEED_REPREPARE` (1615)
# retry, lazy re-prepare after a reconnect, and finalizer-free statement reaping.

"""
    MySQL.Native.Statement

A prepared statement on the native backend, from `DBInterface.prepare(conn, sql)`. Execute it
with `DBInterface.execute(stmt, params)`; close it with `DBInterface.close!(stmt)` (the
COM_STMT_CLOSE is deferred to the next command, never sent from a finalizer).
"""
mutable struct Statement <: DBInterface.Statement
    conn::Connection
    statement_id::UInt32
    sql::String
    generation::Int
    nparams::Int
    params::Vector{P.ColumnDef}
    columns::Vector{P.ColumnDef}
    names::Vector{Symbol}
    types::Vector{Type}
    lookup::Dict{Symbol, Int}
    last_signature::Vector{UInt16}
    date_and_time::Bool
    closed::Bool
    reap::StatementReapEntry
end

DBInterface.getconnection(stmt::Statement) = stmt.conn
Base.show(io::IO, stmt::Statement) = print(io, "MySQL.Native.Statement(", repr(stmt.sql), ")")

function statement_schema(conn::Connection, ok::P.PrepareOK, date_and_time::Bool)
    opts = ResultOptions(; date_and_time=date_and_time, zero_dates=conn.results.zero_dates, time_type=conn.results.time_type)
    names = [Symbol(col.name) for col in ok.columns]
    types = Type[juliatype(col, opts) for col in ok.columns]
    lookup = Dict{Symbol, Int}(nm => i for (i, nm) in enumerate(names))
    return names, types, lookup
end

"""
    DBInterface.prepare(conn::MySQL.Native.Connection, sql; mysql_date_and_time=false) -> Statement

Prepares `sql` on the server and returns a `Statement`. `mysql_date_and_time=true` maps
DATETIME/TIMESTAMP result columns to `DateAndTime` (microsecond precision).
"""
function DBInterface.prepare(conn::Connection, sql::AbstractString; mysql_date_and_time::Bool=false)
    lock(conn.lock) do
        s = begin_command!(conn)
        P.stmt_prepare!(s, sql)
        ok = P.read_prepare_response!(s)
        names, types, lookup = statement_schema(conn, ok, mysql_date_and_time)
        generation = @atomic conn.generation
        stmt = Statement(
            conn,
            ok.statement_id,
            String(sql),
            generation,
            P.num_params(ok),
            ok.params,
            ok.columns,
            names,
            types,
            lookup,
            UInt16[],
            mysql_date_and_time,
            false,
            StatementReapEntry(ok.statement_id, generation, nothing),
        )
        finalizer(finalize_statement, stmt)
        return stmt
    end
end

# Re-prepares `stmt.sql` on the current (READY) session and refreshes its id/generation and
# cached metadata. Used after a reconnect and after a single 1615 (ER_NEED_REPREPARE).
function reprepare!(conn::Connection, s::P.Session, stmt::Statement)
    P.stmt_prepare!(s, stmt.sql)
    ok = P.read_prepare_response!(s)
    stmt.statement_id = ok.statement_id
    stmt.generation = @atomic conn.generation
    stmt.reap.statement_id = stmt.statement_id
    stmt.reap.generation = stmt.generation
    stmt.nparams = P.num_params(ok)
    stmt.params = ok.params
    stmt.columns = ok.columns
    stmt.names, stmt.types, stmt.lookup = statement_schema(conn, ok, stmt.date_and_time)
    empty!(stmt.last_signature)
    return nothing
end

function send_execute!(s::P.Session, stmt::Statement, params)
    signature = param_signature(params)
    send_types = signature != stmt.last_signature
    block = encode_param_block(params, signature, send_types)
    P.stmt_execute!(s, stmt.statement_id, block)
    stmt.last_signature = signature
    return nothing
end

@noinline paramcount_error(stmt, n) = throw(MySQLInterfaceError("statement requires $(stmt.nparams) parameters, got $n"))

"""
    DBInterface.execute(stmt::MySQL.Native.Statement, params=(); mysql_store_result=true) -> BinaryCursor

Executes the prepared statement with `params` bound as the `?` markers and returns a
binary-protocol cursor. `mysql_store_result=false` streams rows (the connection is busy until
the cursor is exhausted or closed).
"""
function DBInterface.execute(stmt::Statement, params=(); mysql_store_result::Bool=true, mysql_date_and_time::Bool=false)
    conn = stmt.conn
    lock(conn.lock) do
        stmt.closed && throw(MySQLInterfaceError("prepared statement is closed"))
        length(params) == stmt.nparams || paramcount_error(stmt, length(params))
        opts = ResultOptions(; date_and_time=(stmt.date_and_time || mysql_date_and_time), zero_dates=conn.results.zero_dates, time_type=conn.results.time_type)
        s = begin_command!(conn)
        stmt.generation == (@atomic conn.generation) || reprepare!(conn, s, stmt)
        token = new_token!(conn)
        resp = try
            send_execute!(s, stmt, params)
            P.read_command_response!(s)
        catch err
            # A complete ER_NEED_REPREPARE before any result bytes: re-prepare once, re-execute
            # once (the server's cached type signature is gone, so types are re-sent).
            (err isa P.StmtError && err.errno == P.ER_NEED_REPREPARE) || rethrow()
            reprepare!(conn, s, stmt)
            token = new_token!(conn)
            send_execute!(s, stmt, params)
            P.read_command_response!(s)
        end
        return make_cursor(conn, stmt.sql, token, resp, true, mysql_store_result, opts, 1)
    end
end

"""
    DBInterface.executemultiple(stmt::MySQL.Native.Statement, params=(); kw...) -> Cursors

Iterates every result set of a prepared CALL (or multi-result statement) as a distinct
binary cursor, like the connection-level `executemultiple`.
"""
function DBInterface.executemultiple(stmt::Statement, params=(); mysql_store_result::Bool=true, mysql_date_and_time::Bool=false)
    first = DBInterface.execute(stmt, params; mysql_store_result=mysql_store_result, mysql_date_and_time=mysql_date_and_time)
    return Cursors(stmt.conn, stmt.sql, first.opts, first)
end

"""
    DBInterface.close!(stmt::MySQL.Native.Statement)

Closes the prepared statement. The COM_STMT_CLOSE is parked and sent before the next command
(never from a finalizer). Idempotent.
"""
function DBInterface.close!(stmt::Statement)
    conn = stmt.conn
    lock(conn.lock) do
        stmt.closed && return nothing
        stmt.closed = true
        conn.handle === nothing && return nothing
        park_statement!(conn, stmt.reap)
        return nothing
    end
    return nothing
end

function finalize_statement(stmt::Statement)
    stmt.closed && return nothing
    conn = stmt.conn
    conn.handle === nothing && return nothing
    try_park_statement!(conn, stmt.reap) || finalizer(finalize_statement, stmt)
    return nothing
end

# One-shot `DBInterface.execute(conn, sql, params)`: prepare, execute, and park the statement
# so its COM_STMT_CLOSE goes out on the next command (after the cursor's stream is drained).
function execute_params(conn::Connection, sql::AbstractString, params; mysql_store_result::Bool, mysql_date_and_time::Bool)
    stmt = DBInterface.prepare(conn, sql; mysql_date_and_time=mysql_date_and_time)
    cursor = try
        DBInterface.execute(stmt, params; mysql_store_result=mysql_store_result)
    catch
        DBInterface.close!(stmt)
        rethrow()
    end
    lock(conn.lock) do
        stmt.closed = true
        conn.handle === nothing || park_statement!(conn, stmt.reap)
    end
    return cursor
end
