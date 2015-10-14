using MySQL
using Base.Test

# Change the below values to whatever it is on your test setup.
const HOST = "127.0.0.1"
const ROOTPASS = "" # In Travis CI the root password is an empty string.

println("*** Cleanup (ignore these messages) ***\n")

try
    run(`echo -e 'drop database mysqltest;\ndrop user test@127.0.0.1;\n'`
        |> `mysql -u root`)
end

println()

for file in ["test_basic.jl", "test_prep.jl"]
    include(file)
end
