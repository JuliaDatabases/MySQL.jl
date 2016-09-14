using MySQL
using Base.Test
using ConfParser

conf = ConfParse("server.ini")
parse_conf!(conf)

const HOST = retrieve(conf, "default", "host") |> parse
const USER = retrieve(conf, "default", "user") |> parse
const PASS = retrieve(conf, "default", "pass") |> parse

for file in ["test_basic.jl", "test_prep.jl", "test_multiquery.jl"]
    include(file)
end
