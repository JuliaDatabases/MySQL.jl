__precompile__(true)
module MySQL
    using Compat
    using DataFrames
    using Missings
    using DataStreams
    using Compat.Dates

    include("config.jl")
    include("consts.jl")
    include("types.jl")
    include("datetime.jl")
    include("api.jl")
    include("results.jl")
    include("iterators.jl")
    include("handy.jl")
end
