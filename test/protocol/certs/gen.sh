#!/bin/sh
# Regenerates the test PKI and RSA fixtures (10-year validity). Requires OpenSSL 3.
set -e
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -keyout ca.key -out ca.crt \
  -subj "/CN=MySQL.jl Test CA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
gen_leaf() { # name subject san extendedKeyUsage
  openssl req -newkey rsa:2048 -nodes -sha256 -keyout "$1.key" -out "$1.csr" -subj "$2" 2>/dev/null
  printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=%s\nsubjectAltName=%s\n" "$4" "$3" > "$1.ext"
  openssl x509 -req -sha256 -days 3650 -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "$1.crt" -extfile "$1.ext" 2>/dev/null
  rm -f "$1.csr" "$1.ext"
}
gen_leaf server "/CN=localhost" "DNS:localhost,IP:127.0.0.1" serverAuth
gen_leaf server-dnsonly "/CN=localhost" "DNS:localhost" serverAuth
gen_leaf client "/CN=mysql-jl-client" "DNS:client.invalid" clientAuth
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -keyout selfsigned.key -out selfsigned.crt \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
for bits in 2048 3072 4096; do
  openssl genrsa -out rsa$bits.key $bits 2>/dev/null
  openssl rsa -in rsa$bits.key -pubout -out rsa$bits.pub 2>/dev/null
done
openssl ecparam -name prime256v1 -genkey -noout -out ec.key 2>/dev/null
openssl ec -in ec.key -pubout -out ec.pub 2>/dev/null
rm -f ca.srl
