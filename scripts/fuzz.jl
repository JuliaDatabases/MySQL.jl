# Budgeted deterministic fuzz driver (plan §8.4): runs `test/protocol/fuzz.jl` batches in
# isolated worker processes with a wall-clock limit and a 2 GiB memory ceiling, restarts
# workers after a crash or timeout, and saves the exact mutated input + seed of every
# isolated finding. A failed batch is split recursively before per-case replay, so failure
# isolation stays inside the total run budget.
#
# Linux workers use `prlimit --as` for a hard address-space limit (the nightly lane is
# Linux). Other Unix hosts use an RSS watchdog because macOS does not implement RLIMIT_AS;
# `--heap-size-hint` remains a GC hint and is not treated as the limit.
#
#   julia --project=. scripts/fuzz.jl [--minutes 30] [--seed 1000000] [--batch 100000]
#       [--worker-timeout 600] [--memory-mb 2048] [--out fuzz_failures]
#
# Exit status: 0 = budget exhausted with no findings, 1 = findings were saved.
module FuzzDriver

const REPO = dirname(@__DIR__)
const FUZZ_SCRIPT = joinpath(REPO, "test", "protocol", "fuzz.jl")

if isdefined(parentmodule(@__MODULE__), :Fuzz)
    const Fuzz = getfield(parentmodule(@__MODULE__), :Fuzz)
else
    include(FUZZ_SCRIPT)
end

function parse_args(args::Vector{String})
    opts = Dict{String, String}(
        "minutes" => "30",
        "seed" => "1000000",
        "batch" => "100000",
        "worker-timeout" => "600",
        "memory-mb" => "2048",
        "out" => "fuzz_failures",
    )
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

function worker_cmd(seed::UInt64, ncases::Int, outfile::String, memory_mb::Int)
    base = if memory_mb == 0
        `$(Base.julia_cmd()) --project=$REPO --startup-file=no $FUZZ_SCRIPT $seed $ncases $outfile`
    else
        heap_hint = "--heap-size-hint=$(memory_mb)M"
        `$(Base.julia_cmd()) --project=$REPO --startup-file=no $heap_hint $FUZZ_SCRIPT $seed $ncases $outfile`
    end
    if Sys.islinux() && memory_mb > 0
        limiter = Sys.which("prlimit")
        limiter === nothing && error("prlimit is required to enforce the fuzz-worker memory limit on Linux")
        limit_bytes = Base.checked_mul(memory_mb, 1024 * 1024)
        return `$limiter --as=$limit_bytes -- $base`
    end
    Sys.iswindows() && memory_mb > 0 && error("set --memory-mb 0 on Windows; the bounded fuzz lane runs on Linux")
    return base
end

function process_rss_bytes(proc::Base.Process)
    Sys.isunix() || return 0
    output = try
        read(Cmd(["ps", "-o", "rss=", "-p", string(getpid(proc))]), String)
    catch
        return 0
    end
    value = tryparse(Int, strip(output))
    return value === nothing ? 0 : value * 1024
end

function stop_process!(proc::Base.Process)
    try
        Sys.iswindows() ? kill(proc) : kill(proc, Base.SIGKILL)
    catch
    end
    wait(proc)
    return nothing
end

# Runs one worker with wall-clock and memory limits. Returns
# `:ok | :findings | :crash | :timeout | :memory`.
function run_worker(seed::UInt64, ncases::Int, outfile::String, timeout_s::Int, memory_mb::Int)
    proc = run(pipeline(worker_cmd(seed, ncases, outfile, memory_mb); stdout=stdout, stderr=stderr); wait=false)
    deadline = time() + timeout_s
    memory_bytes = Base.checked_mul(memory_mb, 1024 * 1024)
    watch_rss = memory_bytes > 0 && !Sys.islinux()
    while process_running(proc)
        if time() >= deadline
            stop_process!(proc)
            return :timeout
        end
        if watch_rss && process_rss_bytes(proc) > memory_bytes
            stop_process!(proc)
            return :memory
        end
        sleep(0.25)
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

function save_case_failure(outdir::String, status::Symbol, seed::UInt64)
    mkpath(outdir)
    entry, data, _ = Fuzz.case_input(seed)
    path = joinpath(outdir, "$(status)-$(seed).txt")
    open(path, "w") do io
        println(io, "status: $status")
        println(io, "entry: $(entry.name)")
        println(io, "seed: $seed")
        println(io, "input_hex: $(bytes2hex(data))")
        println(io, "reproduce: julia --project=. $FUZZ_SCRIPT $seed 1 /tmp/out.tsv")
    end
    @warn "fuzz worker failure isolated" seed status path
    return 1
end

function save_range_failure(outdir::String, status::Symbol, seed::UInt64, ncases::Int)
    mkpath(outdir)
    path = joinpath(outdir, "unresolved-$(seed)-$(ncases).txt")
    last_seed = seed + UInt64(ncases - 1)
    open(path, "w") do io
        println(io, "status: $status")
        println(io, "first_seed: $seed")
        println(io, "last_seed: $last_seed")
        println(io, "cases: $ncases")
        println(io, "reproduce: julia --project=. $FUZZ_SCRIPT $seed $ncases /tmp/out.tsv")
    end
    @warn "fuzz failure could not be reduced inside the run budget" seed ncases status path
    return 1
end

function bounded_timeout(deadline::Float64, preferred::Int)
    remaining = floor(Int, deadline - time())
    remaining > 0 || return 0
    return min(preferred, remaining)
end

# Recursively splits one failed batch. Only a one-case range is recorded as an exact crash
# reproducer. If the failure is cumulative, nondeterministic, or the budget expires, the
# smallest unresolved seed range is saved and the run still fails visibly.
function isolate_failure(
        seed0::UInt64,
        ncases::Int,
        initial_status::Symbol,
        outdir::String,
        tmpdir::String,
        timeout_s::Int,
        memory_mb::Int,
        deadline::Float64;
        runner::F=run_worker,
    ) where {F}
    function visit(seed::UInt64, count::Int, status::Symbol)
        count == 1 && return save_case_failure(outdir, status, seed)
        time() < deadline || return save_range_failure(outdir, :budget, seed, count)
        left_count = count >> 1
        right_count = count - left_count
        parts = ((seed, left_count), (seed + UInt64(left_count), right_count))
        results = Tuple{UInt64, Int, Symbol}[]
        for (part_seed, part_count) in parts
            child_timeout = bounded_timeout(deadline, max(10, timeout_s >> 1))
            if child_timeout == 0
                push!(results, (part_seed, part_count, :budget))
                continue
            end
            outfile = joinpath(tmpdir, "isolate-$part_seed-$part_count.tsv")
            child_status = runner(part_seed, part_count, outfile, child_timeout, memory_mb)
            if child_status == :findings
                found = save_findings(outfile, outdir, part_seed)
                child_status = found == 0 ? :crash : :saved
            end
            push!(results, (part_seed, part_count, child_status))
        end
        found = 0
        for (part_seed, part_count, child_status) in results
            child_status == :ok && continue
            child_status == :saved && (found += 1; continue)
            child_status == :budget && (found += save_range_failure(outdir, :budget, part_seed, part_count); continue)
            found += visit(part_seed, part_count, child_status)
        end
        found > 0 && return found
        return save_range_failure(outdir, initial_status, seed, count)
    end
    return visit(seed0, ncases, initial_status)
end

function checked_options(args::Vector{String})
    opts = parse_args(args)
    minutes = parse(Float64, opts["minutes"])
    seed = parse(UInt64, opts["seed"])
    batch = parse(Int, opts["batch"])
    timeout_s = parse(Int, opts["worker-timeout"])
    memory_mb = parse(Int, opts["memory-mb"])
    isfinite(minutes) && minutes > 0 || error("--minutes must be positive and finite")
    batch > 0 || error("--batch must be positive")
    timeout_s > 0 || error("--worker-timeout must be positive")
    memory_mb >= 0 || error("--memory-mb must be nonnegative")
    return (; minutes, seed, batch, timeout_s, memory_mb, outdir=abspath(opts["out"]))
end

function main(args::Vector{String})
    opts = checked_options(args)
    started = time()
    deadline = started + opts.minutes * 60
    reserve = min(300.0, max(1.0, opts.minutes * 12))
    batch_deadline = deadline - reserve
    seed = opts.seed
    total_cases = 0
    total_findings = 0
    mktempdir() do tmpdir
        while time() < batch_deadline
            remaining = floor(Int, batch_deadline - time())
            remaining >= min(opts.timeout_s, 30) || break
            outfile = joinpath(tmpdir, "batch-$seed.tsv")
            @info "fuzz batch" seed batch=opts.batch remaining_min=round((deadline - time()) / 60; digits=1)
            status = run_worker(seed, opts.batch, outfile, min(opts.timeout_s, remaining), opts.memory_mb)
            total_cases += opts.batch
            if status == :findings
                total_findings += save_findings(outfile, opts.outdir, seed)
                break
            elseif status == :crash || status == :timeout || status == :memory
                @warn "fuzz worker did not exit cleanly; isolating" seed status
                total_findings += isolate_failure(
                    seed,
                    opts.batch,
                    status,
                    opts.outdir,
                    tmpdir,
                    opts.timeout_s,
                    opts.memory_mb,
                    deadline,
                )
                break
            end
            seed = Base.checked_add(seed, UInt64(opts.batch))
        end
    end
    @info "fuzz run complete" total_cases total_findings outdir=opts.outdir elapsed_min=round((time() - started) / 60; digits=2)
    return total_findings == 0 ? 0 : 1
end

end # module

(abspath(PROGRAM_FILE) == @__FILE__) && exit(FuzzDriver.main(ARGS))
