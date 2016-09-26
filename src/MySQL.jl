VERSION >= v"0.4" && __precompile__()

module MySQL
    if isfile(joinpath(dirname(@__FILE__),"..","deps","deps.jl"))
        include("../deps/deps.jl")
    else
        error("MySQL not properly installed. Please run Pkg.build(\"MySQL\")")
    end
    const mysql_lib = libmysqlclient
    include("consts.jl")
    include("types.jl")
    include("datetime.jl")
    include("api.jl")
    include("results.jl")
    include("iterators.jl")
    include("handy.jl")
end
