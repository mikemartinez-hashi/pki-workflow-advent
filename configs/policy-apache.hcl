# Certificate issuance only — path resolved at apply time via templatefile()
path "${pki_int_path}/issue/${role_name}" {
  capabilities = ["create", "update"]
}

path "${pki_int_path}/roles/${role_name}" {
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
