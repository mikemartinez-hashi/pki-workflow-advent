# DEPRECATED — superseded by agent.hcl.tpl
#
# This file is kept for reference only. The canonical Vault Agent config
# template is now templates/vault-agent/agent.hcl.tpl, which is parameterized
# via templatefile() in main.tf for all platforms (Apache, Tomcat, IIS).
#
# To replicate this config manually, call:
#
#   templatefile("templates/vault-agent/agent.hcl.tpl", {
#     vault_addr      = "<addr>"
#     vault_namespace = "admin"
#     cert_base_dir   = "C:\\Vault"
#     exec_command    = jsonencode(["powershell.exe", "-File", "C:\\Vault\\hooks\\bind-cert.ps1"])
#     exec_timeout    = "60s"
#   })
