# Apache web server - certificate issuance only
# Scope: apache-role on pki_int, read own token

path "pki_int/issue/apache-role" {
  capabilities = ["create", "update"]
}

path "pki_int/roles/apache-role" {
  capabilities = ["read"]
}

path "pki_int/cert/ca" {
  capabilities = ["read"]
}

path "pki_int/cert/ca_chain" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
