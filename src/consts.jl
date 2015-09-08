# Configuration: Specify the right path where the mysql library is present.
@windows_only const mysql_lib = "C:/apps/mysql-5.6.13-winx64/lib/libmysql.dll"
@linux_only const mysql_lib = "/usr/lib64/libmysqlclient.so.18.0.0"
@osx_only const mysql_lib = "/usr/local/mysql-5.6.26-osx10.8-x86_64/lib/libmysqlclient.dylib"

# Alternatively, figure out what the path is from possible dynamic libraries.
# Commented out for now.
# This snippet is taken from https://github.com/Dynactionize/MariaDB.jl
#=
let
    global mysql_lib
    succeeded = false
    if !isdefined(:mysql_lib)
        @linux_only   lib_choices = ["libmysql", "libmysql.so", "libmysql.so.1",
                                     "libmysql.so.2", "libmysql.so.3"]
        @windows_only lib_choices = ["mysql32"]
        @osx_only     lib_choices = ["libmysql.dylib", "libimysql", "libimysql.dylib",
                                     "libimysql.1.dylib", "libimysql.2.dylib", "libimysql.3.dylib"]
        local lib
        for lib in lib_choices
            try
                dlopen(lib)
                succeeded = true
                break
            end
        end
        succeeded || error("MYSQL library not found")
        @eval const mysql_lib = $lib
    end
end
=#
