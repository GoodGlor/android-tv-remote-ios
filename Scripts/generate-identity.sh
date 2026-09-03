#!/bin/bash
# Generates the app's single client identity for Android TV pairing.
# Run ONCE (artifacts are committed); re-run only to rotate the identity,
# which un-pairs every TV.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/RemoteCore/Sources/RemoteCore/Resources"
mkdir -p "$DIR"
cd "$DIR"

# RSA-2048 is REQUIRED: the pairing secret hash uses RSA modulus/exponent.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout client.key -out client.pem \
  -subj "/CN=RemoteControl/O=artem"

openssl x509 -in client.pem -outform der -out client.der

# SHA1-3DES parameters: OpenSSL 3's AES default breaks SecPKCS12Import.
openssl pkcs12 -export -out client.p12 -inkey client.key -in client.pem \
  -passout pass:atvremote \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

rm client.key client.pem
echo "Generated $DIR/client.p12 and client.der"
