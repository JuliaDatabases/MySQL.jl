# Prepared statements: COM_STMT_PREPARE with the parameter/column definitions, parameter
# binding and the `(type, unsigned)` signature that drives `new_params_bind_flag`,
# COM_STMT_EXECUTE returning a binary-protocol cursor, the single `ER_NEED_REPREPARE` (1615)
# retry, lazy re-prepare after a reconnect, retained long-data chunks, and finalizer-free
# statement reaping.

struct LongDataChunk
    parameter_number::UInt16
    data::Vector{UInt8}
end

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
    long_data::Vector{LongDataChunk}
    date_and_time::Bool
    dynamic_metadata::Bool
    metadata_date_and_time::Bool
    closed::Bool
    reap::StatementReapEntry
end

DBInterface.getconnection(stmt::Statement) = stmt.conn
Base.show(io::IO, stmt::Statement) = print(io, "MySQL.Native.Statement(", repr(stmt.sql), ")")

function statement_schema(conn::Connection, columns::Vector{P.ColumnDef}, date_and_time::Bool)
    opts = ResultOptions(; date_and_time=date_and_time, zero_dates=conn.results.zero_dates, time_type=conn.results.time_type)
    names = [Symbol(col.name) for col in columns]
    types = Type[juliatype(col, opts) for col in columns]
    lookup = Dict{Symbol, Int}(nm => i for (i, nm) in enumerate(names))
    return names, types, lookup
end

statement_schema(conn::Connection, ok::P.PrepareOK, date_and_time::Bool) =
    statement_schema(conn, ok.columns, date_and_time)

function same_column_definition(a::P.ColumnDef, b::P.ColumnDef)
    return a.catalog == b.catalog && a.schema == b.schema && a.table == b.table &&
           a.org_table == b.org_table && a.name == b.name && a.org_name == b.org_name &&
           a.charset == b.charset && a.length == b.length && a.type == b.type &&
           a.flags == b.flags && a.decimals == b.decimals
end

function same_column_definitions(a::Vector{P.ColumnDef}, b::Vector{P.ColumnDef})
    length(a) == length(b) || return false
    for i in eachindex(a, b)
        same_column_definition(a[i], b[i]) || return false
    end
    return true
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
            LongDataChunk[],
            mysql_date_and_time,
            isempty(ok.columns),
            mysql_date_and_time,
            false,
            StatementReapEntry(ok.statement_id, generation, nothing, false),
        )
        finalizer(finalize_statement, stmt)
        return stmt
    end
end

# Re-prepares `stmt.sql` on the current (READY) session and refreshes its id/generation and
# cached metadata. A 1615 retry closes the superseded id on the same session. A reconnect
# leaves the old-generation id alone because it belongs to the dead session.
function reprepare!(conn::Connection, s::P.Session, stmt::Statement; close_previous::Bool=false, replay_long_data::Bool=true)
    old_id = stmt.statement_id
    old_generation = stmt.generation
    P.stmt_prepare!(s, stmt.sql)
    ok = P.read_prepare_response!(s)
    generation = @atomic conn.generation
    if close_previous && old_generation == generation && old_id != ok.statement_id
        P.stmt_close!(s, old_id)
    end
    stmt.statement_id = ok.statement_id
    stmt.generation = generation
    stmt.reap.statement_id = stmt.statement_id
    stmt.reap.generation = stmt.generation
    stmt.nparams = P.num_params(ok)
    stmt.params = ok.params
    stmt.columns = ok.columns
    stmt.names, stmt.types, stmt.lookup = statement_schema(conn, ok, stmt.date_and_time)
    stmt.dynamic_metadata = isempty(ok.columns)
    stmt.metadata_date_and_time = stmt.date_and_time
    empty!(stmt.last_signature)
    if replay_long_data
        validate_long_data_ids(stmt)
        replay_long_data!(s, stmt)
    end
    return nothing
end

function send_execute!(s::P.Session, stmt::Statement, params)
    validate_long_data_params(stmt, params)
    signature = param_signature(params)
    send_types = signature != stmt.last_signature
    block = if isempty(stmt.long_data)
        encode_param_block(params, signature, send_types)
    else
        slots = Int[Int(chunk.parameter_number) + 1 for chunk in stmt.long_data]
        unique!(slots)
        encode_param_block(params, signature, send_types; skip=slots)
    end
    P.stmt_execute!(s, stmt.statement_id, block)
    stmt.last_signature = signature
    return nothing
end

function read_execute_response!(s::P.Session, stmt::Statement; retain_need_reprepare::Bool)
    response = try
        P.read_command_response!(s)
    catch err
        need_reprepare = err isa P.StmtError && err.errno == P.ER_NEED_REPREPARE
        (retain_need_reprepare && need_reprepare) || empty!(stmt.long_data)
        rethrow()
    end
    empty!(stmt.long_data)
    return response
end

function validate_long_data_ids(stmt::Statement)
    for chunk in stmt.long_data
        Int(chunk.parameter_number) < stmt.nparams || throw(MySQLInterfaceError(
            "long-data parameter $(chunk.parameter_number) is outside 0:$(stmt.nparams - 1) after re-prepare",
        ))
    end
    return nothing
end

function replay_long_data!(s::P.Session, stmt::Statement)
    for chunk in stmt.long_data
        P.stmt_send_long_data!(s, stmt.statement_id, chunk.parameter_number, chunk.data)
    end
    return nothing
end

function validate_long_data_params(stmt::Statement, params)
    for chunk in stmt.long_data
        value = params[Int(chunk.parameter_number) + 1]
        type, _ = param_type(value)
        (type == P.MYSQL_TYPE_STRING || type == P.MYSQL_TYPE_BLOB) || throw(MySQLInterfaceError(
            "long-data parameter $(chunk.parameter_number) must be bound as a string or binary value, got $(typeof(value))",
        ))
    end
    return nothing
end

long_data_bytes(data::AbstractString) = Vector{UInt8}(codeunits(String(data)))
long_data_bytes(data::AbstractVector{UInt8}) = Vector{UInt8}(data)

"""
    MySQL.Native.send_long_data!(stmt, parameter_number, data)

Sends one copied string or byte chunk for the zero-based prepared-statement parameter number.
Repeated calls append chunks. The next execute omits that parameter's inline value and retains
the copied chunks until its first response, so a 1615 or reconnect re-prepare can replay them.
"""
function send_long_data!(stmt::Statement, parameter_number::Integer, data::Union{AbstractString, AbstractVector{UInt8}})
    conn = stmt.conn
    lock(conn.lock) do
        stmt.closed && closed_statement()
        (0 <= parameter_number < stmt.nparams) || throw(MySQLInterfaceError(
            "long-data parameter $parameter_number is outside 0:$(stmt.nparams - 1)",
        ))
        bytes = long_data_bytes(data)
        s = begin_command!(conn)
        if stmt.generation != (@atomic conn.generation)
            reprepare!(conn, s, stmt)
            (0 <= parameter_number < stmt.nparams) || throw(MySQLInterfaceError(
                "long-data parameter $parameter_number is outside 0:$(stmt.nparams - 1) after re-prepare",
            ))
        end
        chunk = LongDataChunk(UInt16(parameter_number), bytes)
        push!(stmt.long_data, chunk)
        try
            P.stmt_send_long_data!(s, stmt.statement_id, chunk.parameter_number, chunk.data)
        catch
            pop!(stmt.long_data)
            rethrow()
        end
        return nothing
    end
    return nothing
end

"""
    MySQL.Native.reset_statement!(stmt)

Resets a prepared statement's accumulated long data and open server cursor. The statement id
and cached parameter signature remain valid when the session generation did not change.
"""
function reset_statement!(stmt::Statement)
    conn = stmt.conn
    lock(conn.lock) do
        stmt.closed && closed_statement()
        s = begin_command!(conn)
        if stmt.generation != (@atomic conn.generation)
            empty!(stmt.long_data)
            reprepare!(conn, s, stmt; replay_long_data=false)
            return nothing
        end
        P.stmt_reset!(s, stmt.statement_id)
        P.read_command_response!(s)
        empty!(stmt.long_data)
        return nothing
    end
    return nothing
end

@noinline function paramcount_error(stmt, n)
    throw(MySQLInterfaceError("stmt requires $(stmt.nparams) params, only $n provided"))
end

function check_paramcount(stmt::Statement, params)
    length(params) == stmt.nparams || paramcount_error(stmt, length(params))
    return nothing
end

@noinline closed_statement() = error("prepared mysql statement has been closed")

"""
    DBInterface.execute(stmt::MySQL.Native.Statement, params=(); mysql_store_result=true) -> BinaryCursor

Executes the prepared statement with `params` bound as the `?` markers and returns a
binary-protocol cursor. `mysql_store_result=false` streams rows (the connection is busy until
the cursor is exhausted or closed).
"""
function DBInterface.execute(stmt::Statement, params=(); mysql_store_result::Bool=true, mysql_date_and_time::Bool=false)
    conn = stmt.conn
    lock(conn.lock) do
        stmt.closed && closed_statement()
        check_paramcount(stmt, params)
        s = begin_command!(conn)
        if stmt.generation != (@atomic conn.generation)
            reprepare!(conn, s, stmt)
            check_paramcount(stmt, params)
        end
        token = new_token!(conn)
        resp = try
            send_execute!(s, stmt, params)
            read_execute_response!(s, stmt; retain_need_reprepare=true)
        catch err
            # A complete ER_NEED_REPREPARE before any result bytes: re-prepare once, re-execute
            # once (the server's cached type signature is gone, so types are re-sent).
            (err isa P.StmtError && err.errno == P.ER_NEED_REPREPARE) || rethrow()
            reprepare!(conn, s, stmt; close_previous=true)
            check_paramcount(stmt, params)
            token = new_token!(conn)
            send_execute!(s, stmt, params)
            read_execute_response!(s, stmt; retain_need_reprepare=false)
        end
        date_and_time = stmt.dynamic_metadata ? mysql_date_and_time : stmt.date_and_time
        opts = ResultOptions(;
            date_and_time=date_and_time,
            zero_dates=conn.results.zero_dates,
            time_type=conn.results.time_type,
        )
        cursor = make_cursor(conn, stmt.sql, token, resp, true, mysql_store_result, opts, 1)
        if resp isa P.ResultHeader &&
                (!same_column_definitions(stmt.columns, resp.columns) ||
                 stmt.metadata_date_and_time != date_and_time)
            # Execute-time definitions are authoritative. Keep the Statement's mutable
            # containers independent from the returned cursor so neither can alter the
            # other's schema. `dynamic_metadata` retains the keyword-dispatch contract.
            stmt.columns = resp.columns
            stmt.names, stmt.types, stmt.lookup =
                statement_schema(conn, resp.columns, date_and_time)
            stmt.metadata_date_and_time = date_and_time
        end
        return cursor
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
        empty!(stmt.long_data)
        conn.handle === nothing && return nothing
        park_statement!(conn, stmt.reap)
        return nothing
    end
    return nothing
end

function finalize_statement(stmt::Statement)
    stmt.closed && return nothing
    conn = stmt.conn
    (@atomic conn.statement_reaping_open) || return nothing
    try_park_statement!(conn, stmt.reap) || finalizer(finalize_statement, stmt)
    return nothing
end

# One-shot `DBInterface.execute(conn, sql, params)`: prepare, execute, and park the statement
# so its COM_STMT_CLOSE goes out on the next command (after the cursor's stream is drained).
function execute_params(conn::Connection, sql::AbstractString, params; mysql_store_result::Bool, mysql_date_and_time::Bool)
    stmt = DBInterface.prepare(conn, sql; mysql_date_and_time=mysql_date_and_time)
    cursor = try
        DBInterface.execute(
            stmt,
            params;
            mysql_store_result=mysql_store_result,
            mysql_date_and_time=mysql_date_and_time,
        )
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
