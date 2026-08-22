# Deterministic fuzz smoke run (plan §8.4). The full budgeted run lives in
# `scripts/fuzz.jl` (isolated worker processes); this bounded in-process batch keeps the
# invariant — every malformed stream fails as a MySQLError, never a crash — in every CI lane.
include(joinpath(@__DIR__, "fuzz.jl"))
using .Fuzz

const FUZZ_SMOKE_CASES = parse(Int, get(ENV, "MYSQL_FUZZ_SMOKE_CASES", "4000"))
const FUZZ_SMOKE_SEED = parse(UInt64, get(ENV, "MYSQL_FUZZ_SMOKE_SEED", "1"))

@testset "deterministic fuzz" begin
    @testset "unmutated corpus drives every flow" begin
        for entry in Fuzz.CORPUS
            result = try
                Fuzz.run_case!(entry, copy(entry.bytes), Fuzz.Rng(0))
                :clean
            catch err
                err
            end
            if entry.expect == :clean
                @test result === :clean
            elseif entry.expect == :server_error
                @test result isa P.ServerError
            else
                @test result === :clean || result isa P.MySQLError
            end
        end
    end
    @testset "mutated batch: every failure is a MySQLError" begin
        violations = Fuzz.run_batch(FUZZ_SMOKE_SEED, FUZZ_SMOKE_CASES)
        for v in violations
            @info "fuzz violation (reproduce with Fuzz.case_input(seed))" v.entry_name v.seed exception=v.exception bytes=bytes2hex(v.bytes)
        end
        @test isempty(violations)
    end
    @testset "seeds are reproducible" begin
        entry, data, _ = Fuzz.case_input(FUZZ_SMOKE_SEED)
        entry2, data2, _ = Fuzz.case_input(FUZZ_SMOKE_SEED)
        @test entry.name == entry2.name && data == data2
    end
end
