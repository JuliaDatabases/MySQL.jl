# Precompile workload: drives the whole driver stack — greeting, authentication, the charset
# bootstrap, text and binary result sets (buffered and streaming), prepared statements, DML,
# ping, transactions, close — against a canned MySQL 8 transcript on the in-memory
# `FaultTransport{IOBuffer}` (the client's writes are discarded), so a session's first
# connect and query do not pay for compiling the driver. No sockets, tasks, or timers are
# involved (the reaper is never started); Reseau precompiles the transport paths itself.
using PrecompileTools: @setup_workload, @compile_workload

const PC_CAPS = P.DEFAULT_CLIENT_CAPABILITIES | P.CLIENT_MULTI_STATEMENTS | P.CLIENT_LOCAL_FILES

function pc_packet!(out::Vector{UInt8}, seq::Integer, payload::Vector{UInt8})
    P.write_u24!(out, length(payload))
    P.write_u8!(out, seq)
    append!(out, payload)
    return seq + 1
end

function pc_greeting()
    buf = UInt8[P.HANDSHAKE_PROTOCOL_VERSION]
    P.write_nul_string!(buf, "8.4.0")
    P.write_u32!(buf, 7)                        # connection id
    P.write_bytes!(buf, codeunits("abcdefgh")); P.write_u8!(buf, 0)   # scramble part 1, filler
    P.write_u16!(buf, PC_CAPS & 0xFFFF)
    P.write_u8!(buf, P.CHARSET_UTF8MB4_GENERAL_CI)
    P.write_u16!(buf, P.SERVER_STATUS_AUTOCOMMIT)
    P.write_u16!(buf, (PC_CAPS >> 16) & 0xFFFF)
    P.write_u8!(buf, 21)                        # auth plugin data length
    P.write_zeros!(buf, 10)
    P.write_nul_string!(buf, "ijklmnopqrst")    # scramble part 2 (12 bytes + NUL)
    P.write_nul_string!(buf, P.PLUGIN_NATIVE_PASSWORD)
    return buf
end

function pc_ok(; header::UInt8=0x00, affected::Integer=0, insert_id::Integer=0, status::Integer=P.SERVER_STATUS_AUTOCOMMIT)
    buf = UInt8[header]
    P.write_lenenc!(buf, affected)
    P.write_lenenc!(buf, insert_id)
    P.write_u16!(buf, status)
    P.write_u16!(buf, 0)
    P.write_lenenc_string!(buf, "")             # info (CLIENT_SESSION_TRACK layout)
    return buf
end

function pc_coldef(name::String, type::Integer, flags::Integer)
    buf = UInt8[]
    for s in ("def", "db", "t", "t", name, name)
        P.write_lenenc_string!(buf, s)
    end
    P.write_lenenc!(buf, 0x0C)
    P.write_u16!(buf, type == P.MYSQL_TYPE_BLOB ? P.CHARSET_BINARY : P.CHARSET_UTF8MB4_GENERAL_CI)
    P.write_u32!(buf, 255)
    P.write_u8!(buf, type)
    P.write_u16!(buf, flags)
    P.write_u8!(buf, 0)
    P.write_u16!(buf, 0)
    return buf
end

# One column of every value family the type mapping produces.
const PC_COLUMNS = (
    ("i", P.MYSQL_TYPE_LONG, P.NOT_NULL_FLAG),
    ("s", P.MYSQL_TYPE_VAR_STRING, 0x0000),
    ("f", P.MYSQL_TYPE_DOUBLE, 0x0000),
    ("dec", P.MYSQL_TYPE_NEWDECIMAL, 0x0000),
    ("dt", P.MYSQL_TYPE_DATETIME, 0x0000),
    ("d", P.MYSQL_TYPE_DATE, 0x0000),
    ("t", P.MYSQL_TYPE_TIME, 0x0000),
    ("b", P.MYSQL_TYPE_BLOB, P.BINARY_FLAG),
    ("bit", P.MYSQL_TYPE_BIT, 0x0000),
    ("big", P.MYSQL_TYPE_LONGLONG, P.UNSIGNED_FLAG),
)

const PC_TEXT_VALUES = ("1", "abc", "1.5", "12.34", "2024-02-29 13:14:15", "2024-02-29", "13:14:15", "\x01\x02", "\x05", "18446744073709551615")
const PC_BINARY_VALUES = (Int32(1), "abc", 1.5, "12.34", DateTime(2024, 2, 29, 13, 14, 15), Date(2024, 2, 29), Time(13, 14, 15), UInt8[0x01, 0x02], UInt8[0x05], typemax(UInt64))

function pc_text_row(values)
    buf = UInt8[]
    for v in values
        v === nothing ? P.write_u8!(buf, P.NULL_VALUE) : P.write_lenenc_string!(buf, v)
    end
    return buf
end

# Binary row: 0x00 header, NULL bitmap (bit offset 2), then the values in their parameter wire form.
function pc_binary_row(values)
    n = length(values)
    buf = UInt8[0x00]
    nullmap = zeros(UInt8, (n + 7 + 2) >> 3)
    for (i, v) in enumerate(values)
        v === nothing || continue
        bit = i - 1 + 2
        nullmap[(bit >> 3) + 1] |= UInt8(1) << (bit & 7)
    end
    append!(buf, nullmap)
    for v in values
        v === nothing || encode_param_value!(buf, v)
    end
    return buf
end

# A result set: column count, definitions, rows, and the DEPRECATE_EOF OK terminator.
function pc_resultset!(out::Vector{UInt8}, rows::Vector{Vector{UInt8}})
    seq = pc_packet!(out, 1, UInt8[UInt8(length(PC_COLUMNS))])
    for (name, type, flags) in PC_COLUMNS
        seq = pc_packet!(out, seq, pc_coldef(name, type, flags))
    end
    for row in rows
        seq = pc_packet!(out, seq, row)
    end
    pc_packet!(out, seq, pc_ok(; header=P.EOF_HEADER))
    return nothing
end

function pc_prepare_ok!(out::Vector{UInt8}, statement_id::Integer, nparams::Integer, with_columns::Bool)
    hdr = UInt8[0x00]
    P.write_u32!(hdr, statement_id)
    P.write_u16!(hdr, with_columns ? length(PC_COLUMNS) : 0)
    P.write_u16!(hdr, nparams)
    P.write_u8!(hdr, 0)
    P.write_u16!(hdr, 0)
    seq = pc_packet!(out, 1, hdr)
    for i in 1:nparams
        seq = pc_packet!(out, seq, pc_coldef("p$i", P.MYSQL_TYPE_VAR_STRING, 0))
    end
    with_columns || return nothing
    for (name, type, flags) in PC_COLUMNS
        seq = pc_packet!(out, seq, pc_coldef(name, type, flags))
    end
    return nothing
end

# Everything the "server" says, in the order the workload below reads it.
function pc_transcript()
    out = UInt8[]
    text_rows = [pc_text_row(PC_TEXT_VALUES), pc_text_row(("2", nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing))]
    binary_rows = [pc_binary_row(PC_BINARY_VALUES), pc_binary_row((Int32(2), nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing))]
    pc_packet!(out, 0, pc_greeting())
    pc_packet!(out, 2, pc_ok())                                  # authentication OK
    pc_packet!(out, 1, pc_ok())                                  # SET NAMES utf8mb4
    pc_resultset!(out, text_rows)                                # buffered text SELECT
    pc_resultset!(out, text_rows)                                # streaming text SELECT
    pc_packet!(out, 1, pc_ok(; affected=1, insert_id=5))         # text INSERT
    pc_prepare_ok!(out, 1, 1, true)                              # prepare SELECT ... WHERE i = ?
    pc_resultset!(out, binary_rows)                              # buffered binary execute
    pc_resultset!(out, binary_rows)                              # streaming binary execute
    pc_prepare_ok!(out, 2, 2, false)                             # one-shot INSERT (?, ?)
    pc_packet!(out, 1, pc_ok(; affected=1, insert_id=6))
    pc_packet!(out, 1, pc_ok())                                  # ping
    pc_packet!(out, 1, pc_ok(; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_IN_TRANS))   # START TRANSACTION
    pc_packet!(out, 1, pc_ok(; affected=1, status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_IN_TRANS))
    pc_packet!(out, 1, pc_ok())                                  # COMMIT
    pc_packet!(out, 1, pc_ok())                                  # MySQL.load: CREATE TABLE
    pc_packet!(out, 1, pc_ok(; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_IN_TRANS))   # START TRANSACTION
    pc_prepare_ok!(out, 3, 4, false)                             # 2-row batch INSERT (2 columns)
    pc_packet!(out, 1, pc_ok(; affected=2, status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_IN_TRANS))
    pc_prepare_ok!(out, 4, 2, false)                             # 1-row tail
    pc_packet!(out, 1, pc_ok(; affected=1, status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_IN_TRANS))
    pc_packet!(out, 1, pc_ok())                                  # COMMIT
    return out
end

# A connection over the transcript: the connection phase runs for real (greeting parsing,
# native-password scramble, HandshakeResponse41, charset bootstrap); the handle is built
# directly so no finalizer or reaper timer is registered during precompilation.
function pc_connection()
    transport = P.FaultTransport(IOBuffer(pc_transcript()); discard_writes=true)
    opts = ConnectOptions("localhost", "root", "secret"; ssl_mode=:disabled)
    s = P.Session(transport; limits=opts.limits, capabilities=opts.client_flags)
    P.read_greeting!(s)
    ok = P.authenticate!(s, opts.user, opts.password, opts.auth; db=opts.db, attrs=opts.attrs)
    bootstrapped = bootstrap_charset!(s, ok)
    h = Handle(s, opts, ReapEntry(transport), bootstrapped, Symbol[])
    return Connection(h, opts, opts.host, opts.user, opts.port, opts.db, ReentrantLock(), 1, 0, 0, 0, nothing, ResultOptions(), ReentrantLock(), nothing, true)
end

function pc_consume(cursor)
    n = 0
    for row in cursor
        n += row.i
        row.s === missing || (n += ncodeunits(row.s))
    end
    return n
end

@setup_workload begin
    @compile_workload begin
        conn = pc_connection()
        cur = DBInterface.execute(conn, "SELECT i, s, f, dec, dt, d, t, b, bit, big FROM t")
        pc_consume(cur)
        Tables.columntable(cur)
        cur = DBInterface.execute(conn, "SELECT i, s, f, dec, dt, d, t, b, bit, big FROM t"; mysql_store_result=false)
        Tables.columntable(cur)
        DBInterface.lastrowid(DBInterface.execute(conn, "INSERT INTO t (s) VALUES ('x')"))
        stmt = DBInterface.prepare(conn, "SELECT i, s, f, dec, dt, d, t, b, bit, big FROM t WHERE i = ?")
        cur = DBInterface.execute(stmt, (1,))
        pc_consume(cur)
        Tables.columntable(cur)
        Tables.columntable(DBInterface.execute(stmt, (2,); mysql_store_result=false))
        DBInterface.close!(stmt)
        DBInterface.execute(conn, "INSERT INTO t (s, i) VALUES (?, ?)", ("x", 1)).rows_affected
        ping(conn)
        DBInterface.transaction(conn) do
            DBInterface.execute(conn, "INSERT INTO t (s) VALUES ('tx')")
        end
        load([(a=1, s="x"), (a=2, s=missing), (a=3, s="z")], conn, "loaded"; batchsize=2)
        escape(conn, "a'b")
        sprint(show, conn)
        DBInterface.close!(conn)
    end
end
