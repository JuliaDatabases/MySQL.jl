module Anon1 end
module Anon2 end
module Anon3 end
module Anon4 end
module Anon5 end
module Anon6 end
module Anon7 end

@static if VERSION < v"1.3.0"

using BinaryProvider # requires BinaryProvider 0.3.0 or later

# Parse some basic command-line arguments
const verbose = "--verbose" in ARGS
const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))

if Sys.iswindows()
    pre = prefix
else
    pre = joinpath(prefix, "lib/mariadb")
end

# These are the two binary objects we care about
products = [
    LibraryProduct(pre, "libmariadb", :libmariadb),
]

Anon1.include("build_MbedTLS.v2.16.0.jl")
Anon2.include("build_Zlib.v1.2.11.jl")
Anon3.include("build_LibSSH2.v1.9.0.jl")
Anon4.include("build_LibCURL.v7.68.0.jl")
Anon5.include("build_OpenSSL.v1.1.1.jl")
Anon6.include("build_Libiconv.v1.16.0.jl")
Anon7.include("build_MariaDB_Connector_C.v3.1.6.jl")

# Finally, write out a deps.jl file
write_deps_file(joinpath(@__DIR__, "deps.jl"), products)

end # VERSION