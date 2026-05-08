# =============================================================================
# Vault Agent Config
# Values resolved by Terraform templatefile() at apply time.
# No env() calls, no runtime environment variables required.
#
# Variables:
#   vault_addr      - HCP Vault cluster address
#   vault_namespace - Vault namespace
#   approle_mount   - AppRole auth mount path
#   cert_base_dir   - /etc/vault-agent (Linux) or C:\Vault (Windows)
#   exec_command    - JSON array for post-render exec hook
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

# Certificate + CA chain — tpl file has values baked in by Terraform
template {
  source               = "${cert_base_dir}/tpl/cert.tpl"
  destination          = "${cert_base_dir}/certs/cert.pem"
  perms                = 0644
  error_on_missing_key = true
  exec {
    command = ${exec_command}
    timeout = "${exec_timeout}"
  }
}

# Private key
template {
  source               = "${cert_base_dir}/tpl/key.tpl"
  destination          = "${cert_base_dir}/certs/key.pem"
  perms                = 0640
  error_on_missing_key = true
}

# CA chain
template {
  source               = "${cert_base_dir}/tpl/chain.tpl"
  destination          = "${cert_base_dir}/certs/chain.pem"
  perms                = 0644
  error_on_missing_key = true
}
