# Child-process entry point for the §8.9 timing report (see test/runtests.jl): Pkg.test
# forces --check-bounds=yes, which slows the byte-heavy scan paths 2-3x. The parent keeps
# the plain and TLS fixtures alive and runs correctness, limit, and allocation gates under
# full bounds checking.
using Test

include(joinpath(@__DIR__, "perf_gates.jl"))

@assert Base.JLOptions().check_bounds != 1 "the perf gates must not run under --check-bounds=yes"
length(ARGS) == 2 || error("usage: run_perf_gates.jl <plain-port> <tls-port>")
PerfGates.run_timing_gates(parse(Int, ARGS[1]), parse(Int, ARGS[2]))
