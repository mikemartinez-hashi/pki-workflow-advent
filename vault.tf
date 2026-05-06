# ── Provider ───────────────────────────────────────────────────────────────
provider "vault" {
  # When using HCP Terraform, the provider automatically authenticates using OIDC
  # via the TFC_VAULT_ADDR, TFC_VAULT_NAMESPACE, and TFC_VAULT_RUN_ROLE environment variables.
  # We leave this block empty to allow TFC to natively inject those credentials.
}

# ── Root CA ────────────────────────────────────────────────────────────────
resource "vault_mount" "pki_root" {
  path                      = "pki"
  type                      = "pki"
  description               = "Root CA"
  default_lease_ttl_seconds = 86400
  max_lease_ttl_seconds     = 315360000 # 87600h
}

resource "vault_pki_secret_backend_root_cert" "root_ca" {
  backend     = vault_mount.pki_root.path
  type        = "internal"
  common_name = "Vault Demo Root CA"
  issuer_name = "vault-root-ca"
  key_type    = "rsa"
  key_bits    = 4096
  ttl         = "87600h"
}

resource "vault_pki_secret_backend_config_urls" "root_urls" {
  backend                 = vault_mount.pki_root.path
  issuing_certificates    = ["${var.vault_addr}/v1/${vault_mount.pki_root.path}/ca"]
  crl_distribution_points = ["${var.vault_addr}/v1/${vault_mount.pki_root.path}/crl"]
  ocsp_servers            = ["${var.vault_addr}/v1/${vault_mount.pki_root.path}/ocsp"]
}

# ── Intermediate CA ────────────────────────────────────────────────────────
resource "vault_mount" "pki_int" {
  path                      = "pki_int"
  type                      = "pki"
  description               = "Intermediate CA"
  default_lease_ttl_seconds = 86400
  max_lease_ttl_seconds     = 157680000 # 43800h
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int_csr" {
  backend     = vault_mount.pki_int.path
  type        = "internal"
  common_name = "Vault Demo Intermediate CA"
  format      = "pem"
  key_type    = "rsa"
  key_bits    = 2048
}

# Write the CSR to disk for the external CA script to read.
# We use .terraform/tmp/ because it is naturally ignored by .gitignore,
# keeping the working directory clean while still being accessible to the local-exec provisioner.
resource "local_file" "int_csr_file" {
  content  = vault_pki_secret_backend_intermediate_cert_request.int_csr.csr
  filename = "${path.module}/.terraform/tmp/vault-intermediate.csr"
}

# Run the Sectigo Stand-in signing script
resource "terraform_data" "sign_intermediate" {
  triggers_replace = [
    vault_pki_secret_backend_intermediate_cert_request.int_csr.csr
  ]

  provisioner "local-exec" {
    command = "mkdir -p ${path.module}/.terraform/tmp && bash ${path.module}/external-ca/sign-intermediate.sh ${local_file.int_csr_file.filename} ${path.module}/.terraform/tmp/vault-intermediate-signed.crt"
  }
}

# Read the signed certificate back into Terraform
data "local_file" "signed_int_cert" {
  depends_on = [terraform_data.sign_intermediate]
  filename   = "${path.module}/.terraform/tmp/vault-intermediate-signed.crt"
}

# Import the signed certificate back into Vault
resource "vault_pki_secret_backend_intermediate_set_signed" "int_set_signed" {
  backend     = vault_mount.pki_int.path
  certificate = data.local_file.signed_int_cert.content
}

resource "vault_pki_secret_backend_config_urls" "int_urls" {
  backend                 = vault_mount.pki_int.path
  issuing_certificates    = ["${var.vault_addr}/v1/${vault_mount.pki_int.path}/ca"]
  crl_distribution_points = ["${var.vault_addr}/v1/${vault_mount.pki_int.path}/crl"]
  ocsp_servers            = ["${var.vault_addr}/v1/${vault_mount.pki_int.path}/ocsp"]
}

# ── PKI Roles ──────────────────────────────────────────────────────────────
locals {
  pki_roles = {
    apache = "demo.internal,app.internal"
    tomcat = "demo.internal,app.internal"
    iis    = "demo.internal,win.internal"
    manual = "demo.internal,legacy.internal"
  }
}

resource "vault_pki_secret_backend_role" "roles" {
  depends_on = [vault_pki_secret_backend_intermediate_set_signed.int_set_signed]
  for_each   = local.pki_roles

  backend            = vault_mount.pki_int.path
  name               = "${each.key}-role"
  issuer_ref         = "vault-intermediate"
  allowed_domains    = split(",", each.value)
  allow_subdomains   = true
  allow_bare_domains = false
  max_ttl            = "2592000" # 720h
  ttl                = "2592000" # 720h
  key_type           = "rsa"
  key_bits           = 2048
  server_flag        = true
  client_flag        = false
  no_store           = false
  generate_lease     = true
}

# ── Vault Policies ─────────────────────────────────────────────────────────
resource "vault_policy" "policies" {
  for_each = local.pki_roles
  name     = "pki-${each.key}"
  policy   = file("${path.module}/configs/policy-${each.key}.hcl")
}

# ── AppRole Authentication ─────────────────────────────────────────────────
resource "vault_auth_backend" "approle" {
  type = "approle"
}

resource "vault_approle_auth_backend_role" "roles" {
  for_each = local.pki_roles

  backend        = vault_auth_backend.approle.path
  role_name      = "${each.key}-vault-agent"
  token_policies = [vault_policy.policies[each.key].name]
  token_ttl      = 3600  # 1h
  token_max_ttl  = 14400 # 4h
  secret_id_ttl  = 0
  bind_secret_id = true
}

resource "vault_approle_auth_backend_role_secret_id" "secret_ids" {
  for_each  = local.pki_roles
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.roles[each.key].role_name
}
