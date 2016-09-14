using BinDeps
using Compat

@BinDeps.setup

libmysqlclient = library_dependency("libmysqlclient",
                                    alias=["libmysqlclient.so",
                                           "libmysqlclient.dylib",
                                           "libmysql.dll"])

provides(AptGet, Dict("libmysqlclient-dev" => libmysqlclient))
provides(Yum, "mysql-devel", libmysqlclient)
provides(Pacman, "mariadb", libmysqlclient)

if is_apple()
    if Pkg.installed("Homebrew") === nothing
        error("Homebrew package not installed, please run Pkg.add(\"Homebrew\")")
    end
    using Homebrew
    provides(Homebrew.HB, "libmysqlclient", libmysqlclient, os = :Darwin)
end

if is_windows()
    using WinRPM
    provides(WinRPM.RPM, "libmysqlclient", libmysqlclient, os = :Windows)
end

@BinDeps.install Dict(:libmysqlclient => :libmysqlclient)
