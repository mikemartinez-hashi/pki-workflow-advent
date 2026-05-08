# =============================================================================
# Vault Agent Config — Simplified
# =============================================================================
# All values are resolved by Terraform's templatefile() at apply time.
# No environment variables, no separate .tpl files, no env() calls.
#
# Variables injected by Terraform:
#   vault_addr      - HCP Vault cluster address
#   vault_namespace - Vault namespace
#   approle_mount   - AppRole auth mount path
#   cert_base_dir   - /etc/vault-agent (Linux) or C:\Vault (Windows)
#   pki_role_path   - Full PKI issue path e.g. pki_int_advent/issue/apache-role
#   common_name     - Certificate CN e.g. apache.demo.internal
#   cert_ttl        - Certificate TTL e.g. 720h
#   exec_command    - JSON array for post-render hook
#   exec_timeout    - Hook timeout string
# =============================================================================

vault {
  address   = "${vault_addr}"
  namespace = "${vault_namespace}"
  retry {
    num_retries = 5
  }
}

auto_auth {
  method "approle" {
    mount_path = "auth/${approle_mount}"
    config = {
      role_id_file_path                   = "${cert_base_dir}/role_id"
      secret_id_file_path                 = "${cert_base_dir}/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" {
    config = {
      path = "${cert_base_dir}/vault-token"
    }
  }
}

template_config {
  exit_on_retry_failure = true
}

# Certificate + CA chain — triggers exec hook on renewal
# Vault Agent template syntax is inside TPL heredocs and processed at runtime.
template {
  contents = <<-TPL
    {{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
    {{ .Data.certificate -}}
    {{ range .Data.ca_chain -}}
    {{ . -}}
    {{ end -}}
    {{- end }}
  TPL
  destination          = "${cert_base_dir}/certs/cert.pem"
  perms                = 0644
  error_on_missing_key = true
  exec {
    command = ${exec_command}
    timeout = "${exec_timeout}"
  }
}

# Private key — tighter permissions, no exec hook
template {
  contents = <<-TPL
    {{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
    {{ .Data.private_key -}}
    {{- end }}
  TPL
  destination          = "${cert_base_dir}/certs/key.pem"
  perms                = 0640
  error_on_missing_key = true
}

# CA chain — used by Apache SSLCertificateChainFile and Tomcat
template {
  contents = <<-TPL
    {{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
    {{ range .Data.ca_chain -}}
    {{ . -}}
    {{ end -}}
    {{- end }}
  TPL
  destination          = "${cert_base_dir}/certs/chain.pem"
  perms                = 0644
  error_on_missing_key = true
}
