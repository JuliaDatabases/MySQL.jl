# In-memory framing tests over FaultTransport(IOBuffer): no sockets needed.
framed(seq, payload) = vcat(UInt8[length(payload) & 0xFF, (length(payload) >> 8) & 0xFF, (length(payload) >> 16) & 0xFF, seq], payload)

function reader_over(bytes::Vector{UInt8})
    return P.PacketIO(), P.FaultTransport(IOBuffer(bytes))
end

@testset "packet framing" begin
    @testset "single packet" begin
        io, t = reader_over(framed(0x00, UInt8[1, 2, 3]))
        p = P.readpacket!(io, t, 1024)
        @test P.payload(p) == UInt8[1, 2, 3]
        @test p.seq == 0x00 && p.nchunks == 1 && p.first_chunk_len == 3
        @test io.seq == 0x01
        @test io.response_bytes == 3
    end

    @testset "reassembly of 0xFFFFFF + 5 bytes" begin
        big = rand(UInt8, P.MAX_CHUNK + 5)
        bytes = vcat(framed(0x00, big[1:P.MAX_CHUNK]), framed(0x01, big[(P.MAX_CHUNK + 1):end]))
        io, t = reader_over(bytes)
        p = P.readpacket!(io, t, 32 * 1024 * 1024)
        @test P.payload_length(p) == P.MAX_CHUNK + 5
        @test P.payload(p) == big
        @test p.nchunks == 2 && p.first_chunk_len == P.MAX_CHUNK
        @test io.seq == 0x02
    end

    @testset "exact multiple ends with an empty chunk" begin
        big = rand(UInt8, P.MAX_CHUNK)
        bytes = vcat(framed(0x00, big), framed(0x01, UInt8[]))
        io, t = reader_over(bytes)
        p = P.readpacket!(io, t, 32 * 1024 * 1024)
        @test P.payload_length(p) == P.MAX_CHUNK && p.nchunks == 2
        @test P.payload(p) == big
    end

    @testset "sequence ids are validated and wrap" begin
        io, t = reader_over(framed(0x05, UInt8[1]))
        @test_throws P.ProtocolError P.readpacket!(io, t, 1024)
        io = P.PacketIO()
        io.seq = 0xFF
        t = P.FaultTransport(IOBuffer(vcat(framed(0xFF, UInt8[1]), framed(0x00, UInt8[2]))))
        @test P.payload(P.readpacket!(io, t, 1024)) == UInt8[1]
        @test P.payload(P.readpacket!(io, t, 1024)) == UInt8[2]
        @test io.seq == 0x01
    end

    @testset "declared length is checked before the body is read" begin
        # only a header announcing 2 MiB is present; the limit must fire, not an EOF
        io, t = reader_over(UInt8[0x00, 0x00, 0x20, 0x00])
        err = try; P.readpacket!(io, t, 1024 * 1024); nothing; catch e; e; end
        @test err isa P.ProtocolError
        @test occursin("exceeds limit", err.msg)
        # aggregate response bound
        io, t = reader_over(vcat(framed(0x00, zeros(UInt8, 40)), framed(0x01, zeros(UInt8, 40))))
        @test P.payload_length(P.readpacket!(io, t, 1024; max_response=64)) == 40
        @test_throws P.ProtocolError P.readpacket!(io, t, 1024; max_response=64)
    end

    @testset "aggregate response accounting does not overflow Int" begin
        io, t = reader_over(framed(0x00, UInt8[0x01, 0x02]))
        io.response_bytes = UInt64(typemax(Int))
        @test P.payload_length(P.readpacket!(io, t, 1024)) == 2
        @test io.response_bytes == UInt64(typemax(Int)) + 2
        P.newcommand!(io)
        @test io.response_bytes == 0
    end

    @testset "writer framing" begin
        function frames(payload)
            out = IOBuffer()
            io = P.PacketIO()
            P.sendpacket!(io, P.FaultTransport(out), payload)
            return take!(out), io.seq
        end
        bytes, seq = frames(UInt8[])
        @test bytes == UInt8[0, 0, 0, 0] && seq == 0x01
        bytes, seq = frames(UInt8[0x10])
        @test bytes == UInt8[1, 0, 0, 0, 0x10] && seq == 0x01
        bytes, seq = frames(zeros(UInt8, P.MAX_CHUNK))
        @test length(bytes) == 4 + P.MAX_CHUNK + 4
        @test bytes[1:4] == UInt8[0xFF, 0xFF, 0xFF, 0x00]
        @test bytes[(end - 3):end] == UInt8[0, 0, 0, 0x01]
        @test seq == 0x02
        bytes, seq = frames(zeros(UInt8, P.MAX_CHUNK + 1))
        @test bytes[(end - 4):end] == UInt8[1, 0, 0, 0x01, 0]
        @test seq == 0x02
        @test P.chunk_count(0) == 1 && P.chunk_count(P.MAX_CHUNK - 1) == 1 && P.chunk_count(P.MAX_CHUNK) == 2
        # the sequence continues across calls and wraps
        io = P.PacketIO()
        io.seq = 0xFF
        out = IOBuffer()
        P.sendpacket!(io, P.FaultTransport(out), UInt8[1])
        @test take!(out)[4] == 0xFF && io.seq == 0x00
    end

    @testset "FaultTransport injection points" begin
        inner = IOBuffer(framed(0x00, UInt8[1, 2, 3]))
        t = P.FaultTransport(inner; fail_read_at=2, read_error=EOFError())
        io = P.PacketIO()
        @test_throws EOFError P.readpacket!(io, t, 1024)
        @test t.read_bytes == 2
        out = IOBuffer()
        t = P.FaultTransport(out; fail_write_at=3, write_error=InterruptException())
        @test_throws InterruptException P.sendpacket!(P.PacketIO(), t, UInt8[9, 9])
        @test length(take!(out)) == 3   # short write: header truncated after 3 bytes
        out = IOBuffer()
        t = P.FaultTransport(out; after_write_error=InterruptException())
        @test_throws InterruptException P.sendpacket!(P.PacketIO(), t, UInt8[9, 9])
        @test take!(out) == UInt8[2, 0, 0, 0, 9, 9]   # written in full before the fault
    end
end
