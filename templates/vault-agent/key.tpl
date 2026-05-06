{{- with secret (env "VAULT_PKI_ROLE_PATH") "common_name=" (env "VAULT_COMMON_NAME") "ttl=" (env "VAULT_CERT_TTL") -}}
{{ .Data.private_key -}}
{{- end }}
