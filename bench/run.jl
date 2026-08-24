# Cross-driver benchmark: the current checkout (native wire protocol) against MySQL.jl 1.x
# (MariaDB Connector/C) on the same Docker server and fixture. The ratio gates that lived in
# test/perf before 2.0 retired with the C backend; this harness keeps the comparison
# repeatable. Needs Docker.
#
#     julia --project=. bench/run.jl
#
# Builds two temp environments (the checkout; MySQL@1 from the registry), starts the perf
# fixture servers via test/perf/perf_gates.jl, runs bench/child.jl once per environment,
# and prints a ratio table.

import Pkg

const ROOT = normpath(joinpath(@__DIR__, ".."))

function build_env(name::String, spec)
    dir = mktempdir()
    Pkg.activate(dir)
    spec === nothing ? Pkg.develop(path=ROOT) : Pkg.add(Pkg.PackageSpec(; name="MySQL", version=spec))
    Pkg.add(["DBInterface", "Tables", "Chairmarks", "Printf"])
    Pkg.precompile()
    println("[bench] environment `$name` ready: $dir")
    return dir
end

native_env = build_env("native", nothing)
legacy_env = build_env("mysql1", "1")

# the fixture manager runs in the checkout's own test environment
Pkg.activate(ROOT)
Pkg.instantiate()

include(joinpath(ROOT, "test", "perf", "perf_gates.jl"))

function run_child(env::String, label::String, port::Int, results::Dict{String, Dict{String, Float64}})
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = `$julia --startup-file=no --project=$env $(joinpath(@__DIR__, "child.jl")) $port $label`
    for line in eachline(pipeline(cmd; stderr=stderr))
        println(line)
        parts = split(line, '\t')
        if length(parts) == 4 && parts[1] == "RESULT"
            get!(results, String(parts[3]), Dict{String, Float64}())[String(parts[2])] = parse(Float64, parts[4])
        end
    end
    return nothing
end

results = Dict{String, Dict{String, Float64}}()
PerfGates.with_perf_server(PerfGates.perf_port(); tls=false) do
end # warm the image pull before timing anything

plain_port = PerfGates.perf_port()
PerfGates.with_perf_server(plain_port; tls=false) do
    PerfGates.setup_fixture!(plain_port)
    run_child(native_env, "native", plain_port, results)
    run_child(legacy_env, "mysql1", plain_port, results)
end

println("\n", rpad("benchmark", 28), lpad("native", 10), lpad("mysql@1", 10), lpad("ratio", 8))
for name in sort!(collect(keys(results)))
    r = results[name]
    (haskey(r, "native") && haskey(r, "mysql1")) || continue
    println(rpad(name, 28), lpad(string(round(r["native"]; digits=4)), 10), lpad(string(round(r["mysql1"]; digits=4)), 10), lpad(string(round(r["mysql1"] / r["native"]; digits=2)), 7), "x")
end
