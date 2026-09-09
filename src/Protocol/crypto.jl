# Thin OpenSSL_jll wrappers for the public-key operations the authentication plugins need.
# No asymmetric arithmetic is implemented here: OpenSSL supplies the OAEP randomness and
# the modular exponentiation. Every handle is freed in a `finally`; the error queue is
# cleared before each operation and read (redacted to OpenSSL's own text) on failure.

const EVP_PKEY_RSA = Cint(6)
const RSA_PKCS1_OAEP_PADDING = Cint(4)
const SHA1_DIGEST_LENGTH = 20
const OPENSSL_ERROR_TEXT_LENGTH = 256

function openssl_clear_errors()
    ccall((:ERR_clear_error, libcrypto), Cvoid, ())
    return nothing
end

function openssl_error_message()
    code = ccall((:ERR_get_error, libcrypto), Culong, ())
    code == 0 && return "unknown OpenSSL error"
    buf = Vector{UInt8}(undef, OPENSSL_ERROR_TEXT_LENGTH)
    ccall((:ERR_error_string_n, libcrypto), Cvoid, (Culong, Ptr{UInt8}, Csize_t), code, buf, length(buf))
    openssl_clear_errors()
    return GC.@preserve buf unsafe_string(pointer(buf))
end

@noinline openssl_failure(what::String) = return throw(AuthError("$what: $(openssl_error_message())"))

"""
    securezero!(v::Vector{UInt8})

Overwrites secret material (password-derived buffers) before it is discarded.
"""
function securezero!(v::Vector{UInt8})
    isempty(v) && return nothing
    GC.@preserve v ccall((:OPENSSL_cleanse, libcrypto), Cvoid, (Ptr{UInt8}, Csize_t), pointer(v), length(v))
    return nothing
end

"""
    with_rsa_public_key(f, pem) -> f(pkey)

Loads a PEM-encoded public key (SubjectPublicKeyInfo or `BEGIN RSA PUBLIC KEY`), checks that
it is an RSA key, runs `f` on the `EVP_PKEY*`, and frees it.
"""
function with_rsa_public_key(f::F, pem::AbstractVector{UInt8}) where {F}
    bytes = pem isa Vector{UInt8} ? pem : Vector{UInt8}(pem)
    openssl_clear_errors()
    # the memory BIO keeps pointing into `bytes` until BIO_free: preserve it for the whole scope
    GC.@preserve bytes begin
        bio = ccall((:BIO_new_mem_buf, libcrypto), Ptr{Cvoid}, (Ptr{UInt8}, Cint), pointer(bytes), length(bytes))
        bio == C_NULL && openssl_failure("OpenSSL could not allocate a memory BIO")
        pkey = C_NULL
        try
            pkey = ccall((:PEM_read_bio_PUBKEY, libcrypto), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, Ptr{Cvoid}), bio, C_NULL, C_NULL, C_NULL)
            pkey == C_NULL && openssl_failure("the server public key is not a valid PEM public key")
            base_id = ccall((:EVP_PKEY_get_base_id, libcrypto), Cint, (Ptr{Cvoid},), pkey)
            base_id == EVP_PKEY_RSA || throw(AuthError("the server public key is not an RSA key (OpenSSL key type $base_id)"))
            return f(pkey)
        finally
            pkey == C_NULL || ccall((:EVP_PKEY_free, libcrypto), Cvoid, (Ptr{Cvoid},), pkey)
            ccall((:BIO_free, libcrypto), Cint, (Ptr{Cvoid},), bio)
        end
    end
end

rsa_key_size(pkey::Ptr{Cvoid}) = return Int(ccall((:EVP_PKEY_get_size, libcrypto), Cint, (Ptr{Cvoid},), pkey))
rsa_key_bits(pkey::Ptr{Cvoid}) = return Int(ccall((:EVP_PKEY_get_bits, libcrypto), Cint, (Ptr{Cvoid},), pkey))

"""
    rsa_oaep_sha1_encrypt(pem, message) -> Vector{UInt8}

RSAES-OAEP with SHA-1 for both the OAEP digest and MGF1 (what MySQL's caching_sha2_password
and sha256_password expect). The ciphertext length equals the modulus length; `message` must
be at most `k - 2*20 - 2` bytes. OpenSSL draws the OAEP seed itself.
"""
function rsa_oaep_sha1_encrypt(pem::AbstractVector{UInt8}, message::Vector{UInt8})
    return with_rsa_public_key(pem) do pkey
        k = rsa_key_size(pkey)
        maxlen = k - 2 * SHA1_DIGEST_LENGTH - 2
        length(message) <= maxlen || throw(AuthError("the password is too long for the server's $(rsa_key_bits(pkey))-bit RSA key (at most $maxlen bytes)"))
        ctx = ccall((:EVP_PKEY_CTX_new, libcrypto), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}), pkey, C_NULL)
        ctx == C_NULL && openssl_failure("OpenSSL could not allocate an EVP_PKEY_CTX")
        try
            ccall((:EVP_PKEY_encrypt_init, libcrypto), Cint, (Ptr{Cvoid},), ctx) > 0 || openssl_failure("EVP_PKEY_encrypt_init failed")
            ccall((:EVP_PKEY_CTX_set_rsa_padding, libcrypto), Cint, (Ptr{Cvoid}, Cint), ctx, RSA_PKCS1_OAEP_PADDING) > 0 || openssl_failure("setting RSA OAEP padding failed")
            sha1 = ccall((:EVP_sha1, libcrypto), Ptr{Cvoid}, ())
            ccall((:EVP_PKEY_CTX_set_rsa_oaep_md, libcrypto), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), ctx, sha1) > 0 || openssl_failure("setting the OAEP digest failed")
            ccall((:EVP_PKEY_CTX_set_rsa_mgf1_md, libcrypto), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), ctx, sha1) > 0 || openssl_failure("setting the MGF1 digest failed")
            outlen = Ref{Csize_t}(0)
            GC.@preserve message begin
                ccall((:EVP_PKEY_encrypt, libcrypto), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Csize_t}, Ptr{UInt8}, Csize_t), ctx, C_NULL, outlen, pointer(message), length(message)) > 0 || openssl_failure("RSA encryption failed")
                out = Vector{UInt8}(undef, Int(outlen[]))
                ccall((:EVP_PKEY_encrypt, libcrypto), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Csize_t}, Ptr{UInt8}, Csize_t), ctx, out, outlen, pointer(message), length(message)) > 0 || openssl_failure("RSA encryption failed")
                resize!(out, Int(outlen[]))
                return out
            end
        finally
            ccall((:EVP_PKEY_CTX_free, libcrypto), Cvoid, (Ptr{Cvoid},), ctx)
        end
    end
end
