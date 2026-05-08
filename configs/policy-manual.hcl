# Non-Terraform existing servers - manual/legacy role
# Separate blast radius from Terraform-provisioned servers

path "${pki_int_path}/issue/manual-role" {
  capabilities = ["create", "update"]
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
