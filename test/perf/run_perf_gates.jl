# Child-process entry point for the §8.9 timing gates (see test/runtests.jl): Pkg.test forces
# --check-bounds=yes, which slows the pure-Julia backend 2-3x on byte-heavy paths while
# leaving Connector/C's C code untouched. The parent keeps the plain and TLS fixtures
# alive and runs correctness, limit, and allocation gates under full bounds checking.
using Test

include(joinpath(@__DIR__, "perf_gates.jl"))

@assert Base.JLOptions().check_bounds != 1 "the perf gates must not run under --check-bounds=yes"
length(ARGS) == 2 || error("usage: run_perf_gates.jl <plain-port> <tls-port>")
PerfGates.run_timing_gates(parse(Int, ARGS[1]), parse(Int, ARGS[2]))
