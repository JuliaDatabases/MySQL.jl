using DBAPI

abstract MySQLInterface <: DatabaseInterface

type MySQLConnection <: DatabaseConnection{MySQLInterface}
    hndl::MySQLHandle
end

type MySQLError <: DatabaseError{MySQLInterface}
    conn::MySQLConnection
    msg::ASCIIString
    function MySQLError(conn)
        new(conn, bytestring(mysql_error(conn.hndl)))
    end
end

function Base.showerror(io::IO, e::MySQLError)
    print(io, e.msg)
end

type MySQLCursor <: DatabaseCursor{MySQLInterface}
    conn::MySQLConnection
    resptr::MYSQL_RES
end

function MySQLCursor(conn)
    MySQLCursor(conn, C_NULL)
end


export MySQLInterface, MySQLError, MySQLConnection, MySQLCursor
