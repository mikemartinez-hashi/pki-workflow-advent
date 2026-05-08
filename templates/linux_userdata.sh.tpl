#!/bin/bash
set -eo pipefail
trap 'echo "ERROR: userdata failed at line $LINENO" >&2' ERR

echo "========================================"
echo " Vault Agent Bootstrap"
echo " Platform : ${platform}"
echo " Host     : $(hostname)"
echo "========================================"

# ── Dependencies ───────────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y curl unzip jq openssl software-properties-common

# ── AWS SSM Agent ──────────────────────────────────────────────────────────
if ! systemctl is-active amazon-ssm-agent &>/dev/null; then
  curl -sL https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb \
    -o /tmp/amazon-ssm-agent.deb
  dpkg -i /tmp/amazon-ssm-agent.deb
  systemctl enable amazon-ssm-agent
  systemctl start amazon-ssm-agent
fi

# ── Vault ──────────────────────────────────────────────────────────────────
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt-get update -qq
apt-get install -y vault

# ── Platform packages ──────────────────────────────────────────────────────
if [ "${platform}" = "apache" ]; then
  apt-get install -y apache2
  systemctl enable apache2
  systemctl start apache2
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

elif [ "${platform}" = "tomcat" ]; then
  apt-get install -y tomcat10 tomcat10-admin
  mkdir -p /opt/tomcat/conf
  chown -R tomcat:tomcat /opt/tomcat 2>/dev/null || true

  # Tomcat exec hook — written as plain bash, no variables needed at runtime
  mkdir -p /etc/vault-agent/hooks
  cat > /etc/vault-agent/hooks/tomcat-reload.sh << 'HOOK'
#!/bin/bash
set -eo pipefail
CERT_DIR="/etc/vault-agent/certs"
KEYSTORE_DIR="/var/lib/tomcat10/conf"
[ -d "$KEYSTORE_DIR" ] || KEYSTORE_DIR="/opt/tomcat/conf"
mkdir -p "$KEYSTORE_DIR"

openssl pkcs12 -export \
    -in  "$CERT_DIR/cert.pem" \
    -inkey "$CERT_DIR/key.pem" \
    -certfile "$CERT_DIR/chain.pem" \
    -out "$KEYSTORE_DIR/vault-keystore.p12.tmp" \
    -passout "pass:changeit" \
    -name "vault-cert"

mv "$KEYSTORE_DIR/vault-keystore.p12.tmp" "$KEYSTORE_DIR/vault-keystore.p12"
chmod 640 "$KEYSTORE_DIR/vault-keystore.p12"
systemctl reload tomcat10 2>/dev/null || systemctl restart tomcat10
echo "[$(date)] Tomcat cert rotation complete."
HOOK
  chmod +x /etc/vault-agent/hooks/tomcat-reload.sh

  cat > /var/lib/tomcat10/conf/server.xml << 'TOMCATXML'
<?xml version="1.0" encoding="UTF-8"?>
<Server port="8005" shutdown="SHUTDOWN">
  <Listener className="org.apache.catalina.startup.VersionLoggerListener" />
  <Listener className="org.apache.catalina.core.JreMemoryLeakPreventionListener" />
  <Listener className="org.apache.catalina.mbeans.GlobalResourcesLifecycleListener" />
  <GlobalNamingResources>
    <Resource name="UserDatabase" auth="Container"
              type="org.apache.catalina.UserDatabase"
              factory="org.apache.catalina.users.MemoryUserDatabaseFactory"
              pathname="conf/tomcat-users.xml" />
  </GlobalNamingResources>
  <Service name="Catalina">
    <Connector port="8080" protocol="HTTP/1.1"
               connectionTimeout="20000" redirectPort="8443" />
    <Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true">
      <SSLHostConfig>
        <Certificate certificateKeystoreFile="conf/vault-keystore.p12"
                     certificateKeystorePassword="changeit" type="RSA" />
      </SSLHostConfig>
    </Connector>
    <Engine name="Catalina" defaultHost="localhost">
      <Host name="localhost" appBase="webapps" unpackWARs="true" autoDeploy="true" />
    </Engine>
  </Service>
</Server>
TOMCATXML
fi

# ── Vault Agent directories ────────────────────────────────────────────────
mkdir -p /etc/vault-agent/certs /etc/vault-agent/tpl
chmod 750 /etc/vault-agent /etc/vault-agent/certs

# ── AppRole credentials ────────────────────────────────────────────────────
echo -n "${role_id}"   > /etc/vault-agent/role_id
echo -n "${secret_id}" > /etc/vault-agent/secret_id
chmod 600 /etc/vault-agent/role_id /etc/vault-agent/secret_id

# ── Vault Agent template files ─────────────────────────────────────────────
# PKI path, CN, and TTL are baked in here by Terraform templatefile().
# Vault Agent processes the {{ }} syntax at runtime — no env() calls needed.
cat > /etc/vault-agent/tpl/cert.tpl << 'EOF'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ .Data.certificate -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
EOF

cat > /etc/vault-agent/tpl/key.tpl << 'EOF'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ .Data.private_key -}}
{{- end }}
EOF

cat > /etc/vault-agent/tpl/chain.tpl << 'EOF'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
EOF

# ── Vault Agent config ─────────────────────────────────────────────────────
cat > /etc/vault-agent/vault-agent.hcl << 'AGENTEOF'
${vault_agent_config}
AGENTEOF

# ── Systemd service ────────────────────────────────────────────────────────
cat > /etc/systemd/system/vault-agent.service << 'SYSTEMDEOF'
[Unit]
Description=Vault Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/vault agent -config=/etc/vault-agent/vault-agent.hcl
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vault-agent

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable vault-agent
systemctl start vault-agent

echo "========================================"
echo " Bootstrap complete"
echo "========================================"
