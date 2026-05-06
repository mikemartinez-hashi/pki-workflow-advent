#!/bin/bash
# Simulates an external public CA (Sectigo stand-in)
# In production this CSR goes to Sectigo's portal instead

set -eo pipefail
trap 'echo "ERROR: setup-external-ca.sh failed at line $LINENO" >&2' ERR

CADIR="./external-ca/ca-data"

# ── Idempotency guard ──────────────────────────────────────────────────────
# Safe to re-run: if the CA cert already exists, skip initialization entirely.
if [ -f "$CADIR/certs/ca.crt" ]; then
  echo "[External CA] Already initialized — skipping."
  echo "[External CA] Delete $CADIR to re-initialize from scratch."
  echo ""
  echo "Existing External CA Certificate:"
  openssl x509 -in "$CADIR/certs/ca.crt" -noout -subject -issuer -dates
  exit 0
fi

mkdir -p "$CADIR"/{certs,crl,newcerts,private}
chmod 700 "$CADIR/private"
touch "$CADIR/index.txt"
echo 1000 > "$CADIR/serial"

cat > "$CADIR/openssl.cnf" << 'EOF'
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = CADIR_PLACEHOLDER
certs             = $dir/certs
new_certs_dir     = $dir/newcerts
database          = $dir/index.txt
serial            = $dir/serial
private_key       = $dir/private/ca.key
certificate       = $dir/certs/ca.crt
default_md        = sha256
policy            = policy_loose
default_days      = 1825

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
organizationName        = optional
commonName              = supplied

[ req ]
default_bits        = 4096
prompt              = no
default_md          = sha256
distinguished_name  = req_distinguished_name
x509_extensions     = v3_ca

[ req_distinguished_name ]
C  = US
ST = Florida
O  = Demo External CA
CN = Demo External CA (Sectigo Stand-In)

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, cRLSign, keyCertSign

[ v3_intermediate_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true, pathlen:0
keyUsage               = critical, cRLSign, keyCertSign
EOF

# Fix placeholder
sed -i "s|CADIR_PLACEHOLDER|$(pwd)/$CADIR|g" "$CADIR/openssl.cnf"

echo "[1/3] Generating External CA private key..."
openssl genrsa -out "$CADIR/private/ca.key" 4096
chmod 400 "$CADIR/private/ca.key"

echo "[2/3] Self-signing External CA certificate (10 years)..."
openssl req -config "$CADIR/openssl.cnf" \
    -key "$CADIR/private/ca.key" \
    -new -x509 -days 3650 \
    -extensions v3_ca \
    -out "$CADIR/certs/ca.crt"

echo "[3/3] External CA ready."
echo ""
echo "External CA Certificate:"
openssl x509 -in "$CADIR/certs/ca.crt" -noout -subject -issuer -dates
