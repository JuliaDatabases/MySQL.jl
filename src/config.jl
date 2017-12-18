# This snippet is  taken from https://github.com/Dynactionize/MariaDB.jl
# This the configuration file for finding the shared  object (dll) file
# for MySQL/MariaDB API.  Make sure to add the location  of the files to
# path for this to work.
#
# TODO: Need to update lib_choices for Mac OS X and Windows.

@static if !isdefined(Base, Symbol("@isdefined"))
macro isdefined(x)
    esc(:(isdefined($x)))
end
end

let
    global mysql_lib
    succeeded = false
    if !@isdefined(:mysql_lib)
        @static Compat.Sys.islinux() ? (lib_choices = ["libmysql.so", "libmysqlclient.so",
                                             "libmysqlclient_r.so", "libmariadb.so",
                                             "libmysqlclient_r.so.16"]) : nothing
        @static Compat.Sys.isapple() ? (lib_choices = ["libmysqlclient.dylib", "libperconaserverclient.dylib"]) : nothing
        @static Compat.Sys.iswindows() ? (lib_choices = ["libmysql.dll", "libmariadb.dll"]) : nothing
        local lib
        for lib in lib_choices
            try
                Libdl.dlopen(lib)
                succeeded = true
                break
            end
        end
        succeeded || error("MySQL library not found")
        @eval const mysql_lib = $lib
    end
end
