# JuliaC --trim=safe workload: drives the main MySQL.jl entrypoints — connect (handshake,
# auth, charset bootstrap), text-protocol execute (buffered and streaming), prepared
# statements (binary protocol), one-shot parameterized execute, ping, escape, and close —
# against an in-process scripted server on a loopback Reseau TCP listener, so the
# executable needs no database and runs on every platform.
#
# Trim-supported consumption is the schema-typed row accessor
# (`Tables.getcolumn(row, T, i, name)`), the same call schema-aware sinks make. The
# runtime-schema conveniences (`Tables.columntable`, untyped `row.name` access, and
# `MySQL.load`) allocate columns from runtime `Type` values and are not statically
# resolvable — use them from regular Julia, not from trimmed executables.

using MySQL, DBInterface, Tables, Dates

const P = MySQL.Protocol
const TCP = P.Reseau.TCP

# ---- server-side wire helpers (mirrors test/protocol/fakepeer.jl) ----

function send_packet(conn, seq::Integer, payload::Vector{UInt8})::Nothing
    n = length(payload)
    header = UInt8[n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, seq & 0xFF]
    write(conn, vcat(header, payload))
    return nothing
end

function read_exact(conn, n::Integer)::Vector{UInt8}
    buf = Vector{UInt8}(undef, n)
    n == 0 && return buf
    GC.@preserve buf unsafe_read(conn, pointer(buf), UInt(n))
    return buf
end

function read_packet(conn)::Tuple{UInt8, Vector{UInt8}}
    h = read_exact(conn, 4)
    len = Int(h[1]) | (Int(h[2]) << 8) | (Int(h[3]) << 16)
    return h[4], read_exact(conn, len)
end

const SERVER_CAPS = P.CLIENT_LONG_PASSWORD | P.CLIENT_FOUND_ROWS | P.CLIENT_LONG_FLAG |
    P.CLIENT_CONNECT_WITH_DB | P.CLIENT_NO_SCHEMA | P.CLIENT_LOCAL_FILES |
    P.CLIENT_IGNORE_SPACE | P.CLIENT_PROTOCOL_41 | P.CLIENT_TRANSACTIONS |
    P.CLIENT_SECURE_CONNECTION | P.CLIENT_MULTI_STATEMENTS | P.CLIENT_MULTI_RESULTS |
    P.CLIENT_PS_MULTI_RESULTS | P.CLIENT_PLUGIN_AUTH | P.CLIENT_CONNECT_ATTRS |
    P.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA | P.CLIENT_SESSION_TRACK | P.CLIENT_DEPRECATE_EOF

function greeting_payload()::Vector{UInt8}
    scramble = collect(UInt8, 1:20)
    buf = UInt8[P.HANDSHAKE_PROTOCOL_VERSION]
    P.write_nul_string!(buf, "8.4.0-trim")
    P.write_u32!(buf, 7)                       # connection id
    P.write_bytes!(buf, scramble[1:8])
    P.write_u8!(buf, 0x00)
    P.write_u16!(buf, SERVER_CAPS & 0xFFFF)
    P.write_u8!(buf, 0xFF)                     # charset
    P.write_u16!(buf, 0x0002)                  # status: autocommit
    P.write_u16!(buf, (SERVER_CAPS >> 16) & 0xFFFF)
    P.write_u8!(buf, length(scramble) + 1)
    P.write_zeros!(buf, 6)
    P.write_u32!(buf, (SERVER_CAPS >> 32) % UInt32)
    P.write_bytes!(buf, scramble[9:end])
    P.write_u8!(buf, 0x00)
    P.write_nul_string!(buf, "caching_sha2_password")
    return buf
end

function ok_payload(; header::UInt8=0x00, affected::Integer=0, insert_id::Integer=0, status::Integer=0x0002)::Vector{UInt8}
    buf = UInt8[header]
    P.write_lenenc!(buf, affected)
    P.write_lenenc!(buf, insert_id)
    P.write_u16!(buf, status)
    P.write_u16!(buf, 0)                       # warnings
    return buf
end

function coldef(name::String; type::UInt8=P.MYSQL_TYPE_VAR_STRING, flags::Integer=0, charset::Integer=0x2D)::Vector{UInt8}
    buf = UInt8[]
    for s in ("def", "db", "t", "t", name, name)
        P.write_lenenc_string!(buf, s)
    end
    P.write_lenenc!(buf, 0x0C)
    P.write_u16!(buf, charset)
    P.write_u32!(buf, 255)                     # display length
    P.write_u8!(buf, type)
    P.write_u16!(buf, flags)
    P.write_u8!(buf, 0)                        # decimals
    P.write_u16!(buf, 0)
    return buf
end

# Cells arrive pre-stringified (missing = SQL NULL) so the loop is concretely typed.
function text_row(cells::Vector{Union{Missing, String}})::Vector{UInt8}
    buf = UInt8[]
    for v in cells
        v === missing ? push!(buf, 0xFB) : P.write_lenenc_string!(buf, v)
    end
    return buf
end

# The prepared-SELECT fixture has exactly (id INT, name VARCHAR) columns.
function binary_result_row(id::Int32, name::Union{Missing, String})::Vector{UInt8}
    buf = UInt8[0x00]
    null = zeros(UInt8, 1)
    name === missing && (null[1] |= UInt8(1) << 3)   # column 2 → bit offset 2 + 1
    append!(buf, null)
    MySQL.encode_param_value!(buf, id)
    name === missing || MySQL.encode_param_value!(buf, name)
    return buf
end

function send_resultset(conn, cols::Vector{Vector{UInt8}}, rows::Vector{Vector{UInt8}})::Nothing
    seq = 1
    count = UInt8[]
    P.write_lenenc!(count, length(cols))
    send_packet(conn, seq, count); seq += 1
    for c in cols
        send_packet(conn, seq, c); seq += 1
    end
    for r in rows
        send_packet(conn, seq, r); seq += 1
    end
    send_packet(conn, seq, ok_payload(; header=0xFE))
    return nothing
end

function send_prepare_ok(conn, statement_id::Integer, param_defs::Vector{Vector{UInt8}}, col_defs::Vector{Vector{UInt8}})::Nothing
    hdr = UInt8[0x00]
    P.write_u32!(hdr, statement_id)
    P.write_u16!(hdr, length(col_defs))
    P.write_u16!(hdr, length(param_defs))
    P.write_u8!(hdr, 0)
    P.write_u16!(hdr, 0)
    seq = 1
    send_packet(conn, seq, hdr); seq += 1
    for d in param_defs
        send_packet(conn, seq, d); seq += 1
    end
    for d in col_defs
        send_packet(conn, seq, d); seq += 1
    end
    return nothing
end

people_cols() = Vector{UInt8}[
    coldef("id"; type=P.MYSQL_TYPE_LONG, flags=P.NOT_NULL_FLAG, charset=63),
    coldef("name"),
    coldef("score"; type=P.MYSQL_TYPE_DOUBLE, charset=63),
    coldef("joined"; type=P.MYSQL_TYPE_DATETIME, charset=63),
]

people_rows() = Vector{UInt8}[
    text_row(Union{Missing, String}["1", "Ada", "1.5", "2024-02-29 13:14:15"]),
    text_row(Union{Missing, String}["2", "Grace", "2.5", "2023-01-02 03:04:05"]),
    text_row(Union{Missing, String}["3", missing, missing, missing]),
]

const SELECT_STMT_ID = 42
const INSERT_STMT_ID = 43

# One scripted connection: handshake + charset bootstrap, then a generic command loop.
function serve_connection!(conn)::Nothing
    send_packet(conn, 0, greeting_payload())
    seq, _ = read_packet(conn)                 # handshake response (auth ignored)
    send_packet(conn, seq + 1, ok_payload())
    while true
        local cmd
        local payload
        try
            _, payload = read_packet(conn)
        catch
            return nothing                     # client closed the transport
        end
        isempty(payload) && return nothing
        cmd = payload[1]
        if cmd == P.COM_QUIT
            return nothing
        elseif cmd == P.COM_PING
            send_packet(conn, 1, ok_payload())
        elseif cmd == P.COM_STMT_CLOSE
            # no response
        elseif cmd == P.COM_QUERY
            sql = String(payload[2:end])
            if occursin("FROM people", sql)
                send_resultset(conn, people_cols(), people_rows())
            else
                # SET NAMES, CREATE TABLE, START TRANSACTION, COMMIT, INSERT, ...
                send_packet(conn, 1, ok_payload(; affected=occursin("INSERT", sql) ? 1 : 0))
            end
        elseif cmd == P.COM_STMT_PREPARE
            sql = String(payload[2:end])
            if occursin("INSERT", sql)
                send_prepare_ok(conn, INSERT_STMT_ID, Vector{UInt8}[coldef("?"), coldef("?")], Vector{UInt8}[])
            else
                send_prepare_ok(conn, SELECT_STMT_ID, Vector{UInt8}[coldef("?")],
                    Vector{UInt8}[coldef("id"; type=P.MYSQL_TYPE_LONG, flags=P.NOT_NULL_FLAG, charset=63), coldef("name")])
            end
        elseif cmd == P.COM_STMT_EXECUTE
            stmt_id = Int(payload[2]) | (Int(payload[3]) << 8) | (Int(payload[4]) << 16) | (Int(payload[5]) << 24)
            if stmt_id == SELECT_STMT_ID
                send_resultset(conn,
                    Vector{UInt8}[coldef("id"; type=P.MYSQL_TYPE_LONG, flags=P.NOT_NULL_FLAG, charset=63), coldef("name")],
                    Vector{UInt8}[binary_result_row(Int32(17), "Jane"), binary_result_row(Int32(18), missing)])
            else
                send_packet(conn, 1, ok_payload(; affected=1, insert_id=1))
            end
        else
            error("unexpected command byte $cmd")
        end
    end
end

# ---- the client workload ----

function check(cond::Bool, what::String)::Nothing
    cond || error("workload check failed: $what")
    return nothing
end

function run_workload(port::Int)::Nothing
    # no connect_timeout: Reseau's deadline-armed dial waits on timer machinery that a
    # trimmed build does not carry (its own trim suite only exercises pre-expired
    # deadlines); the scripted loopback peer answers immediately anyway
    conn = DBInterface.connect(MySQL.Connection, "127.0.0.1", "root", "secret"; port=port, ssl_mode=:disabled)
    try
        check(isopen(conn)::Bool, "connection is open")
        check(occursin("MySQL.Connection", sprint(show, conn)), "show(conn)")

        # buffered text protocol, consumed through the schema-typed accessor
        cursor = DBInterface.execute(conn, "SELECT id, name, score, joined FROM people")::MySQL.TextCursor{true}
        check(length(cursor) == 3, "buffered cursor length")
        ids = Int32[]
        names = Union{Missing, String}[]
        scores = Union{Missing, Float64}[]
        joineds = Union{Missing, DateTime}[]
        for row in cursor
            push!(ids, Tables.getcolumn(row, Int32, 1, :id))
            push!(names, Tables.getcolumn(row, Union{Missing, String}, 2, :name))
            push!(scores, Tables.getcolumn(row, Union{Missing, Float64}, 3, :score))
            push!(joineds, Tables.getcolumn(row, Union{Missing, DateTime}, 4, :joined))
        end
        check(ids == Int32[1, 2, 3], "text id column")
        check(isequal(names, Union{Missing, String}["Ada", "Grace", missing]), "text name column")
        check(isequal(scores, Union{Missing, Float64}[1.5, 2.5, missing]), "text score column")
        check(isequal(joineds, Union{Missing, DateTime}[DateTime(2024, 2, 29, 13, 14, 15), DateTime(2023, 1, 2, 3, 4, 5), missing]), "text datetime column")

        # streaming text protocol
        n = 0
        total = 0
        for row in DBInterface.execute(conn, "SELECT id, name, score, joined FROM people"; mysql_store_result=false)::MySQL.TextCursor{false}
            n += 1
            total += Int(Tables.getcolumn(row, Int32, 1, :id))
        end
        check(n == 3 && total == 6, "streaming rows")

        # prepared statement (binary protocol)
        stmt = DBInterface.prepare(conn, "SELECT id, name FROM people WHERE id = ?")
        bids = Int32[]
        bnames = Union{Missing, String}[]
        for row in DBInterface.execute(stmt, (17,))::MySQL.BinaryCursor{true}
            push!(bids, Tables.getcolumn(row, Int32, 1, :id))
            push!(bnames, Tables.getcolumn(row, Union{Missing, String}, 2, :name))
        end
        check(bids == Int32[17, 18], "binary id column")
        check(isequal(bnames, Union{Missing, String}["Jane", missing]), "binary name column")
        DBInterface.close!(stmt)

        # one-shot parameterized execute (prepare + execute + parked close)
        oids = Int32[]
        for row in DBInterface.execute(conn, "SELECT id, name FROM people WHERE id = ?", (17,))::MySQL.BinaryCursor{true}
            push!(oids, Tables.getcolumn(row, Int32, 1, :id))
        end
        check(oids == Int32[17, 18], "one-shot execute")

        # simple commands and escaping
        check(MySQL.ping(conn), "ping")
        check(MySQL.escape(conn, "a'b") == "a\\'b", "escape")
        check(MySQL.escape_identifier("weird`name") == "`weird``name`", "escape_identifier")
    finally
        DBInterface.close!(conn)
    end
    check(!(isopen(conn)::Bool), "connection closed")
    return nothing
end

# Task bodies must be named zero-argument functions (registered via
# `Base.Experimental.entrypoint`), not closures: `juliac --trim` does not trace dynamic
# task invocation, so a closure's call method would be trimmed out of the executable.
const SERVER_LISTENER = Ref{Union{Nothing, TCP.Listener}}(nothing)
const SERVER_ERROR = Ref{Any}(nothing)

function server_task_entry()::Nothing
    conn = nothing
    try
        conn = TCP.accept(SERVER_LISTENER[]::TCP.Listener)
        serve_connection!(conn)
    catch err
        SERVER_ERROR[] = err
    finally
        conn === nothing || close(conn)
    end
    return nothing
end

Base.Experimental.entrypoint(server_task_entry, ())

function run_trim_workload()::Nothing
    listener = TCP.listen(TCP.loopback_addr(0))
    laddr = TCP.addr(listener)::TCP.SocketAddrV4
    port = Int(laddr.port)
    SERVER_LISTENER[] = listener
    SERVER_ERROR[] = nothing
    server_task = Task(server_task_entry)
    schedule(server_task)
    try
        run_workload(port)
    finally
        close(listener)
        wait(server_task)
        SERVER_LISTENER[] = nothing
    end
    SERVER_ERROR[] === nothing || throw(SERVER_ERROR[])
    return nothing
end

function (@main)(args::Vector{String})::Cint
    _ = args
    run_trim_workload()
    Core.println("mysql trim workload passed")
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
