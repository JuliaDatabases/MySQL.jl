using BinaryProvider
# Parse some basic command-line arguments
const prefix = Prefix(joinpath(@__DIR__, "usr"))

suffix() = platform_key() == Linux(:i686, :glibc) ? "linux-glibc2.12-i686" :
           platform_key() == Linux(:x86_64, :glibc) ? "linux-glibc2.12-x86_64" :
           platform_key() == Windows(:i686) ? "win32" :
           platform_key() == Windows(:x86_64) ? "winx64" :
           platform_key() == MacOS() ? "macos10.12-x86_64" : error("platform $(Sys.MACHINE) is not supported")

const lib = LibraryProduct(joinpath(@__DIR__, "usr", "mysql-connector-c-6.1.11-$(suffix())", "lib"), ["libmysqlclient", "libmysql"], :libmysql)

download_info = Dict(
    Linux(:i686, :glibc) => ("https://dev.mysql.com/get/Downloads/Connector-C/mysql-connector-c-6.1.11-linux-glibc2.12-i686.tar.gz", "32e463fda6613907b90d44228b3b81ad7508ce5e20a928b86ced47fbce1fe92a"),
    Linux(:x86_64, :glibc) => ("https://dev.mysql.com/get/Downloads/Connector-C/mysql-connector-c-6.1.11-linux-glibc2.12-x86_64.tar.gz", "149102915ea1f1144edb0de399c3392a55773448f96b150ec1568f700c00c929"),
    Windows(:i686) => ("https://dev.mysql.com/get/Downloads/Connector-C/mysql-connector-c-6.1.11-win32.zip", "a32487407bc0c4e217d8839892333fb0cb39153194d2788f226e9c5b9abdd928"),
    Windows(:x86_64) => ("https://dev.mysql.com/get/Downloads/Connector-C/mysql-connector-c-6.1.11-winx64.zip", "3555641cea2da60435ab7f1681a94d1aa97341f1a0f52193adc82a83734818ca"),
    MacOS() => ("https://dev.mysql.com/get/Downloads/Connector-C/mysql-connector-c-6.1.11-macos10.12-x86_64.tar.gz", "c97d76936c6caf063778395e7ca15862770a1ab77c1731269408a8d5c0eb4b93"),
)
# First, check to see if we're all satisfied
if !satisfied(lib; verbose=true)
    if haskey(download_info, platform_key())
        # Download and install binaries
        url, tarball_hash = download_info[platform_key()]
        install(url, tarball_hash; prefix=prefix, force=true, verbose=true, ignore_platform=true)
    else
        # If we don't have a BinaryProvider-compatible .tar.gz to download, complain.
        # Alternatively, you could attempt to install from a separate provider,
        # build from source or something more even more ambitious here.
        error("Your platform $(Sys.MACHINE) is not supported by this package!")
    end
end
# Write out a deps.jl file that will contain mappings for our products
write_deps_file(joinpath(@__DIR__, "deps.jl"), [lib])
