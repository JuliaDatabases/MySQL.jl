# DecFP interop through the package extension (ext/MySQLDecFPExt.jl). 1.x decoded DECIMAL
# columns to `Dec64`, so `DecFP` values stay bindable as parameters and loadable with
# `MySQL.load`; results decode to `MySQL.DecimalResult`. Needs no server.
using Test, MySQL, DecFP

@testset "DecFP extension" begin
    @test Base.get_extension(MySQL, :MySQLDecFPExt) !== nothing
    P = MySQL.Protocol
    @test MySQL.param_signature(Any[d64"12.3", Dec128("4.5"), Dec32("1")]) == fill(UInt16(P.MYSQL_TYPE_STRING), 3)
    for x in (d64"12.345", Dec128("12345678901234567890123456789.123456"), Dec32("-1.5"))
        buf = UInt8[]
        MySQL.encode_param_value!(buf, x)
        c = P.PacketCursor(buf)
        @test P.read_lenenc_string!(c) == string(x)
        @test P.atend(c)
    end
    @test MySQL.sqltype(Union{Missing, Dec64}) == "NUMERIC(16, 6)"
    @test MySQL.sqltype(Dec128) == "NUMERIC(35, 6)"
    @test MySQL.sqltype(Dec32) == "VARCHAR(255)"
    # results never decode to DecFP types
    @test MySQL.juliatype(P.MYSQL_TYPE_NEWDECIMAL) === MySQL.DecimalResult
end
