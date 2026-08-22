# Native wire-protocol tests. These need no database server (scripted loopback peer only)
# and therefore run on every platform and CI lane.
using Test, MySQL, SHA

const P = MySQL.Protocol
const Reseau = P.Reseau

include("fakepeer.jl")
include("vectors.jl")

using .FakePeer: FakePeer, hexbytes
using .Vectors: Vectors

P.COVERAGE_ENABLED[] = true
empty!(P.COVERAGE)

@testset "Protocol" begin
    include("codec_tests.jl")
    include("packets_tests.jl")
    include("handshake_tests.jl")
    include("responses_tests.jl")
    include("session_tests.jl")
    include("crypto_tests.jl")
    include("auth_tests.jl")
    include("tls_tests.jl")
    include("native_tests.jl")
    include("cursor_tests.jl")
    include("binary_tests.jl")
    include("fuzz_tests.jl")
    include("perf_tests.jl")
    include("coverage_tests.jl")
end

P.COVERAGE_ENABLED[] = false
