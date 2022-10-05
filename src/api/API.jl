module API

using Dates, DecFP

export DateAndTime

using MariaDB_Connector_C_jll
const PLUGIN_DIR = joinpath(MariaDB_Connector_C_jll.artifact_dir, "lib", "mariadb", "plugin")

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