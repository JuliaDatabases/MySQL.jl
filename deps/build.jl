if VERSION < v"1.3.0"

using BinaryProvider # requires BinaryProvider 0.3.0 or later

# Parse some basic command-line arguments
const verbose = "--verbose" in ARGS
const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))

# These are the two binary objects we care about
products = [
    LibraryProduct(joinpath(prefix, "lib/mariadb"), "libmariadb", :libmariadb),
]

module Anon1 end
Anon1.include("build_MbedTLS.v2.16.0.jl")
module Anon2 end
Anon2.include("build_Zlib.v1.2.11.jl")
module Anon3 end
Anon3.include("build_LibSSH2.v1.9.0.jl")
module Anon4 end
Anon4.include("build_LibCURL.v7.68.0.jl")
module Anon5 end
Anon5.include("build_OpenSSL.v1.1.1.jl")
module Anon6 end
Anon6.include("build_Libiconv.v1.16.0.jl")
module Anon7 end
Anon7.include("build_MariaDB_Connector_C.v3.1.6.jl")

# Finally, write out a deps.jl file
write_deps_file(joinpath(@__DIR__, "deps.jl"), products)

end # VERSION