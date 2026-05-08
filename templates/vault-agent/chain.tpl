{{- with secret "pki_int_advent/issue/apache-role-advent" "common_name=apache.demo.internal" "ttl=720h" -}}
{{ range .Data.ca_chain }}{{ . }}
{{ end }}
{{- end }}