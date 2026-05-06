# =============================================================================
# Unified Vault Agent Config Template
# =============================================================================
# Used by main.tf via templatefile() for all platforms (Apache, Tomcat, IIS).
#
# Required variables (passed from templatefile()):
#   vault_addr        - HCP Vault cluster address
#   vault_namespace   - Vault namespace (e.g. "admin")
#   cert_base_dir     - Base path for certs/tpl/credentials
#                       Linux: /etc/vault-agent   Windows: C:\Vault
#   exec_command      - JSON array string for the post-render hook
#                       e.g. ["systemctl","reload","apache2"]
#                         or ["powershell.exe","-File","C:\\Vault\\hooks\\bind-cert.ps1"]
#   exec_timeout      - Timeout string, e.g. "30s" or "60s"
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
    mount_path = "auth/approle"
    config = {
      role_id_file_path                = "${cert_base_dir}/role_id"
      secret_id_file_path              = "${cert_base_dir}/secret_id"
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
  static_secret_render_interval = "5m"
  exit_on_retry_failure         = true
}

# Certificate + CA chain — triggers exec hook on renewal
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

# Private key — tighter permissions, no exec hook
template {
  source               = "${cert_base_dir}/tpl/key.tpl"
  destination          = "${cert_base_dir}/certs/key.pem"
  perms                = 0640
  error_on_missing_key = true
}

# CA chain — for client certificate verification
template {
  source               = "${cert_base_dir}/tpl/chain.tpl"
  destination          = "${cert_base_dir}/certs/chain.pem"
  perms                = 0644
  error_on_missing_key = true
}
