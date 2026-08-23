# Deterministic fuzz smoke run (plan §8.4). The full budgeted run lives in
# `scripts/fuzz.jl` (isolated worker processes); this bounded in-process batch keeps the
# invariant — every malformed stream fails as a MySQLError, never a crash — in every CI lane.
include(joinpath(@__DIR__, "fuzz.jl"))
using .Fuzz
include(joinpath(@__DIR__, "..", "..", "scripts", "fuzz.jl"))
using .FuzzDriver
import Logging

const FUZZ_SMOKE_CASES = parse(Int, get(ENV, "MYSQL_FUZZ_SMOKE_CASES", "4000"))
const FUZZ_SMOKE_SEED = parse(UInt64, get(ENV, "MYSQL_FUZZ_SMOKE_SEED", "1"))

@testset "deterministic fuzz" begin
    @testset "unmutated corpus drives every flow" begin
        for entry in Fuzz.CORPUS
            result = try
                Fuzz.run_case!(entry, copy(entry.bytes), Fuzz.Rng(0); randomized_scan=false)
                :clean
            catch err
                err
            end
            if entry.expect == :clean
                @test result === :clean
            elseif entry.expect == :server_error
                @test result isa P.ServerError
            elseif entry.expect == :protocol_error
                @test result isa P.ProtocolError
            else
                error("unknown corpus expectation $(entry.expect)")
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
        entry, data, rng = Fuzz.case_input(FUZZ_SMOKE_SEED)
        entry2, data2, rng2 = Fuzz.case_input(FUZZ_SMOKE_SEED)
        @test entry.name == entry2.name && data == data2 && rng.state == rng2.state
    end
end

@testset "bounded fuzz worker driver" begin
    @test FuzzDriver.checked_options(["--minutes", "1", "--batch", "8", "--memory-mb", "0"]).batch == 8
    @test_throws ErrorException FuzzDriver.checked_options(["--minutes", "0"])
    mktempdir() do outdir
        mktempdir() do tmpdir
            target = UInt64(13)
            calls = Ref(0)
            runner = function(seed, ncases, outfile, timeout_s, memory_mb)
                calls[] += 1
                last_seed = seed + UInt64(ncases - 1)
                return seed <= target <= last_seed ? :crash : :ok
            end
            found = Logging.with_logger(Logging.NullLogger()) do
                FuzzDriver.isolate_failure(
                    UInt64(8),
                    16,
                    :crash,
                    outdir,
                    tmpdir,
                    10,
                    0,
                    time() + 5;
                    runner=runner,
                )
            end
            path = joinpath(outdir, "crash-$target.txt")
            _, data, _ = Fuzz.case_input(target)
            @test found == 1 && calls[] <= 8
            @test isfile(path)
            @test occursin("seed: $target", read(path, String))
            @test occursin("input_hex: $(bytes2hex(data))", read(path, String))
        end
    end
    # the bounded (memory-limited) worker lane is Linux/macOS; Windows runs workers unbounded
    memory_mb = Sys.iswindows() ? 0 : 64
    cmd = string(FuzzDriver.worker_cmd(UInt64(1), 1, joinpath(tempdir(), "fuzz.tsv"), memory_mb))
    @test occursin("--startup-file=no", cmd)
    Sys.iswindows() || @test occursin("--heap-size-hint=64M", cmd)
    Sys.iswindows() && @test_throws ErrorException FuzzDriver.worker_cmd(UInt64(1), 1, joinpath(tempdir(), "fuzz.tsv"), 64)
end
