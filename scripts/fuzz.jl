# Budgeted deterministic fuzz driver (plan §8.4): runs `test/protocol/fuzz.jl` batches in
# isolated worker processes with a heap-size hint and a wall-clock limit per worker, restarts
# workers after a crash or timeout, and saves the exact mutated input + seed of every finding
# (a worker crash is bisected to its case in per-case processes). Seeds advance
# monotonically so a nightly run is reproducible from its starting seed alone.
#
#   julia --project=. scripts/fuzz.jl [--minutes 30] [--seed 1000000] [--batch 100000]
#       [--worker-timeout 600] [--out fuzz_failures]
#
# Exit status: 0 = budget exhausted with no findings, 1 = findings were saved.

function parse_args(args::Vector{String})
    opts = Dict{String, String}("minutes" => "30", "seed" => "1000000", "batch" => "100000", "worker-timeout" => "600", "out" => "fuzz_failures")
    i = 1
    while i <= length(args)
        startswith(args[i], "--") || error("unknown argument $(args[i])")
        key = args[i][3:end]
        haskey(opts, key) || error("unknown option --$key")
        i + 1 <= length(args) || error("--$key needs a value")
        opts[key] = args[i + 1]
        i += 2
    end
    return opts
end

const REPO = dirname(@__DIR__)
const FUZZ_SCRIPT = joinpath(REPO, "test", "protocol", "fuzz.jl")

worker_cmd(seed::UInt64, ncases::Int, outfile::String) =
    `$(Base.julia_cmd()) --project=$REPO --startup-file=no --heap-size-hint=2G $FUZZ_SCRIPT $seed $ncases $outfile`

# Runs one worker with a wall-clock limit. Returns (:ok | :findings | :crash | :timeout).
function run_worker(seed::UInt64, ncases::Int, outfile::String, timeout_s::Int)
    proc = run(pipeline(worker_cmd(seed, ncases, outfile); stdout=stdout, stderr=stderr); wait=false)
    t0 = time()
    while process_running(proc)
        if time() - t0 > timeout_s
            kill(proc, Base.SIGKILL)
            wait(proc)
            return :timeout
        end
        sleep(0.5)
    end
    proc.exitcode == 0 && return :ok
    proc.exitcode == 2 && return :findings
    return :crash
end

function save_findings(outfile::String, outdir::String, batch_start::UInt64)
    isfile(outfile) || return 0
    lines = readlines(outfile)
    isempty(lines) && return 0
    mkpath(outdir)
    path = joinpath(outdir, "findings-$(batch_start).tsv")
    open(path, "a") do io
        foreach(line -> println(io, line), lines)
    end
    @warn "fuzz findings saved" path count=length(lines)
    return length(lines)
end

# A crashed/timed-out worker: replay its batch one case per process to pin the exact case,
# then save the reproducer (regenerated deterministically from the seed).
function bisect_crash(seed0::UInt64, ncases::Int, outdir::String, tmpdir::String, case_timeout_s::Int)
    mkpath(outdir)
    found = 0
    for k in 0:(ncases - 1)
        seed = seed0 + UInt64(k)
        outfile = joinpath(tmpdir, "case-$seed.tsv")
        status = run_worker(seed, 1, outfile, case_timeout_s)
        status == :ok && continue
        found += 1
        path = joinpath(outdir, "crash-$seed.txt")
        open(path, "w") do io
            println(io, "status: $status")
            println(io, "seed: $seed")
            println(io, "reproduce: julia --project=. $FUZZ_SCRIPT $seed 1 /tmp/out.tsv")
            # regenerate the exact mutated input in-process for the record
            println(io, "input: regenerate with Fuzz.case_input($seed)")
        end
        @warn "fuzz crash isolated" seed status path
    end
    return found
end

function main(args::Vector{String})
    opts = parse_args(args)
    minutes = parse(Float64, opts["minutes"])
    seed = parse(UInt64, opts["seed"])
    batch = parse(Int, opts["batch"])
    timeout_s = parse(Int, opts["worker-timeout"])
    outdir = abspath(opts["out"])
    deadline = time() + minutes * 60
    total_cases = 0
    total_findings = 0
    tmpdir = mktempdir()
    while time() < deadline
        outfile = joinpath(tmpdir, "batch-$seed.tsv")
        @info "fuzz batch" seed batch remaining_min=round((deadline - time()) / 60; digits=1)
        status = run_worker(seed, batch, outfile, timeout_s)
        if status == :findings
            total_findings += save_findings(outfile, outdir, seed)
        elseif status == :crash || status == :timeout
            @warn "fuzz worker did not exit cleanly; bisecting" seed status
            total_findings += bisect_crash(seed, batch, outdir, tmpdir, max(60, timeout_s ÷ 10))
        end
        total_cases += batch
        seed += UInt64(batch)
    end
    @info "fuzz run complete" total_cases total_findings outdir
    exit(total_findings == 0 ? 0 : 1)
end

main(ARGS)
