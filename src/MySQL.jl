module MySQL

using Dates, DBInterface, Tables, Parsers, DecFP

# For non-C-api errors that happen in MySQL.jl
mutable struct MySQLInterfaceError
    msg::String
end
Base.showerror(io::IO, e::MySQLInterfaceError) = print(io, e.msg)

include("api/API.jl")
using .API

mutable struct Connection <: DBInterface.Connection
    mysql::API.MYSQL
    host::String
    user::String
    port::String
    db::String

    function Connection(host::String, user::String, passwd::String, db::String, port::Integer, unix_socket::String, client_flag)
        mysql = API.init()
        mysql = withenv("MARIADB_PLUGIN_DIR" => joinpath(API.MariaDB_Connector_C_jll.artifact_dir, "lib", "mariadb", "plugin")) do
            API.connect(mysql, host, user, passwd, db, port, unix_socket, client_flag)
        end
        return new(mysql, host, user, string(port), db)
    end
end

function Base.show(io::IO, conn::Connection)
    opts = conn.mysql.ptr == C_NULL ? "disconnected" :
        "host=\"$(conn.host)\", user=\"$(conn.user)\", port=\"$(conn.port)\", db=\"$(conn.db)\""
    print(io, "MySQL.Connection($opts)")
end

@noinline checkconn(conn::Connection) = conn.mysql.ptr == C_NULL && error("mysql connection has been closed or disconnected")

"""
    DBInterface.connect(MySQL.Connection, host::String, user::String, passwd::String; db::String="", port::Integer=3306, unix_socket::String=API.MYSQL_DEFAULT_SOCKET, client_flag=API.CLIENT_MULTI_STATEMENTS, opts = Dict())

Connect to a MySQL database.
"""
DBInterface.connect(::Type{Connection}, host::String, user::String, passwd::String; db::String="", port::Integer=3306, unix_socket::String=API.MYSQL_DEFAULT_SOCKET, client_flag=API.CLIENT_MULTI_STATEMENTS) =
    Connection(host, user, passwd, db, port, unix_socket, client_flag)

"""
    DBInterface.close!(conn::MySQL.Connection)

Close a `MySQL.Connection` opened by `DBInterface.connect`.
"""
function DBInterface.close!(conn::Connection)
    if conn.mysql.ptr != C_NULL
        API.mysql_close(conn.mysql.ptr)
        conn.mysql.ptr = C_NULL
    end
    return
end

function juliatype(field_type, notnullable, isunsigned)
    T = API.juliatype(field_type)
    T2 = isunsigned ? unsigned(T) : T
    return notnullable ? T2 : Union{Missing, T2}
end

include("execute.jl")
include("prepare.jl")

end # module
