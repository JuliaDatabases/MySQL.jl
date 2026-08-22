# Connection options: the compatibility truth table of `DBInterface.connect(MySQL.Connection, ...)`
# keywords, the ssl conflict table, option files, and the opt-in environment defaults.

const DEFAULT_PORT = 3306
const UTF8MB4 = "utf8mb4"

"""
    ConnectOptions

Validated, fully resolved connection parameters (see `ConnectOptions(host, user, password; kw...)`).
"""
struct ConnectOptions
    host::String
    port::Int
    user::String
    password::Union{Nothing, String}
    db::String
    connect_timeout::Union{Nothing, Int}
    read_timeout::Union{Nothing, Int}
    write_timeout::Union{Nothing, Int}
    bind::Union{Nothing, String}
    init_command::Union{Nothing, String}
    reconnect::Bool
    client_flags::UInt64
    tls::P.TLSOptions
    auth::P.AuthPolicy
    default_auth::Union{Nothing, String}
    can_handle_expired_passwords::Bool
    limits::P.Limits
    attrs::Vector{Pair{String, String}}
    local_infile_handler::Union{Nothing, Function}
    max_local_infile_bytes::Int
    debug::Bool
end

const REMOVED_KEYWORDS = Dict{Symbol, String}(
    :ssl_cipher => "cipher lists are not configurable on the native backend (modern AEAD suites only)",
    :ssl_crl => "certificate revocation lists are not supported by the native backend",
    :ssl_crlpath => "certificate revocation lists are not supported by the native backend",
    :passphrase => "encrypted private keys are not supported by the native backend",
    :charset_dir => "the native backend has no character-set files",
    :connection_handler => "the native backend has no dynamic plugins",
    :plugin_dir => "the native backend has no dynamic plugins",
    :compress => "protocol compression is not supported yet",
)

const DEPRECATED_KEYWORDS = Dict{Symbol, String}(
    :data_truncation => "result buffers are not fixed-size on the native backend; the option has no effect",
    :net_buffer_length => "buffer sizing is automatic on the native backend; the option has no effect",
    :secure_auth => "mysql_old_password is never supported by the native backend; the option has no effect",
    :multi_results => "multiple result sets are always negotiated; the option has no effect",
)

const DEFERRED_KEYWORDS = Dict{Symbol, String}(
    :unix_socket => "Unix-domain sockets are not supported yet (TCP only)",
    :named_pipe => "named pipes are not supported yet (TCP only)",
)

const KNOWN_KEYWORDS = Set{Symbol}([
    :db, :port, :unix_socket, :found_rows, :no_schema, :compress, :ignore_space, :local_files,
    :multi_statements, :multi_results, :init_command, :connect_timeout, :reconnect, :read_timeout,
    :write_timeout, :data_truncation, :charset_dir, :charset_name, :bind, :max_allowed_packet,
    :net_buffer_length, :named_pipe, :protocol, :ssl_key, :ssl_cert, :ssl_ca, :ssl_capath,
    :ssl_cipher, :ssl_crl, :ssl_crlpath, :passphrase, :ssl_verify_server_cert, :ssl_enforce,
    :ssl_mode, :ssl_server_name, :default_auth, :connection_handler, :plugin_dir, :secure_auth,
    :server_public_key, :get_server_public_key, :enable_cleartext_plugin, :insecure_cleartext_auth,
    :can_handle_expired_passwords, :read_default_file, :option_file, :read_default_group,
    :option_group, :read_env, :local_infile_handler, :max_local_infile_bytes, :max_buffered_bytes,
    :max_response_bytes, :max_columns, :max_result_sets, :max_metadata_bytes, :debug, :attrs,
    :tls_version,
])

const TLS_VERSION_NAMES = Dict{String, UInt16}("tlsv1.2" => P.Reseau.TLS.TLS1_2_VERSION, "tlsv1.3" => P.Reseau.TLS.TLS1_3_VERSION)

# `tls_version="TLSv1.2,TLSv1.3"` (libmysqlclient's option): the allowed protocol versions.
# Returns `(min_version, max_version)`; `nothing` means TLS 1.2 and 1.3 are both allowed.
function parse_tls_version(spec)
    spec === nothing && return (nothing, nothing)
    versions = UInt16[]
    for part in split(String(spec), ',')
        name = lowercase(strip(part))
        isempty(name) && continue
        push!(versions, get(TLS_VERSION_NAMES, name) do
            throw(ArgumentError("unsupported tls_version $(repr(strip(part))); the native backend speaks TLSv1.2 and TLSv1.3"))
        end)
    end
    isempty(versions) && throw(ArgumentError("tls_version must name at least one of TLSv1.2, TLSv1.3"))
    return (minimum(versions), maximum(versions))
end

@noinline removed_keyword(k::Symbol) = throw(ArgumentError("the `$k` option was removed: $(REMOVED_KEYWORDS[k])"))
@noinline deferred_keyword(k::Symbol) = throw(ArgumentError("the `$k` option is not available: $(DEFERRED_KEYWORDS[k])"))

function check_keywords(kw)
    for k in keys(kw)
        k in KNOWN_KEYWORDS || throw(ArgumentError("unknown connection option `$k`"))
        haskey(REMOVED_KEYWORDS, k) && kw[k] !== nothing && kw[k] !== false && removed_keyword(k)
        haskey(DEPRECATED_KEYWORDS, k) && kw[k] !== nothing && @warn "connection option `$k` is deprecated: $(DEPRECATED_KEYWORDS[k])" maxlog=1
    end
    return nothing
end

function protocol_is_tcp(protocol)
    protocol === nothing && return true
    p = protocol isa Symbol ? protocol : protocol isa AbstractString ? Symbol(lowercase(protocol)) : Symbol(lowercase(replace(string(protocol), "MYSQL_PROTOCOL_" => "")))
    return p == :tcp || p == :default
end

# ---- ssl conflict table ----

"""
    resolve_ssl_mode(; ssl_mode=nothing, ssl_enforce=nothing, ssl_verify_server_cert=nothing, has_ca=false)

An explicit `ssl_mode` wins; otherwise `ssl_verify_server_cert=true` ⇒ `:verify_identity`,
`ssl_enforce=true` ⇒ `:required`, CA material ⇒ `:verify_ca`, else `:preferred`. Explicit
`false` values never lower an explicit mode; contradictory explicit combinations are errors.
"""
function resolve_ssl_mode(; ssl_mode=nothing, ssl_enforce=nothing, ssl_verify_server_cert=nothing, has_ca::Bool=false)
    if ssl_mode !== nothing
        mode = P.ssl_mode(ssl_mode)
        ssl_enforce === true && mode == P.SSL_DISABLED && throw(ArgumentError("ssl_mode=:disabled contradicts ssl_enforce=true"))
        ssl_verify_server_cert === true && mode != P.SSL_VERIFY_IDENTITY && throw(ArgumentError("ssl_verify_server_cert=true contradicts ssl_mode=$(Symbol(lowercase(string(mode)[5:end])))"))
        return mode
    end
    ssl_verify_server_cert === true && return P.SSL_VERIFY_IDENTITY
    ssl_enforce === true && return P.SSL_REQUIRED
    has_ca && return P.SSL_VERIFY_CA
    return P.SSL_PREFERRED
end

# ---- option files ----

const OPTION_FILE_KEYS = Dict{String, Symbol}(
    "host" => :host, "user" => :user, "password" => :password, "port" => :port,
    "database" => :db, "connect-timeout" => :connect_timeout, "connect_timeout" => :connect_timeout,
    "ssl-ca" => :ssl_ca, "ssl_ca" => :ssl_ca, "ssl-capath" => :ssl_capath, "ssl_capath" => :ssl_capath,
    "ssl-cert" => :ssl_cert, "ssl_cert" => :ssl_cert, "ssl-key" => :ssl_key, "ssl_key" => :ssl_key,
    "ssl-mode" => :ssl_mode, "ssl_mode" => :ssl_mode, "default-character-set" => :charset_name,
    "protocol" => :protocol, "bind-address" => :bind, "bind_address" => :bind, "socket" => :unix_socket,
    "tls-version" => :tls_version,
)

"""
    default_option_files() -> Vector{String}

The client option files Oracle's clients read, minus server-only locations. `.mylogin.cnf`
(an obfuscated login-path file) is reported so it can be skipped with a warning.
"""
function default_option_files()
    if Sys.iswindows()
        windir = get(ENV, "WINDIR", "C:\\Windows")
        appdata = get(ENV, "APPDATA", homedir())
        return [joinpath(windir, "my.ini"), joinpath(windir, "my.cnf"), "C:\\my.ini", "C:\\my.cnf", joinpath(appdata, "MySQL", ".mylogin.cnf")]
    end
    return ["/etc/my.cnf", "/etc/mysql/my.cnf", joinpath(homedir(), ".my.cnf"), joinpath(homedir(), ".mylogin.cnf")]
end

function world_writable(path::String)
    Sys.iswindows() && return false
    return (filemode(path) & 0o002) != 0
end

function strip_option_comment(value::AbstractString)
    quote_char = nothing
    escaped = false
    for i in eachindex(value)
        ch = value[i]
        if escaped
            escaped = false
        elseif ch == '\\'
            escaped = true
        elseif quote_char === nothing && (ch == '"' || ch == '\'')
            quote_char = ch
        elseif quote_char == ch
            quote_char = nothing
        elseif quote_char === nothing && ch == '#'
            return strip(SubString(value, firstindex(value), prevind(value, i)))
        end
    end
    return strip(value)
end

function option_escape(ch::Char)
    ch == 'b' && return '\b'
    ch == 't' && return '\t'
    ch == 'n' && return '\n'
    ch == 'r' && return '\r'
    ch == 's' && return ' '
    ch == '\\' && return '\\'
    ch == '"' && return '"'
    ch == '\'' && return '\''
    return nothing
end

function unescape_option_value(value::AbstractString)
    out = IOBuffer()
    i = firstindex(value)
    while i <= lastindex(value)
        ch = value[i]
        if ch == '\\' && i < lastindex(value)
            j = nextind(value, i)
            escaped = value[j]
            replacement = option_escape(escaped)
            if replacement !== nothing
                write(out, replacement)
                i = nextind(value, j)
                continue
            end
        end
        write(out, ch)
        i = nextind(value, i)
    end
    return String(take!(out))
end

function parse_option_value(value::AbstractString)
    parsed = strip_option_comment(value)
    if length(parsed) >= 2 && ((parsed[1] == '"' && parsed[end] == '"') || (parsed[1] == '\'' && parsed[end] == '\''))
        parsed = parsed[2:(end - 1)]
    end
    return unescape_option_value(parsed)
end

"""
    read_option_file(path; group="client") -> Dict{Symbol, String}

Parses the `[client]` group plus `group` of a my.cnf/my.ini file. The requested group
overrides `[client]` independent of file order. `!include`/`!includedir` directives are
rejected (fail closed), and unknown keys are ignored.
"""
function read_option_file(path::AbstractString; group::AbstractString="client")
    client_opts = Dict{Symbol, String}()
    group_opts = Dict{Symbol, String}()
    current = ""
    requested_group = lowercase(group)
    for (lineno, raw) in enumerate(eachline(path))
        line = strip(raw)
        (isempty(line) || startswith(line, '#') || startswith(line, ';')) && continue
        startswith(line, '!') && throw(ArgumentError("$path:$lineno: `$(first(split(line)))` directives are not supported (fail closed)"))
        if startswith(line, '[')
            endswith(line, ']') || throw(ArgumentError("$path:$lineno: malformed group header"))
            current = lowercase(strip(line[2:(end - 1)]))
            continue
        end
        target = current == "client" ? client_opts : current == requested_group ? group_opts : nothing
        target === nothing && continue
        key, value = occursin('=', line) ? (strip(first(split(line, '='; limit=2))), strip(last(split(line, '='; limit=2)))) : (line, "")
        sym = get(OPTION_FILE_KEYS, lowercase(replace(key, '_' => '-')), nothing)
        sym === nothing && continue
        target[sym] = parse_option_value(value)
    end
    requested_group == "client" || merge!(client_opts, group_opts)
    return client_opts
end

function load_option_files(; option_file=nothing, read_default_file=nothing, option_group=nothing, read_default_group=nothing)
    group = option_group === nothing ? "client" : String(option_group)
    paths = String[]
    (read_default_file === true || read_default_group === true || (option_group !== nothing && option_file === nothing)) && append!(paths, default_option_files())
    option_file === nothing || push!(paths, String(option_file))
    merged = Dict{Symbol, String}()
    for path in paths
        if basename(path) == ".mylogin.cnf"
            @warn ".mylogin.cnf login-path files are not supported and were skipped" path maxlog=1
            continue
        end
        isfile(path) || continue
        if world_writable(path)
            @warn "ignoring world-writable option file" path maxlog=1
            continue
        end
        merge!(merged, read_option_file(path; group=group))
    end
    return merged
end

# ---- constructor ----

function client_flags(; found_rows::Bool=false, no_schema::Bool=false, ignore_space::Bool=false, multi_statements::Bool=false, local_files::Bool=false)
    flags = P.DEFAULT_CLIENT_CAPABILITIES
    found_rows && (flags |= P.CLIENT_FOUND_ROWS)
    no_schema && (flags |= P.CLIENT_NO_SCHEMA)
    ignore_space && (flags |= P.CLIENT_IGNORE_SPACE)
    multi_statements && (flags |= P.CLIENT_MULTI_STATEMENTS)
    local_files && (flags |= P.CLIENT_LOCAL_FILES)
    return flags
end

function default_attrs()
    return ["_client_name" => "MySQL.jl", "_client_version" => "2.0.0-native", "_os" => string(Sys.KERNEL), "_platform" => string(Sys.ARCH), "_pid" => string(getpid())]
end

positive_or_nothing(v, name) = v === nothing ? nothing : (v > 0 ? Int(v) : throw(ArgumentError("$name must be positive")))

"""
    ConnectOptions(host, user, password=nothing; kw...)

Validates the connection keywords (unknown ones are errors, removed ones explain why,
deprecated ones warn once), applies option files when requested, the opt-in environment
defaults (`read_env=true`: `MYSQL_TCP_PORT` fills an omitted port; `MYSQL_PWD` is never
read), and resolves the ssl conflict table.
"""
function ConnectOptions(host::AbstractString, user::AbstractString, password::Union{Nothing, AbstractString}=nothing; kw...)
    kwd = Dict{Symbol, Any}(pairs(kw))
    check_keywords(kwd)
    for (k, msg) in DEFERRED_KEYWORDS
        v = get(kwd, k, nothing)
        (v === nothing || v === false) || deferred_keyword(k)
    end
    file = load_option_files(; option_file=get(kwd, :option_file, nothing), read_default_file=get(kwd, :read_default_file, nothing), option_group=get(kwd, :option_group, nothing), read_default_group=get(kwd, :read_default_group, nothing))
    pick(k, default) = haskey(kwd, k) && kwd[k] !== nothing ? kwd[k] : haskey(file, k) ? file[k] : default
    protocol_is_tcp(pick(:protocol, nothing)) || throw(ArgumentError("only the TCP protocol is supported at the moment"))
    haskey(file, :unix_socket) && delete!(file, :unix_socket)
    host_s = String(host)
    host_s == "" && haskey(file, :host) && (host_s = file[:host])
    user_s = String(user)
    user_s == "" && haskey(file, :user) && (user_s = file[:user])
    pw = password === nothing ? (haskey(file, :password) ? file[:password] : nothing) : String(password)
    port = pick(:port, nothing)
    port === nothing && get(kwd, :read_env, false) === true && haskey(ENV, "MYSQL_TCP_PORT") && (port = ENV["MYSQL_TCP_PORT"])
    port = port === nothing ? DEFAULT_PORT : Int(port isa AbstractString ? parse(Int, port) : port)
    (port == 0) && (port = DEFAULT_PORT)
    1 <= port <= 65535 || throw(ArgumentError("port must be in 1:65535"))
    charset = pick(:charset_name, UTF8MB4)
    lowercase(String(charset)) == UTF8MB4 || throw(ArgumentError("only charset_name=\"utf8mb4\" is supported by the native backend"))
    ssl_ca = pick(:ssl_ca, nothing)
    ssl_capath = pick(:ssl_capath, nothing)
    (ssl_ca !== nothing && ssl_capath !== nothing) && throw(ArgumentError("ssl_ca and ssl_capath cannot be combined yet (Reseau takes a single trust root); pass one of them"))
    ca_file = ssl_ca !== nothing ? String(ssl_ca) : ssl_capath !== nothing ? String(ssl_capath) : nothing
    mode = resolve_ssl_mode(; ssl_mode=pick(:ssl_mode, nothing), ssl_enforce=get(kwd, :ssl_enforce, nothing), ssl_verify_server_cert=get(kwd, :ssl_verify_server_cert, nothing), has_ca=ca_file !== nothing)
    min_version, max_version = parse_tls_version(pick(:tls_version, nothing))
    tls = P.TLSOptions(; mode=mode, ca_file=ca_file, cert_file=pick(:ssl_cert, nothing), key_file=pick(:ssl_key, nothing), server_name=get(kwd, :ssl_server_name, nothing), min_version=min_version, max_version=max_version)
    default_auth = get(kwd, :default_auth, nothing)
    default_auth === nothing || P.is_supported_plugin(default_auth) || throw(P.UnsupportedAuthError(String(default_auth)))
    pubkey = get(kwd, :server_public_key, nothing)
    if pubkey === nothing
        pem = nothing
    else
        pubkey isa AbstractString || throw(ArgumentError("server_public_key must be a PEM file path"))
        isfile(pubkey) || throw(ArgumentError("server_public_key does not name a readable file: $(repr(pubkey))"))
        pem = read(pubkey)
    end
    auth = P.AuthPolicy(; server_public_key=pem, get_server_public_key=get(kwd, :get_server_public_key, false), enable_cleartext_plugin=get(kwd, :enable_cleartext_plugin, false) || default_auth == P.PLUGIN_CLEAR_PASSWORD, insecure_cleartext_auth=get(kwd, :insecure_cleartext_auth, false))
    local_files = get(kwd, :local_files, false)
    handler = get(kwd, :local_infile_handler, nothing)
    local_files && handler === nothing && throw(ArgumentError("local_files=true requires a local_infile_handler"))
    db = String(pick(:db, ""))
    flags = client_flags(; found_rows=get(kwd, :found_rows, false), no_schema=get(kwd, :no_schema, false), ignore_space=get(kwd, :ignore_space, false), multi_statements=get(kwd, :multi_statements, false), local_files=local_files)
    isempty(db) || (flags |= P.CLIENT_CONNECT_WITH_DB)
    get(kwd, :can_handle_expired_passwords, false) && (flags |= P.CLIENT_CAN_HANDLE_EXPIRED_PASSWORDS)
    limits = P.Limits(; max_packet=something(get(kwd, :max_allowed_packet, nothing), P.DEFAULT_MAX_PACKET), max_buffered_bytes=get(kwd, :max_buffered_bytes, P.DEFAULT_MAX_BUFFERED_BYTES), max_response_bytes=get(kwd, :max_response_bytes, nothing), max_columns=get(kwd, :max_columns, 4096), max_result_sets=get(kwd, :max_result_sets, 1024), max_metadata_bytes=get(kwd, :max_metadata_bytes, 16 * 1024 * 1024))
    attrs = Vector{Pair{String, String}}(get(kwd, :attrs, default_attrs()))
    ct = pick(:connect_timeout, nothing)
    ct = ct isa AbstractString ? parse(Int, ct) : ct
    max_local_infile_bytes = Int(get(kwd, :max_local_infile_bytes, 1024 * 1024 * 1024))
    max_local_infile_bytes > 0 || throw(ArgumentError("max_local_infile_bytes must be positive"))
    return ConnectOptions(host_s, port, user_s, pw, db, positive_or_nothing(ct, "connect_timeout"), positive_or_nothing(get(kwd, :read_timeout, nothing), "read_timeout"), positive_or_nothing(get(kwd, :write_timeout, nothing), "write_timeout"), pick(:bind, nothing) === nothing ? nothing : String(pick(:bind, nothing)), get(kwd, :init_command, nothing) === nothing ? nothing : String(kwd[:init_command]), something(get(kwd, :reconnect, nothing), false), flags, tls, auth, default_auth === nothing ? nothing : String(default_auth), get(kwd, :can_handle_expired_passwords, false), limits, attrs, handler, max_local_infile_bytes, get(kwd, :debug, false))
end
