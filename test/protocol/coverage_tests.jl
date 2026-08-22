# Transition-table coverage: every (from, event, to) row of Protocol.TRANSITIONS must have
# been exercised by the suite. Rows that no scenario can reach naturally (close!/fault! from
# intermediate phases) are driven here over in-memory sessions.
@testset "transition coverage" begin
    non_terminal = [ph for ph in instances(P.Phase) if !P.is_terminal(ph)]
    for ph in non_terminal
        s = P.Session(P.FaultTransport(IOBuffer()))
        s.phase = ph
        P.close!(s)
        @test s.phase == P.CLOSED
        @test !isopen(s)
        P.close!(s)   # idempotent
        @test s.phase == P.CLOSED
        s = P.Session(P.FaultTransport(IOBuffer()))
        s.phase = ph
        err = P.fault!(s, EOFError())
        @test err isa P.ProtocolError
        @test s.phase == P.BROKEN
        @test P.fault!(s, InterruptException()) isa InterruptException   # already terminal: no transition
        @test s.phase == P.BROKEN
    end
    @test P.fault!(P.Session(P.FaultTransport(IOBuffer())), P.Reseau.IOPoll.DeadlineExceededError()) isa P.TimeoutError
    s = P.Session(P.FaultTransport(IOBuffer()))
    @test_throws ErrorException P.transition!(s, :row, P.ROWS)   # illegal transition is a programming error
    missing_rows = P.uncovered_transitions()
    @test isempty(missing_rows)
    isempty(missing_rows) || @info "uncovered transitions" missing_rows
end
