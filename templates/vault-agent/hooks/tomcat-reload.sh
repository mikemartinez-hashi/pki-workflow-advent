#!/bin/bash
# Converts Vault-issued cert to PKCS12 keystore for Tomcat
# Then reloads Tomcat without a full restart
#
# Atomic swap pattern: writes to a temp file first, then renames.
# Prevents a partial/failed export from leaving a corrupt keystore on disk.

set -eo pipefail
trap 'echo "[$(date)] ERROR: tomcat-reload.sh failed at line $LINENO" >&2' ERR

CERT_DIR="/etc/vault-agent/certs"
KEYSTORE_DIR="/opt/tomcat/conf"
KEYSTORE_PASS="${KEYSTORE_PASS:-changeit}"
KEYSTORE_FILE="${KEYSTORE_DIR}/vault-keystore.p12"
KEYSTORE_TMP="${KEYSTORE_FILE}.tmp"

echo "[$(date)] Converting cert to PKCS12 keystore..."

# Write to a temp file first so the live keystore is never half-written
openssl pkcs12 -export \
    -in "${CERT_DIR}/cert.pem" \
    -inkey "${CERT_DIR}/key.pem" \
    -certfile "${CERT_DIR}/chain.pem" \
    -out "${KEYSTORE_TMP}" \
    -passout "pass:${KEYSTORE_PASS}" \
    -name "vault-cert"

# Atomic promotion: mv is atomic within the same filesystem
mv "${KEYSTORE_TMP}" "${KEYSTORE_FILE}"
chmod 640 "${KEYSTORE_FILE}"

echo "[$(date)] Reloading Tomcat..."
systemctl reload tomcat 2>/dev/null || systemctl restart tomcat

echo "[$(date)] Tomcat cert rotation complete."
