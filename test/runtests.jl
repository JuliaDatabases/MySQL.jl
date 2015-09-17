using MySQL
using Base.Test

# Change the below values to whatever it is on your test setup.
const HOST = "127.0.0.1"
const ROOTPASS = "root"

for file in ["test_basic.jl", ]
    include(file)
end
