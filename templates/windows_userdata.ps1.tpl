<powershell>
$ErrorActionPreference = "Stop"
Start-Transcript -Path "C:\Vault\logs\userdata-transcript.txt"

Write-Host "========================================"
Write-Host " Vault Agent Bootstrap (Windows IIS)"
Write-Host "========================================"

# Create directories
New-Item -ItemType Directory -Force -Path "C:\Vault\certs" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\tpl" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\hooks" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\logs" | Out-Null

# Install Vault
Write-Host "Downloading and installing Vault..."
$latestUrl = "https://api.releases.hashicorp.com/v1/releases/vault/latest?license_class=oss"
$vaultVersion = (Invoke-RestMethod -Uri $latestUrl).version
$vaultUrl = "https://releases.hashicorp.com/vault/$${vaultVersion}/vault_$${vaultVersion}_windows_amd64.zip"
$zipPath = "C:\Vault\vault.zip"
Invoke-WebRequest -Uri $vaultUrl -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath "C:\Vault" -Force
Remove-Item $zipPath
[System.Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Vault", [System.EnvironmentVariableTarget]::Machine)
$env:Path = $env:Path + ";C:\Vault"

# Install IIS
Write-Host "Installing IIS..."
Install-WindowsFeature -name Web-Server -IncludeManagementTools

# Write credentials
Set-Content -Path "C:\Vault\role_id" -Value "${role_id}" -NoNewline
Set-Content -Path "C:\Vault\secret_id" -Value "${secret_id}" -NoNewline

# Write templates
$certTpl = @"
{{- with secret (env "VAULT_PKI_ROLE_PATH") "common_name=" (env "VAULT_COMMON_NAME") "ttl=" (env "VAULT_CERT_TTL") -}}
{{ .Data.certificate -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
"@
Set-Content -Path "C:\Vault\tpl\cert.tpl" -Value $certTpl

$keyTpl = @"
{{- with secret (env "VAULT_PKI_ROLE_PATH") "common_name=" (env "VAULT_COMMON_NAME") "ttl=" (env "VAULT_CERT_TTL") -}}
{{ .Data.private_key -}}
{{- end }}
"@
Set-Content -Path "C:\Vault\tpl\key.tpl" -Value $keyTpl

$chainTpl = @"
{{- with secret (env "VAULT_PKI_ROLE_PATH") "common_name=" (env "VAULT_COMMON_NAME") "ttl=" (env "VAULT_CERT_TTL") -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
"@
Set-Content -Path "C:\Vault\tpl\chain.tpl" -Value $chainTpl

# Write bind-cert.ps1 hook
$hookContent = @"
# bind-cert.ps1
# Imports Vault-issued certificate into Windows cert store
# and updates IIS HTTPS binding - runs on each cert renewal

param(
    [string]`$CertPath    = "C:\Vault\certs\cert.pem",
    [string]`$KeyPath     = "C:\Vault\certs\key.pem",
    [string]`$ChainPath   = "C:\Vault\certs\chain.pem",
    [string]`$SiteName    = "Default Web Site",
    [string]`$LogPath     = "C:\Vault\logs\bind-cert.log",
    [int]`$Port           = 443
)

`$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Write-Log {
    param([string]`$Message)
    `$entry = "[`$timestamp] `$Message"
    Add-Content -Path `$LogPath -Value `$entry
    Write-Host `$entry
}

Write-Log "Starting cert bind process..."

New-Item -ItemType Directory -Force -Path (Split-Path `$LogPath) | Out-Null

try {
    `$pfxPath = "C:\Vault\certs\vault-cert.pfx"
    `$pfxPass = "vault-temp-`$(Get-Random)"

    & openssl pkcs12 -export `
        -in `$CertPath `
        -inkey `$KeyPath `
        -certfile `$ChainPath `
        -out `$pfxPath `
        -passout "pass:`$pfxPass" `
        -name "vault-cert" 2>&1 | Out-Null

    Write-Log "PFX created at `$pfxPath"

    `$secPass = ConvertTo-SecureString -String `$pfxPass -Force -AsPlainText
    `$cert = Import-PfxCertificate `
        -FilePath `$pfxPath `
        -CertStoreLocation Cert:\LocalMachine\My `
        -Password `$secPass

    Write-Log "Cert imported. Thumbprint: `$`(`$cert.Thumbprint)"
    Write-Log "Subject: `$`(`$cert.Subject)"
    Write-Log "Expiry:  `$`(`$cert.NotAfter)"

    Remove-Item `$pfxPath -Force

    Import-Module WebAdministration
    `$binding = Get-WebBinding -Name `$SiteName -Protocol "https" -Port `$Port
    if (`$binding) {
        `$binding.AddSslCertificate(`$cert.Thumbprint, "My")
        Write-Log "IIS HTTPS binding updated for site: `$SiteName on port `$Port"
    } else {
        # Create new binding if it doesn't exist
        New-WebBinding -Name `$SiteName -IP "*" -Port `$Port -Protocol https
        `$binding = Get-WebBinding -Name `$SiteName -Protocol "https" -Port `$Port
        `$binding.AddSslCertificate(`$cert.Thumbprint, "My")
        Write-Log "IIS HTTPS binding created and updated for site: `$SiteName on port `$Port"
    }

    `$appPool = (Get-Website -Name `$SiteName).applicationPool
    Restart-WebAppPool -Name `$appPool
    Write-Log "App pool '`$appPool' restarted."

    Write-Log "Cert bind complete."

} catch {
    Write-Log "ERROR: `$`(`$_.Exception.Message)"
    exit 1
}
"@
Set-Content -Path "C:\Vault\hooks\bind-cert.ps1" -Value $hookContent

# Write agent config
$agentConfig = @"
${vault_agent_config}
"@
Set-Content -Path "C:\Vault\vault-agent.hcl" -Value $agentConfig

# Install chocolatey and openssl (required for pkcs12 export in the hook)
if (!(Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}
choco install openssl -y
choco install nssm -y

# Setup Windows Service for Vault Agent using NSSM
nssm install VaultAgent "C:\Vault\vault.exe" "agent -config=C:\Vault\vault-agent.hcl"
nssm set VaultAgent AppEnvironmentExtra "VAULT_PKI_ROLE_PATH=${pki_role_path}" "VAULT_COMMON_NAME=${common_name}" "VAULT_CERT_TTL=${cert_ttl}"
nssm start VaultAgent

Stop-Transcript
</powershell>
