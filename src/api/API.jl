module API

using Dates, DecFP

if VERSION < v"1.3.0"

    # Load libmariadb from our deps.jl
const depsjl_path = joinpath(dirname(@__FILE__), "..", "..", "deps", "deps.jl")
if !isfile(depsjl_path)
    error("MySQL not installed properly, run Pkg.build(\"MySQL\"), restart Julia and try again")
end
include(depsjl_path)
const PLUGIN_DIR = joinpath(dirname(@__FILE__), "..", "..", "deps", "usr", "lib", "mariadb", "plugin")

else

using MariaDB_Connector_C_jll
const PLUGIN_DIR = joinpath(MariaDB_Connector_C_jll.artifact_dir, "lib", "mariadb", "plugin")

end

# const definitions from mysql client library
include("consts.jl")

# lowest-level ccall definitions
include("ccalls.jl")

# api data structure definitions and wrappers
include("apitypes.jl")

# C API functions
include("capi.jl")

# Prepared statement API functions
include("papi.jl")

end # module