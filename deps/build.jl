if VERSION < v"1.3.0"

using BinaryProvider # requires BinaryProvider 0.3.0 or later

# Parse some basic command-line arguments
const verbose = "--verbose" in ARGS
const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))

# These are the two binary objects we care about
products = [
    LibraryProduct(joinpath(prefix, "lib/mariadb"), "libmariadb", :libmariadb),
]

dependencies = [
    "build_MbedTLS.v2.16.0.jl",
    "build_Zlib.v1.2.11.jl",
    "build_LibSSH2.v1.9.0.jl",
    "build_LibCURL.v7.68.0.jl",
    "build_OpenSSL.v1.1.1.jl",
    "build_Libiconv.v1.16.0.jl",
    "build_MariaDB_Connector_C.v3.1.6.jl"
]

for dependency in dependencies
    # it's a bit faster to run the build in an anonymous module instead of
    # starting a new julia process

    # Build the dependencies
    Mod = @eval module Anon end
    Mod.include(dependency)
end

# Finally, write out a deps.jl file
write_deps_file(joinpath(@__DIR__, "deps.jl"), products)

end # VERSION