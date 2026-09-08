using Test, MySQL, DataDecimals
@testset "Exact shared decimals" begin
    D = DataDecimals.DecimalValue{DataDecimals.Int256}
    opts = MySQL.ResultOptions()
    @test MySQL.juliatype(MySQL.Protocol.MYSQL_TYPE_NEWDECIMAL) === D
    for s in ("12345678901234567890123456789012345678901234567890123456789012345.1234",
              "-0.000000000000000000000000000001", "0.00")
        bytes = collect(codeunits(s))
        expected = parse(D, s)
        @test MySQL.decode_value(D, bytes, 1, length(bytes), opts) === expected
        @test MySQL.decode_binary_value(D, bytes, 1, length(bytes), opts) === expected
        @test string(expected) == s
    end
    for s in ("NaN", "Inf", "12.\0oops", "1.2x")
        bytes = collect(codeunits(s))
        @test_throws MySQL.Protocol.ConversionError MySQL.decode_value(D, bytes, 1, length(bytes), opts)
    end
    @test MySQL.sqltype(DataDecimals.Decimal{18,2,Int64}) == "DECIMAL(18, 2)"
    @test_throws ArgumentError MySQL.sqltype(D)
    @test MySQL.sqltype(D, Dict(:x=>"DECIMAL(65, 30)"), :x) == "DECIMAL(65, 30)"
    x = DataDecimals.Decimal64{2}("12.34")
    bytes = UInt8[]
    MySQL.encode_param_value!(bytes, x)
    @test bytes == [0x05; codeunits("12.34")]
end
