# IIS web server - certificate issuance only
# Scope: iis-role on ${pki_int_path}, read own token

path "${pki_int_path}/issue/iis-role" {
  capabilities = ["create", "update"]
}

path "${pki_int_path}/roles/iis-role" {
  capabilities = ["read"]
}

path "${pki_int_path}/cert/ca" {
  capabilities = ["read"]
}

path "${pki_int_path}/cert/ca_chain" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
