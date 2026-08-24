# Deterministic mutation fuzzer over protocol transcripts (plan §8.4).
#
# Seed transcripts (server → client byte streams, vendor examples plus synthetic frames)
# are mutated by a seeded SplitMix64 generator and fed to the real packet reader, response
# classifiers, row scanners, value decoders and the handshake/auth parsers through an
# in-memory transport. The contract under test: any malformed stream must surface as a
# `Protocol.MySQLError` (`ProtocolError`, `ConversionError`, `Error`, …) — never a
# segfault, `BoundsError`, out-of-bounds read, or hang. Everything is reproducible from
# `(entry name, seed)` alone.
#
# Used two ways:
#   - `test/protocol/fuzz_tests.jl` runs a bounded in-process smoke batch in the suite
#   - `scripts/fuzz.jl` runs large batches in isolated worker processes (nightly budget)
module Fuzz

using MySQL, Dates, Logging

const P = MySQL.Protocol
const N = MySQL

# Reuse the vendor golden vectors already loaded by the protocol suite. The standalone
# worker includes their small fixture modules itself.
const VendorVectors = if isdefined(parentmodule(@__MODULE__), :Vectors)
    getfield(parentmodule(@__MODULE__), :Vectors)
else
    include("fakepeer.jl")
    include("vectors.jl")
    Vectors
end

# ---- deterministic generator (SplitMix64; independent of Julia's RNG stream) ----

mutable struct Rng
    state::UInt64
end

function next!(r::Rng)
    r.state += 0x9e3779b97f4a7c15
    z = r.state
    z = (z ⊻ (z >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ⊻ (z >> 27)) * 0x94d049bb133111eb
    return z ⊻ (z >> 31)
end

# Uniform integer in 1:n.
randint(r::Rng, n::Int) = Int(next!(r) % UInt64(n)) + 1

randbyte(r::Rng) = UInt8(next!(r) % 256)

# ---- corpus ----

# `expect` for the unmutated stream: :clean (must complete without any exception),
# :server_error (a ServerError is expected), or :protocol_error (a documented rejection).
struct CorpusEntry
    name::String
    flow::Symbol            # :connect | :query | :prepare | :execute | :scan_text | :scan_binary
    caps::UInt64
    bytes::Vector{UInt8}
    expect::Symbol
end

# Frames one logical packet (splitting at 0xFFFFFF is not needed for corpus sizes).
function frame!(out::Vector{UInt8}, seq::Integer, payload::Vector{UInt8})
    P.write_u24!(out, length(payload))
    P.write_u8!(out, seq)
    append!(out, payload)
    return seq + 1
end

function ok_payload(; header::UInt8=0x00, affected::Integer=0, insert_id::Integer=0, status::Integer=P.SERVER_STATUS_AUTOCOMMIT, warnings::Integer=0, info::String="", track::Bool=false, state::Vector{UInt8}=UInt8[])
    buf = UInt8[header]
    P.write_lenenc!(buf, affected)
    P.write_lenenc!(buf, insert_id)
    P.write_u16!(buf, status)
    P.write_u16!(buf, warnings)
    if track
        P.write_lenenc_string!(buf, info)
        isempty(state) || append!(buf, state)
    else
        append!(buf, codeunits(info))
    end
    return buf
end

function eof_payload(; status::Integer=P.SERVER_STATUS_AUTOCOMMIT, warnings::Integer=0)
    buf = UInt8[0xFE]
    P.write_u16!(buf, warnings)
    P.write_u16!(buf, status)
    return buf
end

function err_payload(code::Integer, msg::String; sqlstate::String="HY000")
    buf = UInt8[0xFF]
    P.write_u16!(buf, code)
    push!(buf, P.SQLSTATE_MARKER)
    append!(buf, codeunits(sqlstate))
    append!(buf, codeunits(msg))
    return buf
end

function coldef_payload(name::String; type::Integer=P.MYSQL_TYPE_VAR_STRING, flags::Integer=0, decimals::Integer=0, charset::Integer=P.CHARSET_UTF8MB4_GENERAL_CI, length::Integer=255)
    buf = UInt8[]
    for s in ("def", "db", "t", "t", name, name)
        P.write_lenenc_string!(buf, s)
    end
    P.write_lenenc!(buf, 0x0C)
    P.write_u16!(buf, charset)
    P.write_u32!(buf, length)
    P.write_u8!(buf, type)
    P.write_u16!(buf, flags)
    P.write_u8!(buf, decimals)
    P.write_u16!(buf, 0)
    return buf
end

# Session-state block: one SYSTEM_VARIABLES change (autocommit=ON).
function session_state_bytes()
    inner = UInt8[]
    P.write_lenenc_string!(inner, "autocommit")
    P.write_lenenc_string!(inner, "ON")
    block = UInt8[]
    P.write_u8!(block, 0x00)
    P.write_lenenc_bytes!(block, inner)
    buf = UInt8[]
    P.write_lenenc_bytes!(buf, block)
    return buf
end

function text_value!(buf::Vector{UInt8}, v::Union{Nothing, String})
    v === nothing ? P.write_u8!(buf, P.NULL_VALUE) : P.write_lenenc_string!(buf, v)
    return nothing
end

function text_row(values::Vector{Union{Nothing, String}})
    buf = UInt8[]
    foreach(v -> text_value!(buf, v), values)
    return buf
end

# HandshakeV10 greeting with MySQL-8-style capabilities.
function greeting_payload(; caps::UInt64=MYSQL8_GREETING_CAPS, version::String="8.4.0", plugin::String=P.PLUGIN_NATIVE_PASSWORD)
    buf = UInt8[P.HANDSHAKE_PROTOCOL_VERSION]
    append!(buf, codeunits(version))
    push!(buf, 0x00)
    P.write_u32!(buf, 7)                       # connection id
    append!(buf, UInt8['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'])
    push!(buf, 0x00)
    P.write_u16!(buf, caps & 0xFFFF)
    P.write_u8!(buf, P.CHARSET_UTF8MB4_GENERAL_CI)
    P.write_u16!(buf, P.SERVER_STATUS_AUTOCOMMIT)
    P.write_u16!(buf, (caps >> 16) & 0xFFFF)
    P.write_u8!(buf, 21)                       # auth plugin data length
    append!(buf, zeros(UInt8, 10))             # reserved
    append!(buf, UInt8['i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't'])
    push!(buf, 0x00)                           # scramble part 2 (12 + NUL = 13)
    append!(buf, codeunits(plugin))
    push!(buf, 0x00)
    return buf
end

const MYSQL8_GREETING_CAPS = P.CLIENT_LONG_PASSWORD | P.CLIENT_LONG_FLAG | P.CLIENT_PROTOCOL_41 |
    P.CLIENT_TRANSACTIONS | P.CLIENT_SECURE_CONNECTION | P.CLIENT_PLUGIN_AUTH |
    P.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA | P.CLIENT_CONNECT_ATTRS | P.CLIENT_SESSION_TRACK |
    P.CLIENT_DEPRECATE_EOF | P.CLIENT_MULTI_RESULTS | P.CLIENT_PS_MULTI_RESULTS |
    P.CLIENT_LOCAL_FILES | P.CLIENT_MULTI_STATEMENTS

const CAPS_MODERN = P.DEFAULT_CLIENT_CAPABILITIES
const CAPS_LEGACY = CAPS_MODERN & ~(P.CLIENT_DEPRECATE_EOF | P.CLIENT_SESSION_TRACK)
const CAPS_INFILE = CAPS_MODERN | P.CLIENT_LOCAL_FILES

const TYPED_COLUMNS = [
    ("i", P.MYSQL_TYPE_LONG, P.NOT_NULL_FLAG),
    ("u", P.MYSQL_TYPE_LONGLONG, P.UNSIGNED_FLAG),
    ("f", P.MYSQL_TYPE_DOUBLE, 0),
    ("dec", P.MYSQL_TYPE_NEWDECIMAL, 0),
    ("s", P.MYSQL_TYPE_VAR_STRING, 0),
    ("b", P.MYSQL_TYPE_BLOB, P.BINARY_FLAG),
    ("bit", P.MYSQL_TYPE_BIT, P.UNSIGNED_FLAG),
    ("dt", P.MYSQL_TYPE_DATETIME, 0),
    ("da", P.MYSQL_TYPE_DATE, 0),
    ("tm", P.MYSQL_TYPE_TIME, 0),
    ("y", P.MYSQL_TYPE_YEAR, P.UNSIGNED_FLAG),
]

const TYPED_TEXT_VALUES = Union{Nothing, String}[
    "-2147483648", "18446744073709551615", "3.25", "12.345", "héllo", "\x00\xff", "\x01\x02",
    "2024-02-29 13:14:15.250000", "2024-02-29", "-100:30:15.5", "2024",
]

function typed_coldefs()
    return [coldef_payload(name; type=t, flags=f) for (name, t, f) in TYPED_COLUMNS]
end

function text_resultset_stream(; deprecate_eof::Bool, more::Bool=false, terminator_state::Bool=false)
    out = UInt8[]
    seq = 1
    cols = typed_coldefs()
    count = UInt8[]
    P.write_lenenc!(count, length(cols))
    seq = frame!(out, seq, count)
    for c in cols
        seq = frame!(out, seq, c)
    end
    deprecate_eof || (seq = frame!(out, seq, eof_payload()))
    seq = frame!(out, seq, text_row(TYPED_TEXT_VALUES))
    seq = frame!(out, seq, text_row(Union{Nothing, String}[nothing for _ in TYPED_COLUMNS]))
    status = more ? P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_MORE_RESULTS_EXISTS : P.SERVER_STATUS_AUTOCOMMIT
    if deprecate_eof
        state = terminator_state ? session_state_bytes() : UInt8[]
        st = terminator_state ? status | P.SERVER_SESSION_STATE_CHANGED : status
        seq = frame!(out, seq, ok_payload(; header=0xFE, status=st, track=true, state=state))
    else
        seq = frame!(out, seq, eof_payload(; status=status))
    end
    return out, seq
end

function multi_result_stream()
    out, seq = text_resultset_stream(; deprecate_eof=true, more=true)
    seq = frame!(out, seq, ok_payload(; affected=3, insert_id=7, status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_MORE_RESULTS_EXISTS, track=true))
    second, _ = text_resultset_stream(; deprecate_eof=true)
    # renumber the second result's frames to continue the sequence
    append!(out, renumber(second, seq))
    return out
end

# Rewrites the sequence ids of a framed stream to continue from `seq0`.
function renumber(stream::Vector{UInt8}, seq0::Integer)
    out = copy(stream)
    i = 1
    seq = seq0
    while i + 3 <= length(out)
        len = Int(out[i]) | (Int(out[i + 1]) << 8) | (Int(out[i + 2]) << 16)
        out[i + 3] = UInt8(seq & 0xFF)
        seq += 1
        i += 4 + len
    end
    return out
end

function infile_stream()
    out = UInt8[]
    seq = 1
    req = UInt8[P.LOCAL_INFILE_HEADER]
    append!(req, codeunits("data.csv"))
    seq = frame!(out, seq, req)
    # client sends the upload (1 data packet + empty terminator): seq advances by 2
    seq += 2
    frame!(out, seq, ok_payload(; affected=1, track=true))
    return out
end

function connect_stream(; plugin_switch::Bool)
    out = UInt8[]
    seq = 0
    seq = frame!(out, seq, greeting_payload())
    seq += 1   # client HandshakeResponse41
    if plugin_switch
        switch = UInt8[P.AUTH_SWITCH_HEADER]
        append!(switch, codeunits(P.PLUGIN_NATIVE_PASSWORD))
        push!(switch, 0x00)
        append!(switch, codeunits("abcdefghijklmnopqrst"))
        seq = frame!(out, seq, switch)
        seq += 1   # client AuthSwitchResponse
    end
    frame!(out, seq, ok_payload(; track=true, info="", state=UInt8[]))
    return out
end

function prepare_execute_stream(; deprecate_eof::Bool, nparams::Int=2)
    out = UInt8[]
    seq = 1
    header = UInt8[0x00]
    P.write_u32!(header, 1)                    # statement id
    P.write_u16!(header, length(TYPED_COLUMNS))
    P.write_u16!(header, nparams)
    P.write_u8!(header, 0x00)
    P.write_u16!(header, 0)                    # warnings
    seq = frame!(out, seq, header)
    for i in 1:nparams
        seq = frame!(out, seq, coldef_payload("?"; type=P.MYSQL_TYPE_VAR_STRING, charset=P.CHARSET_BINARY))
    end
    (nparams > 0 && !deprecate_eof) && (seq = frame!(out, seq, eof_payload()))
    for c in typed_coldefs()
        seq = frame!(out, seq, c)
    end
    deprecate_eof || (seq = frame!(out, seq, eof_payload()))
    # COM_STMT_EXECUTE response: same columns, binary rows
    seq = 1
    count = UInt8[]
    P.write_lenenc!(count, length(TYPED_COLUMNS))
    seq = frame!(out, seq, count)
    for c in typed_coldefs()
        seq = frame!(out, seq, c)
    end
    deprecate_eof || (seq = frame!(out, seq, eof_payload()))
    seq = frame!(out, seq, binary_row_full())
    seq = frame!(out, seq, binary_row_nulls())
    seq = frame!(out, seq, binary_row_short_temporals())
    if deprecate_eof
        frame!(out, seq, ok_payload(; header=0xFE, track=true))
    else
        frame!(out, seq, eof_payload())
    end
    return out
end

# One binary row for TYPED_COLUMNS with every value present.
function binary_row_full()
    buf = UInt8[0x00]
    append!(buf, zeros(UInt8, (length(TYPED_COLUMNS) + 7 + 2) >> 3))
    P.write_u32!(buf, 0x80000000)              # i (LONG)
    append!(buf, reinterpret(UInt8, [0xFFFFFFFFFFFFFFFF % UInt64]))   # u
    append!(buf, reinterpret(UInt8, [3.25]))   # f (DOUBLE)
    P.write_lenenc_string!(buf, "12.345")      # dec
    P.write_lenenc_string!(buf, "héllo")       # s
    P.write_lenenc_bytes!(buf, UInt8[0x00, 0xFF])   # b
    P.write_lenenc_bytes!(buf, UInt8[0x01, 0x02])   # bit
    P.write_u8!(buf, 11)                       # dt: DATETIME len 11
    P.write_u16!(buf, 2024); P.write_u8!(buf, 2); P.write_u8!(buf, 29)
    P.write_u8!(buf, 13); P.write_u8!(buf, 14); P.write_u8!(buf, 15)
    P.write_u32!(buf, 250000)
    P.write_u8!(buf, 4)                        # da: DATE len 4
    P.write_u16!(buf, 2024); P.write_u8!(buf, 2); P.write_u8!(buf, 29)
    P.write_u8!(buf, 12)                       # tm: TIME len 12 (negative, 4 days)
    P.write_u8!(buf, 1); P.write_u32!(buf, 4)
    P.write_u8!(buf, 4); P.write_u8!(buf, 30); P.write_u8!(buf, 15)
    P.write_u32!(buf, 500000)
    P.write_u16!(buf, 2024)                    # y (YEAR)
    return buf
end

function binary_row_nulls()
    buf = UInt8[0x00]
    nullbytes = zeros(UInt8, (length(TYPED_COLUMNS) + 7 + 2) >> 3)
    for i in 1:length(TYPED_COLUMNS)
        bit = i - 1 + 2
        nullbytes[1 + (bit >> 3)] |= UInt8(1) << (bit & 7)
    end
    append!(buf, nullbytes)
    return buf
end

# Zero-length temporals and TIME len 8 exercise the remaining self-describing widths.
function binary_row_short_temporals()
    buf = UInt8[0x00]
    nullbytes = zeros(UInt8, (length(TYPED_COLUMNS) + 7 + 2) >> 3)
    for i in 1:7   # NULL the non-temporal columns
        bit = i - 1 + 2
        nullbytes[1 + (bit >> 3)] |= UInt8(1) << (bit & 7)
    end
    append!(buf, nullbytes)
    P.write_u8!(buf, 0)                        # dt len 0 (zero datetime)
    P.write_u8!(buf, 0)                        # da len 0 (zero date)
    P.write_u8!(buf, 8)                        # tm: TIME len 8
    P.write_u8!(buf, 0); P.write_u32!(buf, 0)
    P.write_u8!(buf, 3); P.write_u8!(buf, 4); P.write_u8!(buf, 5)
    P.write_u16!(buf, 1999)                    # y
    return buf
end

function err_stream(code::Integer, msg::String; seq::Integer=1)
    out = UInt8[]
    frame!(out, seq, err_payload(code, msg))
    return out
end

function err_mid_rows_stream()
    out = UInt8[]
    seq = 1
    cols = typed_coldefs()
    count = UInt8[]
    P.write_lenenc!(count, length(cols))
    seq = frame!(out, seq, count)
    for c in cols
        seq = frame!(out, seq, c)
    end
    seq = frame!(out, seq, text_row(TYPED_TEXT_VALUES))
    frame!(out, seq, err_payload(P.ER_QUERY_INTERRUPTED, "interrupted"))
    return out
end

function build_corpus()
    corpus = CorpusEntry[]
    # The documented 5.5.2 greeting lacks CLIENT_PLUGIN_AUTH. The native backend requires
    # that capability, so its clean corpus outcome is a deliberate ProtocolError.
    push!(corpus, CorpusEntry("vendor/connect-5.5.2", :connect, CAPS_LEGACY, copy(VendorVectors.HANDSHAKE_V10_552), :protocol_error))
    push!(corpus, CorpusEntry("connect/plain", :connect, CAPS_MODERN, connect_stream(; plugin_switch=false), :clean))
    push!(corpus, CorpusEntry("connect/auth-switch", :connect, CAPS_MODERN, connect_stream(; plugin_switch=true), :clean))
    push!(corpus, CorpusEntry("connect/initial-err", :connect, CAPS_MODERN, err_stream(1040, "Too many connections"; seq=0), :server_error))
    stream, _ = text_resultset_stream(; deprecate_eof=true, terminator_state=true)
    push!(corpus, CorpusEntry("query/text-deprecate-eof", :query, CAPS_MODERN, stream, :clean))
    stream, _ = text_resultset_stream(; deprecate_eof=false)
    push!(corpus, CorpusEntry("query/text-legacy-eof", :query, CAPS_LEGACY, stream, :clean))
    push!(corpus, CorpusEntry("vendor/query-text", :query, CAPS_LEGACY, copy(VendorVectors.TEXT_RESULTSET_REPEAT_A), :clean))
    push!(corpus, CorpusEntry("vendor/query-call-multi", :query, CAPS_LEGACY, copy(VendorVectors.CALL_MULTI_RESULTSET), :clean))
    push!(corpus, CorpusEntry("vendor/execute-binary", :execute, CAPS_LEGACY, copy(VendorVectors.BINARY_RESULTSET_FOOBAR), :clean))
    push!(corpus, CorpusEntry("query/multi-result", :query, CAPS_MODERN, multi_result_stream(), :clean))
    push!(corpus, CorpusEntry("vendor/query-err", :query, CAPS_MODERN, copy(VendorVectors.ERR_EXAMPLE), :server_error))
    push!(corpus, CorpusEntry("query/err", :query, CAPS_MODERN, err_stream(1064, "You have an error in your SQL syntax"), :server_error))
    push!(corpus, CorpusEntry("query/err-mid-rows", :query, CAPS_MODERN, err_mid_rows_stream(), :server_error))
    push!(corpus, CorpusEntry("query/local-infile", :query, CAPS_INFILE, infile_stream(), :clean))
    push!(corpus, CorpusEntry("prepare/deprecate-eof", :prepare, CAPS_MODERN, prepare_execute_stream(; deprecate_eof=true), :clean))
    push!(corpus, CorpusEntry("prepare/legacy-eof", :prepare, CAPS_LEGACY, prepare_execute_stream(; deprecate_eof=false), :clean))
    push!(corpus, CorpusEntry("prepare/err", :prepare, CAPS_MODERN, err_stream(1064, "syntax"), :server_error))
    push!(corpus, CorpusEntry("scan/text-row", :scan_text, CAPS_MODERN, text_row(TYPED_TEXT_VALUES), :clean))
    push!(corpus, CorpusEntry("scan/binary-row", :scan_binary, CAPS_MODERN, binary_row_full(), :clean))
    return corpus
end

const CORPUS = build_corpus()

# ---- mutation ----

const INTERESTING = UInt8[0x00, 0x01, 0x02, 0x03, 0x04, 0x07, 0x08, 0x0B, 0x0C, 0x10, 0x7F, 0x80, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF]

function mutate(data::Vector{UInt8}, rng::Rng)
    out = copy(data)
    for _ in 1:randint(rng, 4)
        isempty(out) && break
        kind = randint(rng, 8)
        if kind == 1
            i = randint(rng, length(out))
            out[i] ⊻= UInt8(1) << (randint(rng, 8) - 1)
        elseif kind == 2
            out[randint(rng, length(out))] = INTERESTING[randint(rng, length(INTERESTING))]
        elseif kind == 3
            out[randint(rng, length(out))] = randbyte(rng)
        elseif kind == 4
            resize!(out, randint(rng, length(out)) - 1)
        elseif kind == 5
            lo = randint(rng, length(out))
            hi = min(length(out), lo + randint(rng, 16) - 1)
            deleteat!(out, lo:hi)
        elseif kind == 6 && length(out) < length(data) + 64
            at = randint(rng, length(out) + 1) - 1
            ins = [randbyte(rng) for _ in 1:randint(rng, 8)]
            out = vcat(out[1:at], ins, out[(at + 1):end])
        elseif kind == 7
            # splat a plausible small length over 1–3 bytes (targets length prefixes)
            i = randint(rng, length(out))
            v = UInt64(randint(rng, 300)) - 1
            for k in 0:(randint(rng, 3) - 1)
                i + k <= length(out) || break
                out[i + k] = UInt8((v >> (8 * k)) & 0xFF)
            end
        else
            lo = randint(rng, length(out))
            hi = min(length(out), lo + randint(rng, 8) - 1)
            fill!(view(out, lo:hi), 0x00)
        end
    end
    return out
end

# ---- driving the parsers ----

# Tight limits keep a mutated declared length from asking for large allocations.
fuzz_limits() = P.Limits(; max_packet=1 << 20, max_columns=128, max_result_sets=16, max_metadata_bytes=1 << 20, max_auth_bytes=4096)

function fake_server_info(caps::UInt64)
    return P.ServerInfo(0x0A, "8.4.0", v"8.4.0", :mysql, UInt32(7), caps | P.REQUIRED_SERVER_CAPABILITIES, P.CHARSET_UTF8MB4_GENERAL_CI, UInt16(P.SERVER_STATUS_AUTOCOMMIT), P.PLUGIN_NATIVE_PASSWORD, zeros(UInt8, 20))
end

function session_for(entry::CorpusEntry, data::Vector{UInt8})
    # reads come from the (mutated) server stream; writes are counted and discarded
    s = P.Session(P.FaultTransport(IOBuffer(copy(data)); discard_writes=true); capabilities=entry.caps, limits=fuzz_limits())
    if entry.flow != :connect
        s.server = fake_server_info(entry.caps)
        s.phase = P.READY
        s.authenticated = true
    end
    return s
end

function drive_connect!(s::P.Session)
    P.read_greeting!(s)
    P.send_handshake_response!(s, "root", zeros(UInt8, 20), P.PLUGIN_NATIVE_PASSWORD)
    auth_bytes = 0
    for round in 1:(s.limits.max_auth_rounds + 1)
        pkt = P.read_auth_packet!(s, round, auth_bytes)
        kind = pkt.kind
        kind == :ok && return nothing
        payload = pkt.data
        auth_bytes += length(payload)
        P.send_auth_data!(s, zeros(UInt8, 20))
    end
    return nothing
end

# Decode exceptions must be MySQLErrors; they do not end the scan (production decodes
# lazily per `getcolumn` and the session stays usable).
function decode_one(binary::Bool, T::Type, buf::Vector{UInt8}, off::Int, len::Int, opts::N.ResultOptions; accept_conversion::Bool=true)
    try
        binary ? N.decode_binary(T, buf, off, len, opts) : N.decode(T, buf, off, len, opts)
    catch err
        err isa P.MySQLError || rethrow()
        accept_conversion || rethrow()
    end
    return nothing
end

function consume_response!(s::P.Session, binary::Bool)
    opts = N.DEFAULT_RESULT_OPTIONS
    resp = P.read_command_response!(s; kind=binary ? P.CMD_STMT_EXECUTE : P.CMD_QUERY)
    offsets = Int[]
    lengths = Int[]
    for _ in 1:(s.limits.max_result_sets + 1)
        if resp isa P.LocalInfileRequest
            resp = upload_infile!(s)
            continue
        end
        if resp isa P.ResultHeader
            resp = consume_rows!(s, resp, binary, opts, offsets, lengths)
        end
        more = resp isa P.ResultEnd ? resp.more_results :
            resp isa P.OKPacket ? P.more_results(resp) :
            resp isa P.EOFPacket ? P.more_results(resp) : false
        more || return nothing
        resp = P.next_result!(s)
    end
    return nothing
end

function upload_infile!(s::P.Session)
    P.send_local_infile!(s, IOBuffer(b"a,b\nc,d\n"))
    return P.read_command_response!(s)
end

function consume_rows!(s::P.Session, header::P.ResultHeader, binary::Bool, opts::N.ResultOptions, offsets::Vector{Int}, lengths::Vector{Int})
    types = Type[N.juliatype(col, opts) for col in header.columns]
    coltypes = UInt8[col.type for col in header.columns]
    while true
        r = P.read_row!(s)
        r isa P.ResultEnd && return r
        if binary
            P.guarded(() -> P.scan_binary_row!(coltypes, r, offsets, lengths), s)
        else
            P.guarded(() -> P.scan_text_row!(r, length(coltypes), offsets, lengths), s)
        end
        for i in 1:length(coltypes)
            decode_one(binary, types[i], r.buf, offsets[i], lengths[i], opts)
        end
    end
end

function drive_prepare!(s::P.Session)
    P.stmt_prepare!(s, "SELECT ?, ?")
    ok = P.read_prepare_response!(s)
    nparams = length(ok.params)
    block = UInt8[]
    if nparams > 0
        params = ntuple(i -> Int64(i), nparams)
        block = N.encode_param_block(params, N.param_signature(params), true)
    end
    P.stmt_execute!(s, ok.statement_id, block)
    consume_response!(s, true)
    return nothing
end

const BINARY_TYPE_POOL = UInt8[
    P.MYSQL_TYPE_TINY, P.MYSQL_TYPE_SHORT, P.MYSQL_TYPE_LONG, P.MYSQL_TYPE_LONGLONG,
    P.MYSQL_TYPE_INT24, P.MYSQL_TYPE_YEAR, P.MYSQL_TYPE_FLOAT, P.MYSQL_TYPE_DOUBLE,
    P.MYSQL_TYPE_DATE, P.MYSQL_TYPE_DATETIME, P.MYSQL_TYPE_TIMESTAMP, P.MYSQL_TYPE_TIME,
    P.MYSQL_TYPE_VAR_STRING, P.MYSQL_TYPE_STRING, P.MYSQL_TYPE_BLOB, P.MYSQL_TYPE_BIT,
    P.MYSQL_TYPE_NEWDECIMAL, P.MYSQL_TYPE_NEWDATE, P.MYSQL_TYPE_JSON, P.MYSQL_TYPE_GEOMETRY,
]

# Direct scanner fuzz: a mutated row payload against random column shapes; every failure
# must be a MySQLError.
function scan_definition(type::UInt8, flags::UInt16)
    charset = (flags & P.BINARY_FLAG) == 0 ? P.CHARSET_UTF8MB4_GENERAL_CI : P.CHARSET_BINARY
    return P.ColumnDef("def", "db", "t", "t", "v", "v", UInt16(charset), UInt32(255), type, flags, 0x00)
end

function scan_schema(rng::Rng, randomized::Bool)
    if !randomized
        defs = P.ColumnDef[scan_definition(UInt8(type), UInt16(flags)) for (_, type, flags) in TYPED_COLUMNS]
        return UInt8[def.type for def in defs], Type[N.juliatype(def, N.ResultOptions(; time_type=Dates.Microsecond)) for def in defs]
    end
    ncols = randint(rng, 12)
    defs = P.ColumnDef[]
    for _ in 1:ncols
        type = BINARY_TYPE_POOL[randint(rng, length(BINARY_TYPE_POOL))]
        flags = UInt16(0)
        randint(rng, 2) == 1 && (flags |= P.UNSIGNED_FLAG)
        randint(rng, 2) == 1 && (flags |= P.BINARY_FLAG)
        randint(rng, 2) == 1 && (flags |= P.NOT_NULL_FLAG)
        push!(defs, scan_definition(type, flags))
    end
    opts = N.DEFAULT_RESULT_OPTIONS
    return UInt8[def.type for def in defs], Type[N.juliatype(def, opts) for def in defs]
end

function drive_scan(flow::Symbol, data::Vector{UInt8}, rng::Rng; randomized::Bool=true)
    p = P.PacketView(data, 1, length(data), 0x00, 1, length(data))
    offsets = Int[]
    lengths = Int[]
    opts = randomized ? N.DEFAULT_RESULT_OPTIONS : N.ResultOptions(; time_type=Dates.Microsecond)
    binary = flow == :scan_binary
    coltypes, types = scan_schema(rng, randomized)
    ncols = length(coltypes)
    if binary
        P.scan_binary_row!(coltypes, p, offsets, lengths)
    else
        P.scan_text_row!(p, ncols, offsets, lengths)
    end
    for i in 1:ncols
        decode_one(binary, types[i], data, offsets[i], lengths[i], opts; accept_conversion=randomized)
    end
    return nothing
end

function run_case!(entry::CorpusEntry, data::Vector{UInt8}, rng::Rng; randomized_scan::Bool=true)
    (entry.flow == :scan_text || entry.flow == :scan_binary) && return drive_scan(entry.flow, data, rng; randomized=randomized_scan)
    s = session_for(entry, data)
    try
        if entry.flow == :connect
            drive_connect!(s)
        elseif entry.flow == :query
            P.query!(s, "SELECT * FROM t")
            consume_response!(s, false)
        elseif entry.flow == :prepare
            drive_prepare!(s)
        elseif entry.flow == :execute
            P.stmt_execute!(s, 1, UInt8[])
            consume_response!(s, true)
        else
            error("unknown fuzz flow $(entry.flow)")
        end
    finally
        P.transport_close(s.transport)
    end
    return nothing
end

# ---- batches ----

struct Violation
    entry_name::String
    seed::UInt64
    exception::Any
    bytes::Vector{UInt8}
end

acceptable(err) = err isa P.MySQLError

entry_named(name::AbstractString) = CORPUS[findfirst(e -> e.name == name, CORPUS)]

# Regenerates the exact mutated input of `seed` (for saving reproducers).
function case_input(seed::Integer)
    rng = Rng(UInt64(seed))
    entry = CORPUS[randint(rng, length(CORPUS))]
    return entry, mutate(entry.bytes, rng), rng
end

"""
    run_batch(seed0, ncases) -> Vector{Violation}

Runs `ncases` deterministic cases with seeds `seed0:(seed0 + ncases - 1)`. Each case picks a
corpus entry and mutations from its seed alone, so any finding is reproducible from the seed.
"""
function run_batch(seed0::Integer, ncases::Integer)
    violations = Violation[]
    with_logger(NullLogger()) do
        for k in 0:(ncases - 1)
            seed = UInt64(seed0) + UInt64(k)
            entry, data, rng = case_input(seed)
            try
                run_case!(entry, data, rng)
            catch err
                acceptable(err) || push!(violations, Violation(entry.name, seed, err, data))
            end
        end
    end
    return violations
end

# ---- worker-process entry point (scripts/fuzz.jl) ----

function child_main(args::Vector{String})
    length(args) == 3 || error("usage: fuzz.jl <seed0> <ncases> <outfile>")
    seed0 = parse(UInt64, args[1])
    ncases = parse(Int, args[2])
    outfile = args[3]
    violations = run_batch(seed0, ncases)
    open(outfile, "w") do io
        for v in violations
            println(io, v.entry_name, "\t", v.seed, "\t", typeof(v.exception), "\t", bytes2hex(v.bytes))
        end
    end
    isempty(violations) || exit(2)
    return nothing
end

end # module

(abspath(PROGRAM_FILE) == @__FILE__) && Fuzz.child_main(ARGS)
