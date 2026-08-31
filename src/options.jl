# Connection options: the compatibility truth table of `DBInterface.connect(MySQL.Connection, ...)`
# keywords, the ssl conflict table, option files, and the opt-in environment defaults.

const DEFAULT_PORT = 3306
const UTF8MB4 = "utf8mb4"

# Concrete box for the user-supplied `local_infile_handler` callable: the field type stays
# a 2-member concrete union so every call site is statically resolvable; only the actual
# handler invocation (`call_infile_handler`) is dynamic.
struct LocalInfileHandlerBox
    f::Any
end

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
    local_infile_handler::Union{Nothing, LocalInfileHandlerBox}
    max_local_infile_bytes::Int
    debug::Bool
    zero_dates::Symbol
    time_type::Type
end

const REMOVED_KEYWORDS = Dict{Symbol, String}(
    :charset_dir => "the native backend has no character-set files",
    :connection_handler => "the native backend has no dynamic plugins",
    :plugin_dir => "the native backend has no dynamic plugins",
)

# Reserve compatibility names that need support below the MySQL protocol layer. These are
# unavailable in 2.0, not removed from the long-term API contract.
const UNAVAILABLE_KEYWORDS = Dict{Symbol, String}(
    :ssl_cipher => "cipher selection requires transport support that Reseau does not expose yet",
    :ssl_crl => "certificate-revocation lists require transport support that Reseau does not expose yet",
    :ssl_crlpath => "certificate-revocation lists require transport support that Reseau does not expose yet",
    :passphrase => "encrypted private-key passphrases require transport support that Reseau does not expose yet",
    :compress => "the compressed-packet protocol layer is planned for a later 2.x release",
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
    :max_response_bytes, :max_columns, :max_result_sets, :max_metadata_bytes,
    :max_preauth_packet, :max_auth_rounds, :max_auth_bytes, :max_session_state_bytes,
    :debug, :attrs, :tls_version, :zero_dates, :time_type,
])

const TLS_VERSION_NAMES = Dict{String, UInt16}("tlsv1.2" => P.Reseau.TLS.TLS1_2_VERSION, "tlsv1.3" => P.Reseau.TLS.TLS1_3_VERSION)

# `tls_version="TLSv1.2,TLSv1.3"` (libmysqlclient's option): the allowed protocol versions.
# Returns `(min_version, max_version)`; `nothing` means TLS 1.2 and 1.3 are both allowed.
function parse_tls_version(spec::Union{Nothing, String})
    spec === nothing && return (nothing, nothing)
    versions = UInt16[]
    for part in split(spec, ',')
        name = lowercase(strip(part))
        isempty(name) && continue
        push!(versions, get(TLS_VERSION_NAMES, name) do
            throw(ArgumentError("unsupported tls_version $(repr(strip(part))); the native backend speaks TLSv1.2 and TLSv1.3"))
        end)
    end
    isempty(versions) && throw(ArgumentError("tls_version must name at least one of TLSv1.2, TLSv1.3"))
    return (minimum(versions), maximum(versions))
end

@noinline removed_keyword(k::Symbol) = return throw(ArgumentError("the `$k` option was removed: $(REMOVED_KEYWORDS[k])"))
@noinline unavailable_keyword(k::Symbol) = return throw(ArgumentError("the `$k` option is not available in MySQL.jl 2.0: $(UNAVAILABLE_KEYWORDS[k])"))
@noinline deferred_keyword(k::Symbol) = return throw(ArgumentError("the `$k` option is not available: $(DEFERRED_KEYWORDS[k])"))

# ---- typed option extraction ----
# Option values arrive as `Any` (a keyword Dict merged with option-file strings). Every
# extraction goes through an `@inline` converter over a closed set of accepted concrete
# types, so `--trim=safe` resolves the whole constructor statically. The accepted types are
# the documented ones: strings are `String`/`SubString{String}`, integers the standard
# machine types or their decimal string form, booleans `Bool`.

@noinline option_type_error(name::String, T::DataType) = return throw(ArgumentError("the `$name` connection option does not accept a value of type $T"))

@inline function option_string(v, name::String)::String
    v isa String && return v
    v isa SubString{String} && return String(v)
    option_type_error(name, typeof(v))
end

@inline option_string_or_nothing(v, name::String) = return v === nothing ? nothing : option_string(v, name)

@inline function option_bool(v, name::String)::Bool
    v isa Bool && return v
    option_type_error(name, typeof(v))
end

@inline option_bool_or(v, name::String, default::Bool)::Bool = return v === nothing ? default : option_bool(v, name)
@inline option_bool_or_nothing(v, name::String) = return v === nothing ? nothing : option_bool(v, name)

@noinline option_int_range_error(name::String) = return throw(ArgumentError("$name must be representable as Int"))
@noinline option_int_parse_error(name::String) = return throw(ArgumentError("$name must be an integer representable as Int"))

@inline function option_int_checked(v, name::String)::Int
    (typemin(Int) <= v <= typemax(Int)) || option_int_range_error(name)
    return v % Int
end

@inline function option_int_parsed(v::AbstractString, name::String)::Int
    parsed = tryparse(Int, v)
    parsed === nothing && option_int_parse_error(name)
    return parsed
end

function check_keywords(kw)
    for k in keys(kw)
        k in KNOWN_KEYWORDS || throw(ArgumentError("unknown connection option `$k`"))
        haskey(DEPRECATED_KEYWORDS, k) && kw[k] !== nothing && @warn "connection option `$k` is deprecated: $(DEPRECATED_KEYWORDS[k])" maxlog=1
    end
    check_keyword_availability(kw)
    return nothing
end

@inline function check_keyword_availability(k::Symbol, value)
    haskey(REMOVED_KEYWORDS, k) && value !== nothing && value !== false && removed_keyword(k)
    haskey(UNAVAILABLE_KEYWORDS, k) && value !== nothing && value !== false && unavailable_keyword(k)
    return nothing
end

function check_keyword_availability(kw)
    for k in keys(kw)
        check_keyword_availability(k, kw[k])
    end
    return nothing
end

@inline function protocol_kind(protocol)::Symbol
    protocol === nothing && return :default
    p = if protocol isa Symbol
        protocol
    elseif protocol isa String
        Symbol(lowercase(protocol))
    elseif protocol isa SubString{String}
        Symbol(lowercase(String(protocol)))
    else
        throw(ArgumentError("protocol must be the Symbol or String form of :default, :tcp, :socket, or :pipe"))
    end
    (p === :default || p === :tcp || p === :socket || p === :pipe || p === :memory) || throw(ArgumentError("unknown protocol :$p"))
    return p
end

function select_transport(host::String, protocol; named_pipe::Bool=false)
    kind = protocol_kind(protocol)
    kind == :tcp && return :tcp
    kind != :default && return kind
    named_pipe && return :pipe
    if Sys.iswindows()
        return host == "." ? :pipe : :tcp
    end
    return host == "" || host == "localhost" ? :socket : :tcp
end

function require_tcp_transport(host::String, protocol; named_pipe::Bool=false)
    transport = select_transport(host, protocol; named_pipe=named_pipe)
    transport == :tcp && return nothing
    transport == :socket && deferred_keyword(:unix_socket)
    transport == :pipe && deferred_keyword(:named_pipe)
    throw(ArgumentError("the `$transport` protocol is not available: the native backend currently supports TCP only"))
end

# ---- ssl conflict table ----

"""
    resolve_ssl_mode(; ssl_mode=nothing, ssl_enforce=nothing, ssl_verify_server_cert=nothing, has_ca=false)

An explicit `ssl_mode` wins; otherwise `ssl_verify_server_cert=true` ⇒ `:verify_identity`,
`ssl_enforce=true` ⇒ `:required`, CA material ⇒ `:verify_ca`, else `:preferred`. Explicit
`false` values never lower an explicit mode; contradictory explicit combinations are errors.
"""
@inline function resolve_ssl_mode(; ssl_mode=nothing, ssl_enforce=nothing, ssl_verify_server_cert=nothing, has_ca::Bool=false)
    if ssl_mode !== nothing
        mode = P.ssl_mode(ssl_mode)
        ssl_enforce === true && mode in (P.SSL_DISABLED, P.SSL_PREFERRED) && throw(ArgumentError("ssl_mode=$(Symbol(lowercase(string(mode)[5:end]))) contradicts ssl_enforce=true"))
        ssl_verify_server_cert === true && mode != P.SSL_VERIFY_IDENTITY && throw(ArgumentError("ssl_verify_server_cert=true contradicts ssl_mode=$(Symbol(lowercase(string(mode)[5:end])))"))
        return mode
    end
    ssl_verify_server_cert === true && return P.SSL_VERIFY_IDENTITY
    ssl_enforce === true && return P.SSL_REQUIRED
    has_ca && return P.SSL_VERIFY_CA
    return P.SSL_PREFERRED
end

# The tri-states travel as (present, value) pairs and the file mode as a ""-sentinel
# String, so every argument is concrete and the call is statically resolvable; the logic is
# `resolve_ssl_mode`'s (which stays as the kwarg-friendly public face).
function resolve_ssl_sources(file_mode::String, has_mode::Bool, mode::P.SSLMode, has_enforce::Bool, enforce::Bool, has_verify::Bool, verify::Bool, has_ca::Bool)
    if has_mode
        (has_enforce && enforce) && (mode == P.SSL_DISABLED || mode == P.SSL_PREFERRED) && ssl_mode_contradiction(mode, "ssl_enforce=true")
        (has_verify && verify) && mode != P.SSL_VERIFY_IDENTITY && ssl_verify_contradiction(mode)
        return mode
    end
    (has_verify && verify) && return P.SSL_VERIFY_IDENTITY
    if has_enforce && enforce
        fm = file_mode == "" ? P.SSL_REQUIRED : P.ssl_mode(file_mode)
        return (fm == P.SSL_VERIFY_CA || fm == P.SSL_VERIFY_IDENTITY) ? fm : P.SSL_REQUIRED
    end
    file_mode == "" || return P.ssl_mode(file_mode)
    has_ca && return P.SSL_VERIFY_CA
    return P.SSL_PREFERRED
end

@noinline ssl_mode_contradiction(mode::P.SSLMode, what::String) = return throw(ArgumentError("ssl_mode=$(Symbol(lowercase(string(mode)[5:end]))) contradicts $what"))
@noinline ssl_verify_contradiction(mode::P.SSLMode) = return throw(ArgumentError("ssl_verify_server_cert=true contradicts ssl_mode=$(Symbol(lowercase(string(mode)[5:end])))"))

# ---- option files ----

const OPTION_FILE_KEYS = Dict{String, Symbol}(
    "host" => :host, "user" => :user, "password" => :password, "port" => :port,
    "database" => :db, "connect-timeout" => :connect_timeout, "connect_timeout" => :connect_timeout,
    "compress" => :compress,
    "ssl-ca" => :ssl_ca, "ssl_ca" => :ssl_ca, "ssl-capath" => :ssl_capath, "ssl_capath" => :ssl_capath,
    "ssl-cert" => :ssl_cert, "ssl_cert" => :ssl_cert, "ssl-key" => :ssl_key, "ssl_key" => :ssl_key,
    "ssl-cipher" => :ssl_cipher, "ssl-crl" => :ssl_crl, "ssl-crlpath" => :ssl_crlpath,
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
        appdata = get(ENV, "APPDATA") do
            return homedir()
        end
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
    first = firstindex(parsed)
    last = lastindex(parsed)
    if length(parsed) >= 2 && ((parsed[first] == '"' && parsed[last] == '"') || (parsed[first] == '\'' && parsed[last] == '\''))
        parsed = SubString(parsed, nextind(parsed, first), prevind(parsed, last))
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
    return open(io -> read_option_file(io, path; group=group), path)
end

function read_option_file(io::IO, path::AbstractString; group::AbstractString="client")
    client_opts = Dict{Symbol, String}()
    group_opts = Dict{Symbol, String}()
    current = ""
    requested_group = lowercase(group)
    for (lineno, raw) in enumerate(eachline(io))
        line = strip(raw)
        (isempty(line) || startswith(line, '#') || startswith(line, ';')) && continue
        (startswith(line, '!') || startswith(lowercase(line), "?includedir")) && throw(ArgumentError("$path:$lineno: `$(first(split(line)))` directives are not supported (fail closed)"))
        if startswith(line, '[')
            endswith(line, ']') || throw(ArgumentError("$path:$lineno: malformed group header"))
            current = lowercase(strip(SubString(line, nextind(line, firstindex(line)), prevind(line, lastindex(line)))))
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

# Sentinel-concrete arguments ("" = not given) so the call is statically resolvable.
function load_option_files(option_file::String, read_default_file::Bool, option_group::String, read_default_group::Bool)
    group = option_group == "" ? "client" : option_group
    paths = String[]
    (read_default_file || read_default_group || (option_group != "" && option_file == "")) && append!(paths, default_option_files())
    option_file == "" || push!(paths, option_file)
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

# Baked at (pre)compile time: interpolating a VersionNumber at run time drags the generic
# `join`/`print` machinery into the trimmed image.
const CLIENT_VERSION_STRING = string(Base.pkgversion(@__MODULE__))
const OS_STRING = string(Sys.KERNEL)
const ARCH_STRING = string(Sys.ARCH)

function default_attrs()
    return ["_client_name" => "MySQL.jl", "_client_version" => CLIENT_VERSION_STRING, "_os" => OS_STRING, "_platform" => ARCH_STRING, "_pid" => string(getpid())]
end

const MAX_TIMEOUT_SECONDS = typemax(Int64) ÷ 1_000_000_000

@inline function option_integer(v, name::String)::Int
    v isa Int && return v
    v isa Bool && return Int(v)
    v isa Int8 && return Int(v)
    v isa UInt8 && return Int(v)
    v isa Int16 && return Int(v)
    v isa UInt16 && return Int(v)
    v isa Int32 && return Int(v)
    v isa UInt32 && return option_int_checked(v, name)
    v isa Int64 && return option_int_checked(v, name)
    v isa UInt64 && return option_int_checked(v, name)
    v isa Int128 && return option_int_checked(v, name)
    v isa UInt128 && return option_int_checked(v, name)
    v isa String && return option_int_parsed(v, name)
    v isa SubString{String} && return option_int_parsed(v, name)
    option_type_error(name, typeof(v))
end

@inline option_integer_or(v, name::String, default::Int)::Int = return v === nothing ? default : option_integer(v, name)

@inline function positive_or_nothing(v, name::String)::Union{Nothing, Int}
    v === nothing && return nothing
    value = option_integer(v, name)
    value > 0 || throw(ArgumentError("$name must be positive"))
    value <= MAX_TIMEOUT_SECONDS || throw(ArgumentError("$name is too large to represent as nanoseconds"))
    return value
end

"""
    ConnectOptions(host, user, password=nothing; kw...)

Validates the connection keywords (unknown ones are errors, removed or unavailable ones
explain why, deprecated ones warn once), applies option files when requested, the opt-in
environment defaults (`read_env=true`: `MYSQL_TCP_PORT` fills an omitted port; `MYSQL_PWD`
is never read), and resolves the ssl conflict table.
"""
function ConnectOptions(host::AbstractString, user::AbstractString, password::Union{Nothing, AbstractString}=nothing; kw...)
    kwd = Dict{Symbol, Any}(pairs(kw))
    check_keywords(kwd)
    file = load_option_files(
        something(option_string_or_nothing(get(kwd, :option_file, nothing), "option_file"), ""),
        option_bool_or(get(kwd, :read_default_file, nothing), "read_default_file", false),
        something(option_string_or_nothing(get(kwd, :option_group, nothing), "option_group"), ""),
        option_bool_or(get(kwd, :read_default_group, nothing), "read_default_group", false),
    )
    # Recognized but unavailable file options must fail closed. Silently ignoring a cipher,
    # CRL, or compression request would claim a property the connection does not have. A
    # non-`nothing` keyword still wins over the file, including `compress=false`.
    for k in keys(file)
        (haskey(kwd, k) && kwd[k] !== nothing) || check_keyword_availability(k, file[k])
    end
    # a keyword wins over the option file; `nothing` falls through
    pick(k) = return haskey(kwd, k) && kwd[k] !== nothing ? kwd[k] : get(file, k, nothing)
    host_s = String(host)
    host_s == "" && haskey(file, :host) && (host_s = file[:host])
    protocol = protocol_kind(pick(:protocol))
    named_pipe = option_bool_or(get(kwd, :named_pipe, nothing), "named_pipe", false)
    require_tcp_transport(host_s, protocol; named_pipe=named_pipe)
    isempty(host_s) && (host_s = "localhost")
    user_s = String(user)
    user_s == "" && haskey(file, :user) && (user_s = file[:user])
    pw = password === nothing ? (haskey(file, :password) ? file[:password] : nothing) : String(password)
    port_raw = pick(:port)
    if port_raw === nothing && option_bool_or(get(kwd, :read_env, nothing), "read_env", false) && haskey(ENV, "MYSQL_TCP_PORT")
        port_raw = ENV["MYSQL_TCP_PORT"]
    end
    port = port_raw === nothing ? DEFAULT_PORT : option_integer(port_raw, "port")
    (port == 0) && (port = DEFAULT_PORT)
    1 <= port <= 65535 || throw(ArgumentError("port must be in 1:65535"))
    charset_raw = pick(:charset_name)
    charset = charset_raw === nothing ? UTF8MB4 : option_string(charset_raw, "charset_name")
    lowercase(charset) == UTF8MB4 || throw(ArgumentError("only charset_name=\"utf8mb4\" is supported by the native backend"))
    ssl_ca = option_string_or_nothing(pick(:ssl_ca), "ssl_ca")
    ssl_capath = option_string_or_nothing(pick(:ssl_capath), "ssl_capath")
    (ssl_ca !== nothing && ssl_capath !== nothing) && throw(ArgumentError("ssl_ca and ssl_capath cannot be combined yet (Reseau takes a single trust root); pass one of them"))
    ca_file = ssl_ca !== nothing ? ssl_ca : ssl_capath
    ssl_mode_kw = get(kwd, :ssl_mode, nothing)
    enforce_raw = option_bool_or_nothing(get(kwd, :ssl_enforce, nothing), "ssl_enforce")
    verify_raw = option_bool_or_nothing(get(kwd, :ssl_verify_server_cert, nothing), "ssl_verify_server_cert")
    mode = resolve_ssl_sources(get(file, :ssl_mode, ""),
        ssl_mode_kw !== nothing, ssl_mode_kw === nothing ? P.SSL_PREFERRED : P.ssl_mode(ssl_mode_kw),
        enforce_raw !== nothing, enforce_raw === nothing ? false : enforce_raw,
        verify_raw !== nothing, verify_raw === nothing ? false : verify_raw,
        ca_file !== nothing)
    min_version, max_version = parse_tls_version(option_string_or_nothing(pick(:tls_version), "tls_version"))
    tls = P.TLSOptions(; mode=mode, ca_file=ca_file,
        cert_file=option_string_or_nothing(pick(:ssl_cert), "ssl_cert"),
        key_file=option_string_or_nothing(pick(:ssl_key), "ssl_key"),
        server_name=option_string_or_nothing(get(kwd, :ssl_server_name, nothing), "ssl_server_name"),
        min_version=min_version, max_version=max_version)
    default_auth = option_string_or_nothing(get(kwd, :default_auth, nothing), "default_auth")
    default_auth === nothing || P.is_supported_plugin(default_auth) || throw(P.UnsupportedAuthError(default_auth))
    pubkey = option_string_or_nothing(get(kwd, :server_public_key, nothing), "server_public_key")
    if pubkey === nothing
        pem = nothing
    else
        isfile(pubkey) || throw(ArgumentError("server_public_key does not name a readable file: $(repr(pubkey))"))
        pem = read(pubkey)
    end
    auth = P.AuthPolicy(;
        server_public_key=pem,
        get_server_public_key=option_bool_or(get(kwd, :get_server_public_key, nothing), "get_server_public_key", false),
        enable_cleartext_plugin=option_bool_or(get(kwd, :enable_cleartext_plugin, nothing), "enable_cleartext_plugin", false) || default_auth == P.PLUGIN_CLEAR_PASSWORD,
        insecure_cleartext_auth=option_bool_or(get(kwd, :insecure_cleartext_auth, nothing), "insecure_cleartext_auth", false))
    local_files = option_bool_or(get(kwd, :local_files, nothing), "local_files", false)
    handler_raw = get(kwd, :local_infile_handler, nothing)
    handler_raw === nothing || applicable(handler_raw, "") || throw(ArgumentError("local_infile_handler must be callable with a filename String"))
    local_files && handler_raw === nothing && throw(ArgumentError("local_files=true requires a local_infile_handler"))
    handler = handler_raw === nothing ? nothing : LocalInfileHandlerBox(handler_raw)
    db_raw = pick(:db)
    db = db_raw === nothing ? "" : option_string(db_raw, "db")
    flags = client_flags(;
        found_rows=option_bool_or(get(kwd, :found_rows, nothing), "found_rows", false),
        no_schema=option_bool_or(get(kwd, :no_schema, nothing), "no_schema", false),
        ignore_space=option_bool_or(get(kwd, :ignore_space, nothing), "ignore_space", false),
        multi_statements=option_bool_or(get(kwd, :multi_statements, nothing), "multi_statements", false),
        local_files=local_files)
    isempty(db) || (flags |= P.CLIENT_CONNECT_WITH_DB)
    can_expired = option_bool_or(get(kwd, :can_handle_expired_passwords, nothing), "can_handle_expired_passwords", false)
    can_expired && (flags |= P.CLIENT_CAN_HANDLE_EXPIRED_PASSWORDS)
    max_packet = option_integer_or(get(kwd, :max_allowed_packet, nothing), "max_allowed_packet", P.DEFAULT_MAX_PACKET)
    mbb_raw = get(kwd, :max_buffered_bytes, P.DEFAULT_MAX_BUFFERED_BYTES)
    mrb_raw = get(kwd, :max_response_bytes, nothing)
    limits = P.Limits(;
        max_packet=max_packet,
        max_preauth_packet=option_integer_or(get(kwd, :max_preauth_packet, nothing), "max_preauth_packet", min(P.DEFAULT_MAX_PREAUTH_PACKET, max_packet)),
        max_auth_rounds=option_integer_or(get(kwd, :max_auth_rounds, nothing), "max_auth_rounds", 8),
        max_auth_bytes=option_integer_or(get(kwd, :max_auth_bytes, nothing), "max_auth_bytes", 64 * 1024),
        max_columns=option_integer_or(get(kwd, :max_columns, nothing), "max_columns", 4096),
        max_result_sets=option_integer_or(get(kwd, :max_result_sets, nothing), "max_result_sets", 1024),
        max_metadata_bytes=option_integer_or(get(kwd, :max_metadata_bytes, nothing), "max_metadata_bytes", 16 * 1024 * 1024),
        max_buffered_bytes=mbb_raw === nothing ? nothing : option_integer(mbb_raw, "max_buffered_bytes"),
        max_response_bytes=mrb_raw === nothing ? nothing : option_integer(mrb_raw, "max_response_bytes"),
        max_session_state_bytes=option_integer_or(get(kwd, :max_session_state_bytes, nothing), "max_session_state_bytes", 1024 * 1024),
    )
    attrs_option = get(kwd, :attrs, nothing)
    attrs = attrs_option === nothing ? default_attrs() :
        attrs_option isa Vector{Pair{String, String}} ? attrs_option :
        option_type_error("attrs", typeof(attrs_option))
    max_local_infile_bytes = option_integer_or(get(kwd, :max_local_infile_bytes, nothing), "max_local_infile_bytes", 1024 * 1024 * 1024)
    max_local_infile_bytes > 0 || throw(ArgumentError("max_local_infile_bytes must be positive"))
    zd_raw = get(kwd, :zero_dates, nothing)
    zero_dates = zd_raw === nothing ? :sentinel :
        zd_raw isa Symbol ? zd_raw :
        zd_raw isa String ? Symbol(zd_raw) :
        option_type_error("zero_dates", typeof(zd_raw))
    tt_raw = get(kwd, :time_type, nothing)
    time_type = (tt_raw === nothing || tt_raw === Dates.Time) ? Dates.Time :
        tt_raw === Dates.Microsecond ? Dates.Microsecond :
        throw(ArgumentError("time_type must be Dates.Time or Dates.Microsecond"))
    results = ResultOptions(; zero_dates=zero_dates, time_type=time_type)
    ic_raw = get(kwd, :init_command, nothing)
    return ConnectOptions(
        host_s,
        port,
        user_s,
        pw,
        db,
        positive_or_nothing(pick(:connect_timeout), "connect_timeout"),
        positive_or_nothing(get(kwd, :read_timeout, nothing), "read_timeout"),
        positive_or_nothing(get(kwd, :write_timeout, nothing), "write_timeout"),
        option_string_or_nothing(pick(:bind), "bind"),
        ic_raw === nothing ? nothing : option_string(ic_raw, "init_command"),
        option_bool_or(get(kwd, :reconnect, nothing), "reconnect", false),
        flags,
        tls,
        auth,
        default_auth,
        can_expired,
        limits,
        attrs,
        handler,
        max_local_infile_bytes,
        option_bool_or(get(kwd, :debug, nothing), "debug", false),
        results.zero_dates,
        results.time_type,
    )
end
