using DBAPI

abstract MySQLInterface <: DatabaseInterface

type MySQLConnection <: DatabaseConnection{MySQLInterface}
    hndl::MySQLHandle
end

abstract MySQLAbstractError <: DatabaseError{MySQLInterface}

type MySQLError <: MySQLAbstractError
    msg::ASCIIString
end

type MySQLInternalError <: MySQLAbstractError
    conn::MySQLConnection
    msg::AbstractString
    function MySQLInternalError(conn)
        new(conn, bytestring(mysql_error(conn.hndl)))
    end
end

Base.showerror{T <: MySQLAbstractError}(io::IO, e::T) =
    print(io, T, ": " * e.msg)

type MySQLCursor <: DatabaseCursor{MySQLInterface}
    conn::MySQLConnection
    resptr::MYSQL_RES
    function MySQLCursor(conn, resptr::Ptr{Void})
        new(conn, resptr)
    end
end

function MySQLCursor(conn)
    isopen(conn) || throw(MySQLError("Attempting to create cursor with a null connection"))
    MySQLCursor(conn, C_NULL)
end

export MySQLInterface, MySQLConnection, MySQLCursor, MySQLError, MySQLInternalError

import DBAPI: show, connect, close, isopen, commit, rollback, cursor,
              connection, execute!, rows, length

"""
Open a MySQL Connection to the specified `host`.

Returns a `MySQLConnection` instance.
"""
connect(::Type{MySQLInterface}, host, user, passwd, dbname) =
    MySQLConnection(mysql_connect(host, user, passwd, dbname))

"""
Closes the MySQLConnection `conn`.  Throws a `MySQLError` if connection is null.

Returns `nothing`.
"""
function close(conn::MySQLConnection)
    isopen(conn) || throw(MySQLError("Cannot close null connection."))
    mysql_disconnect(conn.hndl)
    return nothing
end

"""
Close the MySQLCursor `csr`.

Returns `nothing`.
"""
function close(csr::MySQLCursor)
    if csr.resptr != C_NULL
        mysql_free_result(csr.resptr)
        csr.resptr = C_NULL
    end
    return nothing
end

"""
Returns a boolean indicating whether connection `conn` is open.
"""
isopen(conn::MySQLConnection) = conn.hndl.mysqlptr != C_NULL

"""
Commit any pending transaction to the database.  Throws a `MySQLError` if connection is null.

Returns `nothing`.
"""
function commit(conn::MySQLConnection)
    isopen(conn) || throw(MySQLError("Commit called on null connection."))
    mysql_commit(conn.hndl) == 0 || throw(MySQLInternalError(conn))
    return nothing
end

"""
Roll back to the start of any pending transaction.  Throws a `MySQLError` if connection is null.

Returns `nothing`.
"""
function rollback(conn::MySQLConnection)
    isopen(conn) || throw(MySQLError("Rollback called on null connection."))
    mysql_rollback(conn.hndl) == 0 || throw(MySQLInternalError(conn))
    return nothing
end

"""
Create a new database cursor.

Returns a `MySQLCursor` instance.
"""
cursor(conn::MySQLConnection) = MySQLCursor(conn)

"""
Return the corresponding connection for a given cursor.
"""
connection(csr::MySQLCursor) = csr.conn

"""
Run a query on a database.

The results of the query are not returned by this function but are accessible through the cursor.

Throws a `MySQLError` if query caused an error, cursor is not initialized or connection is null.

Returns `nothing`.
"""
function execute!(csr::MySQLCursor, qry::SimpleStringQuery)
    isopen(connection(csr)) || throw(MySQLError("Cannot execute with null connection."))
    mysql_query(csr.conn.hndl, qry.query) == 0 || throw(MySQLInternalError(csr.conn))
    csr.resptr != C_NULL && mysql_free_result(csr.resptr)
    csr.resptr = mysql_store_result(csr.conn.hndl)
    return nothing
end

"""
Create a row iterator.

This method returns an instance of an iterator type which returns one row
on each iteration. Each row returnes a Tuple{...}.

Throws a `MySQLError` if `execute!` was not called on the cursor or connection is null.

Returns a `MySQLRowIterator` instance.
"""
function rows(csr::MySQLCursor)
    isopen(connection(csr)) || throw(MySQLError("Cannot create iterator with null connection."))
    csr.resptr == C_NULL && throw(MySQLError("Cannot call `rows` on a null result set. Use `execute!` first."))
    return MySQLRowIterator(csr.resptr)
end

function length(csr::MySQLCursor)
    csr.resptr == C_NULL && throw(MySQLError("Cannot get length of empty result."))
    mysql_num_rows(csr.resptr)
end


export connect, close, isopen, commit, rollback, cursor,
       connection, execute!, rows, length
