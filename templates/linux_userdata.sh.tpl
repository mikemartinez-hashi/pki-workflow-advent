#!/bin/bash
set -eo pipefail
trap 'echo "ERROR: linux_userdata.sh failed at line $LINENO" >&2' ERR

echo "========================================"
echo " Vault Agent Bootstrap (Linux)"
echo " Platform: ${platform}"
echo "========================================"

# Install dependencies
apt-get update -qq
apt-get install -y curl unzip jq openssl software-properties-common

# Install Vault
curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
apt-get update -qq
apt-get install -y vault

# Platform specific installation
if [ "${platform}" == "apache" ]; then
    apt-get install -y apache2
    systemctl enable apache2
    systemctl start apache2

    # Enable SSL and configure HTTPS
    a2enmod ssl
    cat > /etc/apache2/sites-available/vault-demo-ssl.conf << 'SSLCONF'
<VirtualHost *:443>
    ServerName apache.demo.internal
    SSLEngine on
    SSLCertificateFile    /etc/vault-agent/certs/cert.pem
    SSLCertificateKeyFile /etc/vault-agent/certs/key.pem
    SSLCertificateChainFile /etc/vault-agent/certs/chain.pem
</VirtualHost>
SSLCONF
    a2ensite vault-demo-ssl
    systemctl reload apache2 || true

elif [ "${platform}" == "tomcat" ]; then
    apt-get install -y tomcat10 tomcat10-admin
    # Ensure standard tomcat dir exists for compatibility
    mkdir -p /opt/tomcat/conf
    chown -R tomcat:tomcat /opt/tomcat || true
fi

VAULT_DIR="/etc/vault-agent"
mkdir -p $VAULT_DIR/certs $VAULT_DIR/tpl $VAULT_DIR/hooks
chmod 750 $VAULT_DIR $VAULT_DIR/certs

# Write credentials
echo -n "${role_id}" > $VAULT_DIR/role_id
echo -n "${secret_id}" > $VAULT_DIR/secret_id
chmod 600 $VAULT_DIR/role_id $VAULT_DIR/secret_id

# Write templates
cat << 'EOF' > $VAULT_DIR/tpl/cert.tpl
{{- with secret (env "VAULT_PKI_ROLE_PATH") "common_name=" (env "VAULT_COMMON_NAME") "ttl=" (env "VAULT_CERT_TTL") -}}
{{ .Data.certificate -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
EOF

cat << 'EOF' > $VAULT_DIR/tpl/key.tpl
{{- with secret (env "VAULT_PKI_ROLE_PATH") "common_name=" (env "VAULT_COMMON_NAME") "ttl=" (env "VAULT_CERT_TTL") -}}
{{ .Data.private_key -}}
{{- end }}
EOF

cat << 'EOF' > $VAULT_DIR/tpl/chain.tpl
{{- with secret (env "VAULT_PKI_ROLE_PATH") "common_name=" (env "VAULT_COMMON_NAME") "ttl=" (env "VAULT_CERT_TTL") -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
EOF

# Write hooks
if [ "${platform}" == "tomcat" ]; then
cat << 'EOF' > $VAULT_DIR/hooks/tomcat-reload.sh
#!/bin/bash
set -eo pipefail
trap 'echo "[$(date)] ERROR: tomcat-reload.sh failed at line $LINENO" >&2' ERR

CERT_DIR="/etc/vault-agent/certs"
KEYSTORE_DIR="/var/lib/tomcat10/conf"
if [ ! -d "$KEYSTORE_DIR" ]; then
    KEYSTORE_DIR="/opt/tomcat/conf"
fi
KEYSTORE_PASS="$${KEYSTORE_PASS:-changeit}"
KEYSTORE_FILE="$KEYSTORE_DIR/vault-keystore.p12"
KEYSTORE_TMP="$KEYSTORE_FILE.tmp"

mkdir -p "$KEYSTORE_DIR"

echo "[$(date)] Converting cert to PKCS12 keystore..."
openssl pkcs12 -export \
    -in "$CERT_DIR/cert.pem" \
    -inkey "$CERT_DIR/key.pem" \
    -certfile "$CERT_DIR/chain.pem" \
    -out "$KEYSTORE_TMP" \
    -passout "pass:$KEYSTORE_PASS" \
    -name "vault-cert"

mv "$KEYSTORE_TMP" "$KEYSTORE_FILE"
chmod 640 "$KEYSTORE_FILE"

echo "[$(date)] Reloading Tomcat..."
systemctl reload tomcat10 2>/dev/null || systemctl restart tomcat10
EOF
chmod +x $VAULT_DIR/hooks/tomcat-reload.sh

# Configure Tomcat to use HTTPS with the generated keystore
cat << 'EOF' > /var/lib/tomcat10/conf/server.xml
<?xml version="1.0" encoding="UTF-8"?>
<Server port="8005" shutdown="SHUTDOWN">
  <Listener className="org.apache.catalina.startup.VersionLoggerListener" />
  <Listener className="org.apache.catalina.core.AprLifecycleListener" SSLEngine="on" />
  <Listener className="org.apache.catalina.core.JreMemoryLeakPreventionListener" />
  <Listener className="org.apache.catalina.mbeans.GlobalResourcesLifecycleListener" />
  <Listener className="org.apache.catalina.core.ThreadLocalLeakPreventionListener" />
  <GlobalNamingResources>
    <Resource name="UserDatabase" auth="Container"
              type="org.apache.catalina.UserDatabase"
              description="User database that can be updated and saved"
              factory="org.apache.catalina.users.MemoryUserDatabaseFactory"
              pathname="conf/tomcat-users.xml" />
  </GlobalNamingResources>
  <Service name="Catalina">
    <Connector port="8080" protocol="HTTP/1.1"
               connectionTimeout="20000"
               redirectPort="8443" />
    <Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="conf/vault-keystore.p12"
                         certificateKeystorePassword="changeit"
                         type="RSA" />
        </SSLHostConfig>
    </Connector>
    <Engine name="Catalina" defaultHost="localhost">
      <Realm className="org.apache.catalina.realm.LockOutRealm">
        <Realm className="org.apache.catalina.realm.UserDatabaseRealm"
               resourceName="UserDatabase"/>
      </Realm>
      <Host name="localhost"  appBase="webapps"
            unpackWARs="true" autoDeploy="true">
        <Valve className="org.apache.catalina.valves.AccessLogValve" directory="logs"
               prefix="localhost_access_log" suffix=".txt"
               pattern="%h %l %u %t &quot;%r&quot; %s %b" />
      </Host>
    </Engine>
  </Service>
</Server>
EOF

fi

# Write agent config from terraform variable
cat << 'EOF' > $VAULT_DIR/vault-agent.hcl
${vault_agent_config}
EOF

# Create Systemd service
cat > /etc/systemd/system/vault-agent.service << EOF
[Unit]
Description=Vault Agent
After=network-online.target

[Service]
Type=simple
User=root
Environment="VAULT_PKI_ROLE_PATH=${pki_role_path}"
Environment="VAULT_COMMON_NAME=${common_name}"
Environment="VAULT_CERT_TTL=${cert_ttl}"
ExecStart=/usr/bin/vault agent -config=${VAULT_DIR}/vault-agent.hcl
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vault-agent
systemctl start vault-agent
