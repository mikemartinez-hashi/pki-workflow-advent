#!/bin/bash
# ============================================================
# End-User Certificate Request via Vault CLI
# Demonstrates what a developer or ops engineer runs
# to request a certificate from Vault on demand
# ============================================================

echo "=== Vault Certificate Request ==="
echo "This simulates what an end user or pipeline runs"
echo "to request a certificate from Vault."
echo ""

# Option 1: CLI request (simplest)
echo "--- Option 1: CLI ---"
vault write -format=json pki_int/issue/manual-role \
    common_name="myapp.demo.internal" \
    alt_names="myapp-dr.demo.internal" \
    ttl="720h" \
    | tee /tmp/cert-request.json

# Extract cert, key, and chain
jq -r '.data.certificate'  /tmp/cert-request.json > /tmp/myapp.crt
jq -r '.data.private_key'  /tmp/cert-request.json > /tmp/myapp.key
jq -r '.data.ca_chain[]'   /tmp/cert-request.json > /tmp/myapp-chain.pem

echo ""
echo "--- Cert details ---"
openssl x509 -in /tmp/myapp.crt -noout -subject -issuer -dates

echo ""
echo "--- Option 2: API (what pipelines use) ---"
cat << 'APIEXAMPLE'
curl --header "X-Vault-Token: $VAULT_TOKEN" \
     --header "X-Vault-Namespace: admin" \
     --request POST \
     --data '{"common_name":"myapp.demo.internal","ttl":"720h"}' \
     $VAULT_ADDR/v1/pki_int/issue/manual-role
APIEXAMPLE

echo ""
echo "--- Option 3: Vault UI ---"
echo "Navigate to: ${VAULT_ADDR}/ui/vault/secrets/pki_int/pki/create"
echo "Select role: manual-role"
echo "Enter CN:    myapp.demo.internal"
echo "Click:       Generate"

echo ""
echo "--- Serial Number Cross-Reference ---"
echo "OpenSSL serial (colon-separated):"
openssl x509 -in /tmp/myapp.crt -noout -serial

echo ""
echo "Convert to Vault format (hyphen-separated):"
openssl x509 -in /tmp/myapp.crt -noout -serial \
  | cut -d= -f2 \
  | sed 's/../&-/g;s/-$//' \
  | tr '[:upper:]' '[:lower:]'

echo ""
echo "Look up cert in Vault by serial:"
SERIAL=$(openssl x509 -in /tmp/myapp.crt -noout -serial \
  | cut -d= -f2 \
  | sed 's/../&-/g;s/-$//' \
  | tr '[:upper:]' '[:lower:]')
echo "vault read pki_int/cert/${SERIAL}"

echo ""
echo "Revoke cert by serial:"
echo "vault write pki_int/revoke serial_number=\"${SERIAL}\""
