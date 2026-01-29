module API

using Dates, DecFP, Libdl

export DateAndTime

using MariaDB_Connector_C_jll
using OpenSSL_jll: libssl, libcrypto

const PLUGIN_DIR = joinpath(MariaDB_Connector_C_jll.artifact_dir, "lib", "mariadb", "plugin")

# Pre-load OpenSSL libraries so they're available when MariaDB loads plugins.
# MariaDB authentication plugins (e.g., caching_sha2_password) depend on OpenSSL,
# but when MariaDB loads them via dlopen, the dynamic linker can't find OpenSSL
# because it's in a different artifact. By loading OpenSSL with RTLD_GLOBAL first,
# its symbols become available to subsequently loaded libraries.
# See: https://github.com/JuliaDatabases/MySQL.jl/issues/232
function __init__()
    @static if !Sys.iswindows()
        Libdl.dlopen(libcrypto, Libdl.RTLD_GLOBAL)
        Libdl.dlopen(libssl, Libdl.RTLD_GLOBAL)
    end
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