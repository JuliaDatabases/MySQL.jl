using DBAPI

import DBAPI: show, connect, close, isopen, commit, rollback, cursor,
              connection, execute!, rows

"""
An internal function to check status codes and throw `MySQLError`.
"""
function mysql_error_check(conn::MySQLConnection, condition::Bool, msg)
    if condition
        throw(MySQLError(conn, msg))
    end
end

function mysql_error_check(conn::MySQLConnection, condition::Bool)
    if condition
        throw(MySQLError(conn))
    end
end

mysql_error_check(conn, status, msg) = mysql_error_check(conn, status != 0, msg)
mysql_error_check(conn, status) = mysql_error_check(conn, status != 0)

connect(::Type{MySQLInterface}, host, user, passwd, dbname) =
    MySQLConnection(mysql_connect(host, user, passwd, dbname))

function close(conn::MySQLConnection)
    mysql_disconnect(conn.hndl)
    return nothing
end

isopen(conn::MySQLConnection) = conn.hndl.mysqlptr != C_NULL

function commit(conn::MySQLConnection)
    status = mysql_commit(conn.hndl)
    mysql_error_check(conn, status)
    return nothing
end

function rollback(conn::MySQLConnection)
    status = mysql_rollback(conn.hndl)
    mysql_error_check(conn, status)
    return nothing
end

cursor(conn::MySQLConnection) = MySQLCursor(conn)

connection(csr::MySQLCursor) = csr.conn

function execute!(csr::MySQLCursor, qry::DatabaseQuery, parameters=())
    mysql_query(csr.conn.hndl, qry.query)
    csr.resptr = mysql_store_result(csr.conn.hndl)
    mysql_error_check(csr.conn, csr.resptr == C_NULL)
    return nothing
end

function rows(csr::MySQLCursor)
    mysql_error_check(csr.conn, csr.resptr == C_NULL,
                      "Cannot call `rows` on a null result set. Use `execute!` first.")
    return MySQLRowIterator(csr.resptr)
end

export connect, close, isopen, commit, rollback, cursor,
       connection, execute!, rows
