{{- with secret "pki_int_advent/issue/apache-role-advent" "common_name=apache.demo.internal" "ttl=720h" -}}
{{ .Data.private_key }}
{{- end }}