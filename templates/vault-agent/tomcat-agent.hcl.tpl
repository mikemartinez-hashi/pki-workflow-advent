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
#     cert_base_dir   = "/etc/vault-agent"
#     exec_command    = jsonencode(["/etc/vault-agent/hooks/tomcat-reload.sh"])
#     exec_timeout    = "60s"
#   })
