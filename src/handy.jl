# Handy wrappers to functions defined in api.jl.

"""
A handy function that wraps mysql_init and mysql_real_connect. Also does error
checking on the pointers returned by init and real_connect.
"""
function mysql_connect(host::String,
                       user::String,
                       passwd::String,
                       db::String,
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

"""
Wrapper over mysql_real_connect with CLIENT_MULTI_STATEMENTS passed
as client flag options.
"""
function mysql_connect(hostName::String, userName::String, password::String, db::String)
    return mysql_connect(hostName, userName, password, db, 0,
                         C_NULL, MySQL.CLIENT_MULTI_STATEMENTS)
end

"""
Wrapper over mysql_close. Must be called to close the connection opened by
MySQL.mysql_connect.
"""
function mysql_disconnect(db::MySQLDatabaseHandle)
    mysql_close(db.ptr)
end