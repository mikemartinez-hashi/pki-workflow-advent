# Tomcat application server - separate policy boundary from Apache
# Scope: tomcat-role on pki_int, read own token

path "pki_int/issue/tomcat-role" {
  capabilities = ["create", "update"]
}

path "pki_int/roles/tomcat-role" {
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
