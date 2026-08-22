const libcrypto = P.libcrypto

const CERTS = joinpath(@__DIR__, "certs")
certfile(name) = joinpath(CERTS, name)
pem(name) = read(certfile(name))

# Test-side RSAES-OAEP(SHA-1) decryption through the same OpenSSL library.
function rsa_oaep_decrypt(private_pem::Vector{UInt8}, ciphertext::Vector{UInt8})
    bio = ccall((:BIO_new_mem_buf, libcrypto), Ptr{Cvoid}, (Ptr{UInt8}, Cint), private_pem, length(private_pem))
    pkey = ccall((:PEM_read_bio_PrivateKey, libcrypto), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, Ptr{Cvoid}), bio, C_NULL, C_NULL, C_NULL)
    pkey == C_NULL && error("cannot load private key")
    ctx = ccall((:EVP_PKEY_CTX_new, libcrypto), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}), pkey, C_NULL)
    try
        ccall((:EVP_PKEY_decrypt_init, libcrypto), Cint, (Ptr{Cvoid},), ctx) > 0 || error("decrypt_init")
        ccall((:EVP_PKEY_CTX_set_rsa_padding, libcrypto), Cint, (Ptr{Cvoid}, Cint), ctx, P.RSA_PKCS1_OAEP_PADDING) > 0 || error("padding")
        sha1 = ccall((:EVP_sha1, libcrypto), Ptr{Cvoid}, ())
        ccall((:EVP_PKEY_CTX_set_rsa_oaep_md, libcrypto), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), ctx, sha1) > 0 || error("oaep md")
        ccall((:EVP_PKEY_CTX_set_rsa_mgf1_md, libcrypto), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), ctx, sha1) > 0 || error("mgf1 md")
        outlen = Ref{Csize_t}(0)
        ccall((:EVP_PKEY_decrypt, libcrypto), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Csize_t}, Ptr{UInt8}, Csize_t), ctx, C_NULL, outlen, ciphertext, length(ciphertext)) > 0 || error("decrypt size")
        out = Vector{UInt8}(undef, Int(outlen[]))
        ccall((:EVP_PKEY_decrypt, libcrypto), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Csize_t}, Ptr{UInt8}, Csize_t), ctx, out, outlen, ciphertext, length(ciphertext)) > 0 || error("decrypt failed")
        return resize!(out, Int(outlen[]))
    finally
        ccall((:EVP_PKEY_CTX_free, libcrypto), Cvoid, (Ptr{Cvoid},), ctx)
        ccall((:EVP_PKEY_free, libcrypto), Cvoid, (Ptr{Cvoid},), pkey)
        ccall((:BIO_free, libcrypto), Cint, (Ptr{Cvoid},), bio)
    end
end

@testset "RSA-OAEP via OpenSSL" begin
    for bits in (2048, 3072, 4096)
        pub = pem("rsa$bits.pub")
        priv = pem("rsa$bits.key")
        msg = Vector{UInt8}(codeunits("correct horse battery staple\0"))
        c1 = P.rsa_oaep_sha1_encrypt(pub, msg)
        c2 = P.rsa_oaep_sha1_encrypt(pub, msg)
        @test length(c1) == bits ÷ 8 == length(c2)
        @test c1 != c2                                   # fresh OAEP seed every time
        @test rsa_oaep_decrypt(priv, c1) == msg
        @test rsa_oaep_decrypt(priv, c2) == msg
        maxlen = bits ÷ 8 - 2 * 20 - 2
        @test rsa_oaep_decrypt(priv, P.rsa_oaep_sha1_encrypt(pub, zeros(UInt8, maxlen))) == zeros(UInt8, maxlen)
        @test_throws P.AuthError P.rsa_oaep_sha1_encrypt(pub, zeros(UInt8, maxlen + 1))
    end
    @test_throws P.AuthError P.rsa_oaep_sha1_encrypt(Vector{UInt8}(codeunits("-----BEGIN PUBLIC KEY-----\ngarbage\n-----END PUBLIC KEY-----\n")), UInt8[1])
    @test_throws P.AuthError P.rsa_oaep_sha1_encrypt(UInt8[], UInt8[1])
    err = try; P.rsa_oaep_sha1_encrypt(pem("ec.pub"), UInt8[1]); nothing; catch e; e; end
    @test err isa P.AuthError && occursin("not an RSA key", err.msg)
    # the password exchange helper: (pw ‖ NUL) XOR nonce, recoverable with the private key
    nonce = collect(UInt8, 1:20)
    pw = Vector{UInt8}(codeunits("s3cret"))
    ct = P.rsa_encrypt_password(pw, nonce, pem("rsa2048.pub"))
    masked = rsa_oaep_decrypt(pem("rsa2048.key"), ct)
    @test length(masked) == length(pw) + 1
    @test [masked[i] ⊻ nonce[mod1(i, 20)] for i in eachindex(masked)] == vcat(pw, 0x00)
    @test_throws P.AuthError P.rsa_encrypt_password(pw, UInt8[], pem("rsa2048.pub"))
    # repeated encryption must not leak OpenSSL handles
    GC.gc()
    before = Sys.maxrss()
    for _ in 1:20_000
        P.rsa_oaep_sha1_encrypt(pem("rsa2048.pub"), UInt8[0x01, 0x02])
    end
    GC.gc()
    @test Sys.maxrss() - before < 16 * 1024 * 1024
    buf = UInt8[1, 2, 3]
    P.securezero!(buf)
    @test buf == UInt8[0, 0, 0]
end
