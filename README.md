# Vault PKI Lifecycle Demo — AdventHealth
## Full Certificate Lifecycle Management Demo

---

## What This Demo Covers

| Ben's Ask | Demo Component |
|---|---|
| Full lifecycle (request → renewal → revocation) | setup-vault-pki.sh + Vault Agent |
| Sectigo / external CA policy story | setup-external-ca.sh + sign-intermediate.sh |
| IIS cert injection | iis-agent.hcl.tpl + bind-cert.ps1 |
| Apache cert injection | apache-agent.hcl.tpl + systemctl reload |
| Tomcat cert injection | tomcat-agent.hcl.tpl + tomcat-reload.sh |
| Reusable templates | cert.tpl / key.tpl / chain.tpl (shared) |
| Platform team ops experience | Policy HCL files + agent configs |
| End-user request experience | request-cert-manual.sh |
| Terraform provisioned servers | main.tf + userdata templates |
| Non-Terraform existing servers | bootstrap-existing-server.sh |

---

## Architecture

```
Simulated External CA (OpenSSL - Sectigo Stand-In)
       |
  Signs Vault Intermediate CA  [one-time event]
       |
  Vault PKI Engine (pki_int/)
  ├── apache-role     → Linux/Apache   (Vault Agent / systemd)
  ├── iis-role        → Windows/IIS    (Vault Agent / Windows Service)
  ├── tomcat-role     → Linux/Tomcat   (Vault Agent / PKCS12 hook)
  └── manual-role     → Non-Terraform  (bootstrap-existing-server.sh)
```

---

## Run Order

### Step 0: Local Prerequisites
If you are running the External CA simulation script locally, ensure you have set your Vault environment variables:
```bash
export VAULT_ADDR="https://<your-hcp-vault-addr>:8200"
export VAULT_NAMESPACE="admin"
export VAULT_TOKEN="<your-token>"
```

### Step 1: Create the simulated external CA (Sectigo stand-in)
```bash
chmod +x scripts/setup-external-ca.sh
./scripts/setup-external-ca.sh
```

### Step 2: Deploy via HCP Terraform

Since this environment is managed via HCP Terraform, the deployment runs remotely.

1. Push this code to a VCS repository connected to an HCP Terraform Workspace (or use CLI-driven runs).
2. Configure the following variables in your HCP Terraform workspace:

**Environment Variables:**
| Key | Value | Sensitive |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Your AWS access key | No |
| `AWS_SECRET_ACCESS_KEY` | Your AWS secret key | YES |
| `VAULT_TOKEN` | Your HCP Vault admin token | YES |

**Terraform Variables:**
| Key | Value |
|---|---|
| `vault_addr` | `"https://<your-hcp-vault-addr>:8200"` |
| `vault_namespace` | `"admin"` (or your chosen namespace) |
| `key_name` | `"your-ec2-key-name"` |

3. Queue a run in HCP Terraform to deploy the infrastructure and Vault PKI hierarchy.

*(Terraform dynamically generates all AppRole credentials and wires them directly into the EC2 instances during the remote run, eliminating the need to manually copy variables!)*

### Step 3: Verify all platforms
```bash
# Apache
aws ssm start-session --target <apache_instance_id>
systemctl status vault-agent
openssl x509 -in /etc/vault-agent/certs/cert.pem -noout -subject -issuer -dates

# Tomcat
aws ssm start-session --target <tomcat_instance_id>
systemctl status vault-agent
openssl x509 -in /etc/vault-agent/certs/cert.pem -noout -subject -issuer -dates

# IIS (Windows)
# RDP or SSM to Windows instance
Get-Service VaultAgent
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, Thumbprint, NotAfter
```

---

## Non-Terraform Path (Existing Servers)

Run this on any existing server that was NOT provisioned by Terraform:

```bash
export VAULT_ADDR="https://<your-hcp-vault-addr>:8200"
export VAULT_NAMESPACE="admin"
export ROLE_ID="<manual_role_id from .vault-outputs.env>"
export SECRET_ID="<manual_secret_id from .vault-outputs.env>"
export COMMON_NAME="myserver.demo.internal"
export PLATFORM="apache"   # apache | tomcat | nginx

chmod +x scripts/bootstrap-existing-server.sh
sudo ./scripts/bootstrap-existing-server.sh
```

---

## End-User Request Flow

Shows CLI, API, and UI paths for requesting a cert on demand:

```bash
chmod +x scripts/request-cert-manual.sh
./scripts/request-cert-manual.sh
```

---

## File Structure

```
pki-lifecycle-demo-adventhealth/
├── README.md
├── main.tf                                     # EC2 instances (Apache, Tomcat, IIS)
├── variables.tf
├── outputs.tf
├── vault.tf                                    # PKI mounts, roles, policies
├── scripts/
│   ├── setup-external-ca.sh                   # Step 1: Simulated Sectigo CA
│   ├── setup-vault-pki.sh                     # Step 2: Full PKI hierarchy setup
│   ├── bootstrap-existing-server.sh           # Non-Terraform server enrollment
│   └── request-cert-manual.sh                 # End-user cert request demo
├── external-ca/
│   └── sign-intermediate.sh                   # Signs Vault CSR (Sectigo simulation)
├── templates/
│   ├── linux_userdata.sh.tpl                  # Apache + Tomcat bootstrap
│   ├── windows_userdata.ps1.tpl               # IIS bootstrap
│   └── vault-agent/
│       ├── cert.tpl                           # Shared: cert + chain
│       ├── key.tpl                            # Shared: private key
│       ├── chain.tpl                          # Shared: CA chain only
│       ├── apache-agent.hcl.tpl              # Apache agent config
│       ├── tomcat-agent.hcl.tpl              # Tomcat agent config
│       ├── iis-agent.hcl.tpl                 # IIS agent config
│       └── hooks/
│           ├── tomcat-reload.sh              # PKCS12 conversion + Tomcat reload
│           └── bind-cert.ps1                 # Windows cert store + IIS rebind
└── configs/
    ├── policy-apache.hcl                      # Least privilege: Apache
    ├── policy-iis.hcl                         # Least privilege: IIS
    ├── policy-tomcat.hcl                      # Least privilege: Tomcat
    └── policy-manual.hcl                      # Least privilege: Existing servers
```

---

## Key Demo Talking Points

### Sectigo / External CA Story
"In production, Step 1 here is replaced by submitting this CSR to Sectigo's portal
or REST API. Sectigo signs it once. From that point forward, Vault issues every
end-entity certificate — Sectigo is not involved for each renewal."

### Reusable Templates
"The cert.tpl, key.tpl, and chain.tpl files are shared across Apache, Tomcat, and
IIS. The only thing that changes per platform is the exec hook that fires after
the cert is written to disk. The CA, the policy, and the template are identical."

### Non-Terraform Path
"bootstrap-existing-server.sh enrolls any server that already exists in your
environment — no Terraform required. It installs Vault Agent, writes the AppRole
credentials, configures the templates, and registers it as a systemd service.
After that it behaves identically to a Terraform-provisioned server."

### Reusable Templates Show
"One set of templates works across all platforms. You define the template once,
parameterize the role path and common name, and the same logic runs on Apache,
Tomcat, and IIS."

### Serial Number Cross-Reference
OpenSSL serial:  20:11:1f:52:... (colon-separated)
Vault serial:    20-11-1f-52-... (hyphen-separated)

Convert on the fly:
```bash
openssl x509 -in cert.pem -noout -serial \
  | cut -d= -f2 \
  | sed 's/../&-/g;s/-$//' \
  | tr '[:upper:]' '[:lower:]'
```

Revoke by serial:
```bash
vault write pki_int/revoke \
  serial_number="20-11-1f-52-3e-96-5b-3f-4d-2a-cb-2b-bb-23-d2-5e-5f-86-45-c7"
```
