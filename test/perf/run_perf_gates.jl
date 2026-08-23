# Child-process entry point for the §8.9 gates (see test/runtests.jl): Pkg.test forces
# --check-bounds=yes, which slows the pure-Julia backend 2-3x on byte-heavy paths while
# leaving Connector/C's C code untouched, so the timing gates must run with production
# bounds semantics. A test failure raises TestSetException, so the process exits nonzero.
using Test

include(joinpath(@__DIR__, "perf_gates.jl"))

@assert Base.JLOptions().check_bounds != 1 "the perf gates must not run under --check-bounds=yes"
PerfGates.runtests()
