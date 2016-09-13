VERSION >= v"0.4" && __precompile__()

module MySQL
    include("config.jl")
    include("consts.jl")
    include("types.jl")
    include("datetime.jl")
    include("api.jl")
    include("results.jl")
    include("iterators.jl")
    include("handy.jl")
end
