module MySQL

using Dates, DBInterface, Tables, Parsers, DecFP

export DBInterface, DateAndTime

# For non-C-api errors that happen in MySQL.jl
struct MySQLInterfaceError
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
    lastexecute::Any

    function Connection(host::AbstractString, user::AbstractString, passwd::Union{AbstractString, Nothing}, db::AbstractString, port::Integer, unix_socket::AbstractString; kw...)
        mysql = API.init()
        API.setoption(mysql, API.MYSQL_PLUGIN_DIR, API.PLUGIN_DIR)
        API.setoption(mysql, API.MYSQL_SET_CHARSET_NAME, "utf8mb4")
        client_flag = clientflags(; kw...)
        setoptions!(mysql; kw...)
        rng = findfirst("mysql://", host)
        if rng !== nothing
            host = host[last(rng)+1:end]
        end
        mysql = API.connect(mysql, host, user, passwd, db, port, unix_socket, client_flag)
        return new(mysql, host, user, string(port), db, nothing)
    end
end

function Base.show(io::IO, conn::Connection)
    opts = conn.mysql.ptr == C_NULL ? "disconnected" :
        "host=\"$(conn.host)\", user=\"$(conn.user)\", port=\"$(conn.port)\", db=\"$(conn.db)\""
    print(io, "MySQL.Connection($opts)")
end

@noinline checkconn(conn::Connection) = conn.mysql.ptr == C_NULL && error("mysql connection has been closed or disconnected")

function clear!(conn)
    conn.lastexecute === nothing || clear!(conn, conn.lastexecute)
    return
end

function clear!(conn, result::API.MYSQL_RES)
    if conn.mysql.ptr != C_NULL && result.ptr != C_NULL
        while true
            if API.fetchrow(conn.mysql, result) == C_NULL
                if API.moreresults(conn.mysql)
                    finalize(result)
                    @assert API.nextresult(conn.mysql) !== nothing
                    result = API.useresult(conn.mysql)
                else
                    break
                end
            end
        end
        finalize(result)
    end
    return
end

function clear!(conn, stmt::API.MYSQL_STMT)
    if stmt.ptr != C_NULL
        while API.fetch(stmt) == 0 || API.nextresult(stmt) !== nothing
        end
    end
    return
end

function clientflags(;
        found_rows::Bool=false,
        no_schema::Bool=false,
        compress::Bool=false,
        ignore_space::Bool=false,
        local_files::Bool=false,
        multi_statements::Bool=true,
        multi_results::Bool=false,
        kw...
    )
    flags = UInt64(0)
    if found_rows
        flags |= API.CLIENT_FOUND_ROWS
    elseif no_schema
        flags |= API.CLIENT_NO_SCHEMA
    elseif compress
        flags |= API.CLIENT_COMPRESS
    elseif ignore_space
        flags |= API.CLIENT_IGNORE_SPACE
    elseif local_files
        flags |= API.CLIENT_LOCAL_FILES
    elseif multi_statements
        flags |= API.CLIENT_MULTI_STATEMENTS
    elseif multi_results
        error("CLIENT_MULTI_RESULTS not currently supported by MySQL.jl")
    end
    return flags
end

function setoptions!(mysql;
        init_command::Union{AbstractString, Nothing}=nothing,
        connect_timeout::Union{Integer, Nothing}=nothing,
        reconnect::Union{Bool, Nothing}=nothing,
        read_timeout::Union{Integer, Nothing}=nothing,
        write_timeout::Union{Integer, Nothing}=nothing,
        data_truncation::Union{Bool, Nothing}=nothing,
        charset_dir::Union{AbstractString, Nothing}=nothing,
        charset_name::Union{AbstractString, Nothing}=nothing,
        bind::Union{AbstractString, Nothing}=nothing,
        max_allowed_packet::Union{Integer, Nothing}=nothing,
        net_buffer_length::Union{Integer, Nothing}=nothing,
        named_pipe::Union{Bool, Nothing}=nothing,
        protocol::Union{API.mysql_protocol_type, Nothing}=nothing,
        ssl_key::Union{AbstractString, Nothing}=nothing,
        ssl_cert::Union{AbstractString, Nothing}=nothing,
        ssl_ca::Union{AbstractString, Nothing}=nothing,
        ssl_capath::Union{AbstractString, Nothing}=nothing,
        ssl_cipher::Union{AbstractString, Nothing}=nothing,
        ssl_crl::Union{AbstractString, Nothing}=nothing,
        ssl_crlpath::Union{AbstractString, Nothing}=nothing,
        passphrase::Union{AbstractString, Nothing}=nothing,
        ssl_verify_server_cert::Union{Bool, Nothing}=nothing,
        ssl_enforce::Union{Bool, Nothing}=nothing,
        ssl_mode::Union{API.mysql_ssl_mode, Nothing}=nothing,
        default_auth::Union{AbstractString, Nothing}=nothing,
        connection_handler::Union{AbstractString, Nothing}=nothing,
        plugin_dir::Union{AbstractString, Nothing}=nothing,
        secure_auth::Union{Bool, Nothing}=nothing,
        server_public_key::Union{AbstractString, Nothing}=nothing,
        read_default_file::Union{Bool, Nothing}=nothing,
        option_file::Union{AbstractString, Nothing}=nothing,
        read_default_group::Union{Bool, Nothing}=nothing,
        option_group::Union{AbstractString, Nothing}=nothing,
        kw...
    )
    if init_command !== nothing
        API.setoption(mysql, API.MYSQL_INIT_COMMAND, init_command)
    end
    if connect_timeout !== nothing
        API.setoption(mysql, API.MYSQL_OPT_CONNECT_TIMEOUT, connect_timeout)
    end
    if reconnect !== nothing
        API.setoption(mysql, API.MYSQL_OPT_RECONNECT, reconnect)
    end
    if read_timeout !== nothing
        API.setoption(mysql, API.MYSQL_OPT_READ_TIMEOUT, read_timeout)
    end
    if write_timeout !== nothing
        API.setoption(mysql, API.MYSQL_OPT_WRITE_TIMEOUT, write_timeout)
    end
    if data_truncation !== nothing
        API.setoption(mysql, API.MYSQL_REPORT_DATA_TRUNCATION, data_truncation)
    end
    if charset_dir !== nothing
        API.setoption(mysql, API.MYSQL_SET_CHARSET_DIR, charset_dir)
    end
    if charset_name !== nothing
        API.setoption(mysql, API.MYSQL_SET_CHARSET_NAME, charset_name)
    end
    if bind !== nothing
        API.setoption(mysql, API.MYSQL_OPT_BIND, bind)
    end
    if max_allowed_packet !== nothing
        API.setoption(mysql, API.MYSQL_OPT_MAX_ALLOWED_PACKET, max_allowed_packet)
    end
    if net_buffer_length !== nothing
        API.setoption(mysql, API.MYSQL_OPT_NET_BUFFER_LENGTH, net_buffer_length)
    end
    if named_pipe !== nothing
        API.setoption(mysql, API.MYSQL_OPT_NAMED_PIPE, named_pipe)
    end
    if protocol !== nothing
        API.setoption(mysql, API.MYSQL_OPT_PROTOCOL, protocol)
    end
    if ssl_key !== nothing
        API.setoption(mysql, API.MYSQL_OPT_SSL_KEY, ssl_key)
    end
    if ssl_cert !== nothing
        API.setoption(mysql, API.MYSQL_OPT_SSL_CERT, ssl_cert)
    end
    if ssl_ca !== nothing
        API.setoption(mysql, API.MYSQL_OPT_SSL_CA, ssl_ca)
    end
    if ssl_capath !== nothing
        API.setoption(mysql, API.MYSQL_OPT_SSL_CAPATH, ssl_capath)
    end
    if ssl_cipher !== nothing
        API.setoption(mysql, API.MYSQL_OPT_SSL_CIPHER, ssl_cipher)
    end
    if ssl_crl !== nothing
        API.setoption(mysql, API.MYSQL_OPT_SSL_CRL, ssl_crl)
    end
    if ssl_crlpath !== nothing
        API.setoption(mysql, API.MYSQL_OPT_SSL_CRLPATH, ssl_crlpath)
    end
    if ssl_mode !== nothing
        API.setoption(mysql, API.MYSQL_OPT_SSL_MODE, ssl_mode)
    end
    if passphrase !== nothing
        API.setoption(mysql, API.MARIADB_OPT_TLS_PASSPHRASE, passphrase)
    end
    if ssl_verify_server_cert !== nothing
        API.setoption(mysql, API.MYSQL_OPT_SSL_VERIFY_SERVER_CERT, ssl_verify_server_cert)
    end
    if ssl_enforce !== nothing
        API.setoption(mysql, API.MYSQL_OPT_SSL_ENFORCE, ssl_enforce)
    end
    if default_auth !== nothing
        API.setoption(mysql, API.MYSQL_DEFAULT_AUTH, default_auth)
    end
    if connection_handler !== nothing
        API.setoption(mysql, API.MARIADB_OPT_CONNECTION_HANDLER, connection_handler)
    end
    if plugin_dir !== nothing
        API.setoption(mysql, API.MYSQL_PLUGIN_DIR, plugin_dir)
    end
    if secure_auth !== nothing
        API.setoption(mysql, API.MYSQL_SECURE_AUTH, secure_auth)
    end
    if server_public_key !== nothing
        API.setoption(mysql, API.MYSQL_SERVER_PUBLIC_KEY, server_public_key)
    end
    if read_default_file !== nothing && read_default_file
        API.setoption(mysql, API.MYSQL_READ_DEFAULT_FILE, C_NULL)
    end
    if option_file !== nothing
        API.setoption(mysql, API.MYSQL_READ_DEFAULT_FILE, option_file)
    end
    if read_default_group !== nothing && read_default_group
        API.setoption(mysql, API.MYSQL_READ_DEFAULT_GROUP, C_NULL)
    end
    if option_group !== nothing
        API.setoption(mysql, API.MYSQL_READ_DEFAULT_GROUP, option_group)
    end
    return
end

"""
    DBInterface.connect(MySQL.Connection, host::AbstractString, user::AbstractString, passwd::AbstractString; db::AbstractString="", port::Integer=3306, unix_socket::AbstractString=API.MYSQL_DEFAULT_SOCKET, client_flag=API.CLIENT_MULTI_STATEMENTS, opts = Dict())

Connect to a MySQL database with provided `host`, `user`, and `passwd` positional arguments. Supported keyword arguments include:
  * `db::AbstractString=""`: attach to a database by default
  * `port::Integer=3306`: connect to the database on a specific port
  * `unix_socket::AbstractString`: specifies the socket or named pipe that should be used
  * `found_rows::Bool=false`: Return the number of matched rows instead of number of changed rows
  * `no_schema::Bool=false`: Forbids the use of database.tablename.column syntax and forces the SQL parser to generate an error.
  * `compress::Bool=false`: Use compression protocol
  * `ignore_space::Bool=false`: Allows spaces after function names. All function names will become reserved words.
  * `local_files::Bool=false`: Allows LOAD DATA LOCAL statements
  * `multi_statements::Bool=false`: Allows the client to send multiple statements in one command. Statements will be divided by a semicolon.
  * `multi_results::Bool=false`: currently not supported by MySQL.jl
  * `init_command=""`: Command(s) which will be executed when connecting and reconnecting to the server.
  * `connect_timeout::Integer`: Connect timeout in seconds
  * `reconnect::Bool`: Enable or disable automatic reconnect.
  * `read_timeout::Integer`: Specifies the timeout in seconds for reading packets from the server.
  * `write_timeout::Integer`: Specifies the timeout in seconds for reading packets from the server.
  * `data_truncation::Bool`: Enable or disable reporting data truncation errors for prepared statements
  * `charset_dir::AbstractString`: character set files directory
  * `charset_name::AbstractString`: Specify the default character set for the connection
  * `bind::AbstractString`: Specify the network interface from which to connect to the database, like `"192.168.8.3"`
  * `max_allowed_packet::Integer`: The maximum packet length to send to or receive from server. The default is 16MB, the maximum 1GB.
  * `net_buffer_length::Integer`: The buffer size for TCP/IP and socket communication. Default is 16KB.
  * `named_pipe::Bool`: For Windows operating systems only: Use named pipes for client/server communication.
  * `protocol::MySQL.API.mysql_protocol_type`: Specify the type of client/server protocol. Possible values are: `MySQL.API.MYSQL_PROTOCOL_TCP`, `MySQL.API.MYSQL_PROTOCOL_SOCKET`, `MySQL.API.MYSQL_PROTOCOL_PIPE`, `MySQL.API.MYSQL_PROTOCOL_MEMORY`.
  * `ssl_key::AbstractString`: Defines a path to a private key file to use for TLS. This option requires that you use the absolute path, not a relative path. If the key is protected with a passphrase, the passphrase needs to be specified with `passphrase` keyword argument.
  * `passphrase::AbstractString`: Specify a passphrase for a passphrase-protected private key, as configured by the `ssl_key` keyword argument.
  * `ssl_cert::AbstractString`: Defines a path to the X509 certificate file to use for TLS. This option requires that you use the absolute path, not a relative path.
  * `ssl_ca::AbstractString`: Defines a path to a PEM file that should contain one or more X509 certificates for trusted Certificate Authorities (CAs) to use for TLS. This option requires that you use the absolute path, not a relative path.
  * `ssl_capath::AbstractString`: Defines a path to a directory that contains one or more PEM files that should each contain one X509 certificate for a trusted Certificate Authority (CA) to use for TLS. This option requires that you use the absolute path, not a relative path. The directory specified by this option needs to be run through the openssl rehash command.
  * `ssl_cipher::AbstractString`: Defines a list of permitted ciphers or cipher suites to use for TLS, like `"DHE-RSA-AES256-SHA"`
  * `ssl_crl::AbstractString`: Defines a path to a PEM file that should contain one or more revoked X509 certificates to use for TLS. This option requires that you use the absolute path, not a relative path.
  * `ssl_crlpath::AbstractString`: Defines a path to a directory that contains one or more PEM files that should each contain one revoked X509 certificate to use for TLS. This option requires that you use the absolute path, not a relative path. The directory specified by this option needs to be run through the openssl rehash command.
  * `ssl_verify_server_cert::Bool`: Enables (or disables) server certificate verification.
  * `ssl_enforce::Bool`: Whether to force TLS
  * `default_auth::AbstractString`: Default authentication client-side plugin to use.
  * `connection_handler::AbstractString`: Specify the name of a connection handler plugin.
  * `plugin_dir::AbstractString`: Specify the location of client plugins. The plugin directory can also be specified with the MARIADB_PLUGIN_DIR environment variable.
  * `secure_auth::Bool`: Refuse to connect to the server if the server uses the mysql_old_password authentication plugin. This mode is off by default, which is a difference in behavior compared to MySQL 5.6 and later, where it is on by default.
  * `server_public_key::AbstractString`: Specifies the name of the file which contains the RSA public key of the database server. The format of this file must be in PEM format. This option is used by the caching_sha2_password client authentication plugin.
  * `read_default_file::Bool`: only the default option files are read
  * `option_file::AbstractString`: the argument is interpreted as a path to a custom option file, and only that option file is read.
  * `read_default_group::Bool`: only the default option groups are read from specified option file(s)
  * `option_group::AbstractString`: it is interpreted as a custom option group, and that custom option group is read in addition to the default option groups.
"""
DBInterface.connect(::Type{Connection}, host::AbstractString, user::AbstractString, passwd::Union{AbstractString, Nothing}=nothing; db::AbstractString="", port::Integer=3306, unix_socket::AbstractString=API.MYSQL_DEFAULT_SOCKET, kw...) =
    Connection(host, user, passwd, db, port, unix_socket; kw...)

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

Base.close(conn::Connection) = DBInterface.close!(conn)
Base.isopen(conn::Connection) = conn.mysql.ptr != C_NULL && API.isopen(conn.mysql)

function juliatype(field_type, notnullable, isunsigned, isbinary, date_and_time)
    T = API.juliatype(field_type)
    T2 = isunsigned && !(T <: AbstractFloat) ? unsigned(T) : T
    T3 = !isbinary && T2 == Vector{UInt8} ? String : T2
    T4 = date_and_time && T3 <: DateTime ? DateAndTime : T3
    return notnullable ? T4 : Union{Missing, T4}
end

include("execute.jl")
include("prepare.jl")
include("load.jl")

"""
    MySQL.escape(conn::MySQL.Connection, str::AbstractString) -> String

Escapes a string using `mysql_real_escape_string()`, returns the escaped string.
"""
escape(conn::Connection, sql::AbstractString) = API.escapestring(conn.mysql, sql)

end # module
