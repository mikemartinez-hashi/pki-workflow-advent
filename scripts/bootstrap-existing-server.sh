#!/bin/bash
# ============================================================
# Vault Agent Bootstrap for Existing (Non-Terraform) Servers
# Run this once on any existing server to enroll in Vault PKI
#
# Supports: Debian/Ubuntu (apt-get) and RHEL/Amazon Linux (yum/dnf)
# ============================================================
set -eo pipefail
trap 'echo "ERROR: bootstrap failed at line $LINENO" >&2' ERR

# ── Config (set these before running) ─────────────────────
VAULT_ADDR="${VAULT_ADDR:?Set VAULT_ADDR}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"
ROLE_ID="${ROLE_ID:?Set ROLE_ID}"
SECRET_ID="${SECRET_ID:?Set SECRET_ID}"
COMMON_NAME="${COMMON_NAME:?Set COMMON_NAME e.g. myserver.demo.internal}"
VAULT_PKI_ROLE_PATH="${VAULT_PKI_ROLE_PATH:-pki_int/issue/manual-role}"
CERT_TTL="${CERT_TTL:-720h}"
PLATFORM="${PLATFORM:-apache}"    # apache | tomcat | nginx
VAULT_DIR="/etc/vault-agent"
CERT_DIR="${VAULT_DIR}/certs"
TPL_DIR="${VAULT_DIR}/tpl"

echo "========================================"
echo " Vault Agent Bootstrap (Existing Server)"
echo " Server:   $(hostname)"
echo " CN:       ${COMMON_NAME}"
echo " Platform: ${PLATFORM}"
echo "========================================"

# ── Install Vault ──────────────────────────────────────────
echo "[1/6] Installing Vault..."
if ! command -v vault &>/dev/null; then
    if command -v apt-get &>/dev/null; then
        # Debian / Ubuntu
        curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor \
            -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
            https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/hashicorp.list
        apt-get update -qq && apt-get install -y vault
    elif command -v dnf &>/dev/null; then
        # RHEL 8+ / Amazon Linux 2023
        dnf install -y yum-utils
        yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
        dnf install -y vault
    elif command -v yum &>/dev/null; then
        # Amazon Linux 2 / CentOS 7
        yum install -y yum-utils
        yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
        yum install -y vault
    else
        echo "ERROR: Unsupported package manager. Install Vault manually and re-run." >&2
        exit 1
    fi
fi
echo "Vault $(vault version) installed."

# ── Create directories ─────────────────────────────────────
echo "[2/6] Creating Vault Agent directories..."
mkdir -p "${VAULT_DIR}" "${CERT_DIR}" "${TPL_DIR}"
chmod 750 "${VAULT_DIR}" "${CERT_DIR}"

# ── Write credentials ──────────────────────────────────────
echo "[3/6] Writing AppRole credentials..."
echo -n "${ROLE_ID}"   > "${VAULT_DIR}/role_id"
echo -n "${SECRET_ID}" > "${VAULT_DIR}/secret_id"
chmod 600 "${VAULT_DIR}/role_id" "${VAULT_DIR}/secret_id"

# ── Write templates ────────────────────────────────────────
echo "[4/6] Writing Vault Agent templates..."
# NOTE: These templates reference env vars (VAULT_PKI_ROLE_PATH, VAULT_COMMON_NAME,
# VAULT_CERT_TTL) that Vault Agent resolves from the process environment at runtime.
# These are set in the systemd [Service] block below via Environment= directives.

cat > "${TPL_DIR}/cert.tpl" << 'EOF'
{{- with secret (env "VAULT_PKI_ROLE_PATH") "common_name=" (env "VAULT_COMMON_NAME") "ttl=" (env "VAULT_CERT_TTL") -}}
{{ .Data.certificate -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
EOF

cat > "${TPL_DIR}/key.tpl" << 'EOF'
{{- with secret (env "VAULT_PKI_ROLE_PATH") "common_name=" (env "VAULT_COMMON_NAME") "ttl=" (env "VAULT_CERT_TTL") -}}
{{ .Data.private_key -}}
{{- end }}
EOF

# ── Write agent config ─────────────────────────────────────
echo "[5/6] Writing Vault Agent config..."

case "${PLATFORM}" in
  apache) EXEC_CMD='["systemctl", "reload", "apache2"]'
          EXEC_TIMEOUT="30s" ;;
  tomcat) EXEC_CMD='["/etc/vault-agent/hooks/tomcat-reload.sh"]'
          EXEC_TIMEOUT="60s" ;;
  nginx)  EXEC_CMD='["systemctl", "reload", "nginx"]'
          EXEC_TIMEOUT="30s" ;;
  *)      EXEC_CMD='["echo", "cert-renewed"]'
          EXEC_TIMEOUT="10s" ;;
esac

cat > "${VAULT_DIR}/vault-agent.hcl" << EOF
vault {
  address   = "${VAULT_ADDR}"
  namespace = "${VAULT_NAMESPACE}"
  retry {
    num_retries = 5
  }
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path   = "${VAULT_DIR}/role_id"
      secret_id_file_path = "${VAULT_DIR}/secret_id"
    }
  }
  sink "file" {
    config = { path = "${VAULT_DIR}/vault-token" }
  }
}

template_config {
  static_secret_render_interval = "5m"
  exit_on_retry_failure         = true
}

template {
  source               = "${TPL_DIR}/cert.tpl"
  destination          = "${CERT_DIR}/cert.pem"
  perms                = 0644
  error_on_missing_key = true
  exec { command = ${EXEC_CMD}; timeout = "${EXEC_TIMEOUT}" }
}

template {
  source               = "${TPL_DIR}/key.tpl"
  destination          = "${CERT_DIR}/key.pem"
  perms                = 0640
  error_on_missing_key = true
}
EOF

# ── Register systemd service ───────────────────────────────
echo "[6/6] Registering Vault Agent as systemd service..."
cat > /etc/systemd/system/vault-agent.service << EOF
[Unit]
Description=Vault Agent - Certificate Lifecycle Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment="VAULT_PKI_ROLE_PATH=${VAULT_PKI_ROLE_PATH}"
Environment="VAULT_COMMON_NAME=${COMMON_NAME}"
Environment="VAULT_CERT_TTL=${CERT_TTL}"
ExecStart=/usr/bin/vault agent -config=${VAULT_DIR}/vault-agent.hcl
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vault-agent

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vault-agent
systemctl start vault-agent

echo ""
echo "========================================"
echo " Bootstrap Complete"
echo " $(hostname) is now enrolled in Vault PKI"
echo "========================================"
echo ""
echo " Check status:  systemctl status vault-agent"
echo " Watch logs:    journalctl -u vault-agent -f"
echo " View cert:     openssl x509 -in ${CERT_DIR}/cert.pem -noout -text"
