# Phase machine. Every decoder takes the explicit phase; `transition!` only permits the
# (from, event, to) triples listed in TRANSITIONS and records them for coverage.

@enum Phase begin
    CONNECTING      # TCP connected, greeting not yet read
    HANDSHAKE       # HandshakeV10 parsed, response not yet sent
    TLS_UPGRADE     # SSLRequest sent, TLS handshake in progress
    AUTH            # HandshakeResponse sent; auth exchange in progress
    READY           # idle, command phase
    CMD_SENT        # command written, first response packet not yet read
    COLUMN_DEFS     # reading column definitions of a result set
    ROWS            # reading rows
    RESULT_END      # a result set ended with MORE_RESULTS_EXISTS set
    LOCAL_INFILE    # uploading a LOCAL INFILE
    CLOSED          # closed cleanly
    BROKEN          # stream position unknown; closed
end

# (from, event, to). The table is the contract; tests assert every row is exercised.
const TRANSITIONS = Set{Tuple{Phase, Symbol, Phase}}([
    (CONNECTING, :greeting, HANDSHAKE),
    (CONNECTING, :initial_err, CLOSED),
    (HANDSHAKE, :ssl_request, TLS_UPGRADE),
    (TLS_UPGRADE, :tls_established, HANDSHAKE),
    (HANDSHAKE, :handshake_response, AUTH),
    (AUTH, :auth_continue, AUTH),
    (AUTH, :auth_ok, READY),
    (AUTH, :auth_err, CLOSED),
    (READY, :send_command, CMD_SENT),
    (READY, :send_noresponse, READY),
    (READY, :quit, CLOSED),
    (CMD_SENT, :ok, READY),
    (CMD_SENT, :ok_more, RESULT_END),
    (CMD_SENT, :err, READY),
    (CMD_SENT, :prepare_ok, READY),
    (CMD_SENT, :local_infile, LOCAL_INFILE),
    (CMD_SENT, :column_count, COLUMN_DEFS),
    (COLUMN_DEFS, :column_def, COLUMN_DEFS),
    (COLUMN_DEFS, :metadata_eof, ROWS),
    (COLUMN_DEFS, :metadata_complete, ROWS),
    (ROWS, :row, ROWS),
    (ROWS, :terminator, READY),
    (ROWS, :terminator_more, RESULT_END),
    (ROWS, :err, READY),
    (RESULT_END, :next_result, CMD_SENT),
    (LOCAL_INFILE, :upload_done, CMD_SENT),
    (CONNECTING, :fault, BROKEN),
    (HANDSHAKE, :fault, BROKEN),
    (TLS_UPGRADE, :fault, BROKEN),
    (AUTH, :fault, BROKEN),
    (READY, :fault, BROKEN),
    (CMD_SENT, :fault, BROKEN),
    (COLUMN_DEFS, :fault, BROKEN),
    (ROWS, :fault, BROKEN),
    (RESULT_END, :fault, BROKEN),
    (LOCAL_INFILE, :fault, BROKEN),
    (READY, :close, CLOSED),
    (TLS_UPGRADE, :close, CLOSED),
    (LOCAL_INFILE, :close, CLOSED),
    (RESULT_END, :close, CLOSED),
    (ROWS, :close, CLOSED),
    (COLUMN_DEFS, :close, CLOSED),
    (CMD_SENT, :close, CLOSED),
    (HANDSHAKE, :close, CLOSED),
    (AUTH, :close, CLOSED),
    (CONNECTING, :close, CLOSED),
])

# Process-wide coverage accumulator (tests turn it on and assert TRANSITIONS ⊆ covered).
const COVERAGE_ENABLED = Ref(false)
const COVERAGE = Set{Tuple{Phase, Symbol, Phase}}()
const COVERAGE_LOCK = ReentrantLock()

function record_coverage(t::Tuple{Phase, Symbol, Phase})
    COVERAGE_ENABLED[] || return nothing
    lock(COVERAGE_LOCK)
    try
        push!(COVERAGE, t)
    finally
        unlock(COVERAGE_LOCK)
    end
    return nothing
end

function uncovered_transitions()
    return lock(COVERAGE_LOCK) do
        setdiff(TRANSITIONS, COVERAGE)
    end
end

@noinline illegal_transition(from::Phase, event::Symbol, to::Phase) = return error("internal error: illegal phase transition $from --$event--> $to")

is_terminal(p::Phase) = return p == CLOSED || p == BROKEN
