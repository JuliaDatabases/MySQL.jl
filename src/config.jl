# This snippet is  taken from https://github.com/Dynactionize/MariaDB.jl
# This the configuration  file for finding the shared  object (dll) file
# for MySQL/MariaDB API.  Make sure to add the location  of the files to
# path for this to work.
# 
# TODO: Need to update lib_choices for Mac OS X and Windows.

let
    global mysql_lib
    succeeded = false
    if !isdefined(:mysql_lib)
        @static is_linux() ? (lib_choices = ["libmysql.so", "libmysqlclient.so",
                                             "libmysqlclient_r.so", "libmariadb.so",
                                             "libmysqlclient_r.so.16"]) : nothing
        @static is_apple() ? (lib_choices = ["libmysqlclient.dylib"]) : nothing
        @static is_windows() ? (lib_choices = ["libmysql.dll", "libmariadb.dll"]) : nothing
        local lib
        for lib in lib_choices
            try
                Libdl.dlopen(lib)
                succeeded = true
                break
            end
        end
        succeeded || error("MYSQL library not found")
        @eval const mysql_lib = $lib
    end
end

