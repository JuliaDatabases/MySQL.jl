using MySQL
using Base.Test

# Change the below values to whatever it is on your test setup.
const HOST = "127.0.0.1"
const ROOTPASS = "" # In Travis CI the root password is an empty string.

for file in ["test_basic.jl", "test_prep.jl", "test_multiquery.jl", "test_dbapi.jl"]
    include(file)
end
