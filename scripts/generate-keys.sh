#!/bin/bash

KEY_DIR="../../keys"

# Generate RSA 2048-bit private key
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ${KEY_DIR}/private_key.pem

# Convert private key to DER
openssl rsa -in ${KEY_DIR}/private_key.pem -outform DER -out ${KEY_DIR}/private_key.der

# Extract public key
openssl rsa -in ${KEY_DIR}/private_key.pem -pubout -out ${KEY_DIR}/public_key.pem

# Convert public key to DER
openssl rsa -in ${KEY_DIR}/private_key.pem -pubout -outform DER -out ${KEY_DIR}/public_key.der

# Detect base64 type (GNU vs BSD)
if base64 --help 2>&1 | grep -q "\-w"; then
    ZETARIS_PRIVATE_KEY_DER=$(base64 -w0 ${KEY_DIR}/private_key.der)
    ZETARIS_PUBLIC_KEY_DER=$(base64 -w0 ${KEY_DIR}/public_key.der)
else
    ZETARIS_PRIVATE_KEY_DER=$(base64 < ${KEY_DIR}/private_key.der)
    ZETARIS_PUBLIC_KEY_DER=$(base64 < ${KEY_DIR}/public_key.der)
fi

# Write base64 encoded keys to files
echo "$ZETARIS_PRIVATE_KEY_DER" > ${KEY_DIR}/private_key_zetaris.der.b64
echo "$ZETARIS_PUBLIC_KEY_DER" > ${KEY_DIR}/public_key_zetaris.der.b64

echo "Keys generated successfully!"
echo "Private key (DER base64): ${KEY_DIR}/private_key_zetaris.der.b64"
echo "Public key (DER base64): ${KEY_DIR}/public_key_zetaris.der.b64"
echo ""
echo "$ZETARIS_PRIVATE_KEY_DER"
echo "$ZETARIS_PUBLIC_KEY_DER"