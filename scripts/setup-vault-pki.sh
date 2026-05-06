#!/bin/bash
set -eo pipefail
trap 'echo "ERROR: setup-vault-pki.sh failed at line $LINENO — aborting." >&2' ERR

echo "=============================================="
echo " Vault PKI Lifecycle Demo Setup (Prereq)"
echo " External CA: OpenSSL (Sectigo stand-in)"
echo "=============================================="

# ── Step 1: Initialize External CA ─────────────────────────────────────────
echo "Running External CA setup..."
bash ./external-ca/setup-external-ca.sh

echo ""
echo "=============================================="
echo " Prerequisite Setup Complete"
echo "=============================================="
echo " The PKI hierarchy, AppRoles, and Policies are now"
echo " managed entirely by Terraform (vault.tf)."
echo ""
echo " Next Steps:"
echo " 1. Run: terraform init && terraform apply"
echo " 2. Verify with: terraform output verify_commands"
echo "=============================================="
