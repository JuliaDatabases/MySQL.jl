if VERSION < v"1.3.0"

using BinaryProvider # requires BinaryProvider 0.3.0 or later

# Parse some basic command-line arguments
const verbose = "--verbose" in ARGS
const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))

# These are the two binary objects we care about
products = [
    LibraryProduct(joinpath(prefix, "lib/mariadb"), "libmariadb", :libmariadb),
]

Mod = @eval module Anon1 end
Mod.include("build_MbedTLS.v2.16.0.jl")
Mod = @eval module Anon2 end
Mod.include("build_Zlib.v1.2.11.jl")
Mod = @eval module Anon3 end
Mod.include("build_LibSSH2.v1.9.0.jl")
Mod = @eval module Anon4 end
Mod.include("build_LibCURL.v7.68.0.jl")
Mod = @eval module Anon5 end
Mod.include("build_OpenSSL.v1.1.1.jl")
Mod = @eval module Anon6 end
Mod.include("build_Libiconv.v1.16.0.jl")
Mod = @eval module Anon7 end
Mod.include("build_MariaDB_Connector_C.v3.1.6.jl")

# Finally, write out a deps.jl file
write_deps_file(joinpath(@__DIR__, "deps.jl"), products)

end # VERSION