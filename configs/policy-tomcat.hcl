# Tomcat application server - separate policy boundary from Apache
# Scope: tomcat-role on ${pki_int_path}, read own token

path "${pki_int_path}/issue/tomcat-role" {
  capabilities = ["create", "update"]
}

path "${pki_int_path}/roles/tomcat-role" {
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
