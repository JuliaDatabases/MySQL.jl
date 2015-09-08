## Overides the Base package's connect and invokes the mysql_real_connect API
## TODO: Check if it is really required to override Base package !!!!
function Base.connect(::Type{MySQL5},
                      host::String,
                      user::String,
                      passwd::String,
                      db::String, # TODO: Let this be optional?
                      port::Integer = 0,
                      unix_socket::Any = C_NULL,
                      client_flag::Integer = 0)

    mysqlptr::Ptr{Cuchar} = C_NULL
    mysqlptr = mysql_init(mysqlptr)

    if mysqlptr == C_NULL
        error("Failed to initialize MySQL database")
    end

    mysqlptr = mysql_real_connect(mysqlptr,
                                  host,
                                  user,
                                  passwd,
                                  db,
                                  convert(Cint, port),
                                  unix_socket,
                                  convert(Uint64, client_flag))

    if mysqlptr == C_NULL
        error("Failed to connect to MySQL database")
    end

    return MySQLDatabaseHandle(mysqlptr, 0)
end

## Overides the DBI package's disconnect and invokes the mysql_close API
## TODO: Check if it is really required to override DBI package !!!!
function DBI.disconnect(db::MySQLDatabaseHandle)
    mysql_close(db.ptr)
    return
end


#= Set of useful functions. 
## TODO:: Do we really need this ????
function DBI.columninfo(db::MySQLDatabaseHandle,
                        table::String,
                        column::String)
    error("DBI API not fully implemented")
end

function DBI.prepare(db::MySQLDatabaseHandle, sql::String)
    stmtptr = mysql_stmt_init(db.ptr)
    if stmtptr == C_NULL
        error("Failed to allocate statement handle")
    end
    status = mysql_stmt_prepare(stmtptr, sql)
    db.status = status
    if status != 0
        msg = bytestring(mysql_stmt_error(stmtptr))
        error(msg)
    end
    stmt = MySQLStatementHandle(db, stmtptr)
    return stmt
end

function DBI.errcode(db::MySQLDatabaseHandle)
    return int(mysql_errno(db.ptr))
end

# TODO: Make a copy here?
function DBI.errstring(db::MySQLDatabaseHandle)
    return bytestring(mysql_error(db.ptr))
end

function DBI.execute(stmt::MySQLStatementHandle)
    status = mysql_stmt_execute(stmt.ptr)
    stmt.db.status = status
    if status != 0
        error(errstring(stmt.db))
    else
        stmt.executed += 1
    end
    return
end


function DBI.fetchall(stmt::MySQLStatementHandle)
    error("DBI API not fully implemented")
end

function DBI.fetchdf(stmt::MySQLStatementHandle)
    error("DBI API not fully implemented")
end

function DBI.fetchrow(stmt::MySQLStatementHandle)
    error("DBI API not fully implemented")
end

function DBI.finish(stmt::MySQLStatementHandle)
    failed = mysql_stmt_close(stmt.ptr)
    if failed
        error("Failed to close MySQL statement handle")
    end
    return
end

function DBI.lastinsertid(db::MySQLDatabaseHandle)
    return int64(mysql_insert_id(db.ptr))
end

# TODO: Rename this
function DBI.sqlescape(db::MySQLDatabaseHandle, dirtysql::String)
    to = Array(Uint8, 4 * length(dirtysql))
    writelength = mysql_real_escape_string(db.ptr,
                                           to,
                                           dirtysql,
                                           convert(Uint32, length(dirtysql)))
    return bytestring(to[1:writelength])
end

function DBI.tableinfo(db::MySQLDatabaseHandle, table::String)
    error("DBI API not fully implemented")
end
=#
