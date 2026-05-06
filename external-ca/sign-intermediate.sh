#!/bin/bash
# Called by setup-vault-pki.sh after generating the Vault intermediate CSR
# Simulates submitting the CSR to Sectigo and receiving a signed cert back

set -e
CADIR="./external-ca/ca-data"
CSR_FILE="$1"
OUTPUT_CERT="$2"

if [ ! -f "$CADIR/openssl.cnf" ]; then
    echo "[External CA] Infrastructure not found. Initializing ephemeral external CA..."
    bash ./scripts/setup-external-ca.sh
fi

echo "[External CA] Received CSR from Vault..."
echo "[External CA] Signing as subordinate CA (simulating Sectigo approval)..."

openssl ca -config "$CADIR/openssl.cnf" \
    -extensions v3_intermediate_ca \
    -days 1825 \
    -notext \
    -batch \
    -in "$CSR_FILE" \
    -out "$OUTPUT_CERT"

echo "[External CA] Signed certificate issued:"
openssl x509 -in "$OUTPUT_CERT" -noout -subject -issuer -dates
echo ""
echo "[External CA] NOTE: In production, this step is replaced by submitting"
echo "              the CSR to Sectigo's portal or REST API."
echo "              The resulting signed cert is then imported back into Vault."
