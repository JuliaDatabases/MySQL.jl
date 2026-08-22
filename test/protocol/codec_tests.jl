@testset "codec" begin
    @testset "fixed-length integers round-trip" begin
        buf = UInt8[]
        P.write_u8!(buf, 0xAB)
        P.write_u16!(buf, 0xBEEF)
        P.write_u24!(buf, 0x00FFFFFF)
        P.write_u32!(buf, 0xDEADBEEF)
        P.write_u64!(buf, 0x0123456789ABCDEF)
        @test length(buf) == 1 + 2 + 3 + 4 + 8
        c = P.PacketCursor(buf)
        @test P.read_u8!(c) == 0xAB
        @test P.read_u16!(c) == 0xBEEF
        @test P.read_u24!(c) == 0x00FFFFFF
        @test P.read_u32!(c) == 0xDEADBEEF
        @test P.read_u64!(c) == 0x0123456789ABCDEF
        @test P.atend(c)
        @test_throws P.ProtocolError P.read_u8!(c)
        # little-endian byte order
        @test buf[2:3] == [0xEF, 0xBE]
    end

    @testset "length-encoded integers at the boundaries" begin
        for (value, size) in ((0, 1), (250, 1), (251, 3), (65535, 3), (65536, 4), (2^24 - 1, 4), (2^24, 9), (typemax(UInt64), 9))
            buf = UInt8[]
            P.write_lenenc!(buf, value)
            @test length(buf) == size == P.lenenc_size(value)
            @test P.read_lenenc!(P.PacketCursor(buf)) == UInt64(value)
        end
        @test P.read_lenenc!(P.PacketCursor(UInt8[0xFC, 0xFB, 0x00])) == 251
        @test P.read_lenenc!(P.PacketCursor(UInt8[0xFD, 0x00, 0x00, 0x01])) == 65536
        @test_throws P.ProtocolError P.read_lenenc!(P.PacketCursor(UInt8[0xFB]))
        @test_throws P.ProtocolError P.read_lenenc!(P.PacketCursor(UInt8[0xFF]))
        @test_throws P.ProtocolError P.read_lenenc!(P.PacketCursor(UInt8[0xFC, 0x01]))
        @test_throws P.ProtocolError P.read_lenenc!(P.PacketCursor(UInt8[0xFE, 1, 2, 3, 4, 5, 6, 7]))
    end

    @testset "strings" begin
        buf = UInt8[]
        P.write_lenenc_string!(buf, "héllo")
        P.write_nul_string!(buf, "nul")
        P.write_string!(buf, "tail")
        c = P.PacketCursor(buf)
        @test P.read_lenenc_string!(c) == "héllo"
        @test P.read_nul_string!(c) == "nul"
        @test P.read_eof_string!(c) == "tail"
        @test P.atend(c)
        @test P.read_eof_string!(c) == ""
        @test_throws ArgumentError P.write_nul_string!(UInt8[], "a\0b")
        # a lenenc string longer than the packet is rejected before allocation
        @test_throws P.ProtocolError P.read_lenenc_string!(P.PacketCursor(UInt8[0x05, 0x61]))
        @test_throws P.ProtocolError P.read_nul_string!(P.PacketCursor(UInt8[0x61, 0x62]))
        @test_throws P.ProtocolError P.read_nul_string!(P.PacketCursor(UInt8[]))
        @test_throws P.ProtocolError P.read_fixed_bytes!(P.PacketCursor(UInt8[1, 2]), 3)
        @test P.read_lenenc_bytes!(P.PacketCursor(UInt8[0x00])) == UInt8[]
        @test P.read_lenenc_string!(P.PacketCursor(UInt8[0x00])) == ""
        # windows are relative to the cursor's range, not the whole buffer
        c = P.PacketCursor(UInt8[0xAA, 0x02, 0x68, 0x69, 0xBB], 2, 4)
        @test P.read_lenenc_string!(c) == "hi"
        @test P.atend(c)
    end

    @testset "Limits validation" begin
        @test P.Limits().max_packet == 16 * 1024 * 1024
        @test P.Limits(; max_packet=1024).max_preauth_packet == 1024
        @test_throws ArgumentError P.Limits(; max_packet=0)
        @test_throws ArgumentError P.Limits(; max_packet=2 * 1024 * 1024 * 1024)
        @test_throws ArgumentError P.Limits(; max_preauth_packet=2 * P.DEFAULT_MAX_PACKET)
        @test_throws ArgumentError P.Limits(; max_buffered_bytes=0)
        @test P.Limits(; max_buffered_bytes=nothing, max_response_bytes=10).max_buffered_bytes === nothing
    end
end
