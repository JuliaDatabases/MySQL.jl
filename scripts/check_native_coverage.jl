const NATIVE_SOURCE = r"(?:^|/)src/(?:Protocol|Native)/"

function usage()
    return error("usage: julia scripts/check_native_coverage.jl <lcov.info> [minimum_fraction]")
end

function is_native_source(path::AbstractString)
    return occursin(NATIVE_SOURCE, replace(normpath(path), '\\' => '/'))
end

function read_native_coverage(path::AbstractString)
    coverage = Dict{Tuple{String, Int}, Int}()
    source = nothing
    for line in eachline(path)
        if startswith(line, "SF:")
            candidate = line[4:end]
            source = is_native_source(candidate) ? candidate : nothing
        elseif source !== nothing && startswith(line, "DA:")
            fields = split(line[4:end], ','; limit=3)
            length(fields) >= 2 || error("malformed DA record in $path: $line")
            line_number = parse(Int, fields[1])
            executions = parse(Int, fields[2])
            key = (source, line_number)
            coverage[key] = max(get(coverage, key, 0), executions)
        elseif line == "end_of_record"
            source = nothing
        end
    end
    return coverage
end

function main(args::Vector{String})
    1 <= length(args) <= 2 || usage()
    path = first(args)
    minimum = length(args) == 2 ? parse(Float64, args[2]) : 0.85
    0.0 <= minimum <= 1.0 || error("minimum_fraction must be between 0 and 1")
    isfile(path) || error("coverage file does not exist: $path")
    coverage = read_native_coverage(path)
    isempty(coverage) && error("$path contains no src/Protocol or src/Native coverage records")
    total = length(coverage)
    covered = count(>(0), values(coverage))
    fraction = covered / total
    println("native line coverage: $covered/$total ($(round(100 * fraction; digits=2))%)")
    fraction >= minimum || error("native line coverage is below $(100 * minimum)%")
    return nothing
end

main(ARGS)
