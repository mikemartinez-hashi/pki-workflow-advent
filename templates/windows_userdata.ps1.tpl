<powershell>
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path "C:\Vault\certs" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\hooks" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\logs"  | Out-Null
Start-Transcript -Path "C:\Vault\logs\userdata-transcript.txt"

Write-Host "========================================"
Write-Host " Vault Agent Bootstrap (Windows IIS)"
Write-Host "========================================"

# ── Install Vault ──────────────────────────────────────────────────────────
Write-Host "Installing Vault..."
$latestUrl  = "https://api.releases.hashicorp.com/v1/releases/vault/latest?license_class=oss"
$vaultVer   = (Invoke-RestMethod -Uri $latestUrl).version
$vaultUrl   = "https://releases.hashicorp.com/vault/$vaultVer/vault_$${vaultVer}_windows_amd64.zip"
Invoke-WebRequest -Uri $vaultUrl -OutFile "C:\Vault\vault.zip"
Expand-Archive  -Path "C:\Vault\vault.zip" -DestinationPath "C:\Vault" -Force
Remove-Item      "C:\Vault\vault.zip"
[System.Environment]::SetEnvironmentVariable(
    "Path", $env:Path + ";C:\Vault",
    [System.EnvironmentVariableTarget]::Machine)
$env:Path += ";C:\Vault"

# ── Install IIS ────────────────────────────────────────────────────────────
Write-Host "Installing IIS..."
Install-WindowsFeature -Name Web-Server -IncludeManagementTools

# ── Install Chocolatey + OpenSSL + NSSM ───────────────────────────────────
Write-Host "Installing Chocolatey, OpenSSL, NSSM..."
if (!(Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}
choco install openssl nssm -y --no-progress

# ── AppRole credentials ────────────────────────────────────────────────────
Write-Host "Writing AppRole credentials..."
Set-Content -Path "C:\Vault\role_id"   -Value "${role_id}"   -NoNewline
Set-Content -Path "C:\Vault\secret_id" -Value "${secret_id}" -NoNewline

# ── bind-cert.ps1 hook ─────────────────────────────────────────────────────
Write-Host "Writing bind-cert hook..."
$bindCert = @'
param(
    [string]$CertPath  = "C:\Vault\certs\cert.pem",
    [string]$KeyPath   = "C:\Vault\certs\key.pem",
    [string]$ChainPath = "C:\Vault\certs\chain.pem",
    [string]$SiteName  = "Default Web Site",
    [string]$LogPath   = "C:\Vault\logs\bind-cert.log",
    [int]$Port         = 443
)
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
function Log($m) { "[$ts] $m" | Tee-Object -FilePath $LogPath -Append }

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Log "Starting cert bind..."

$pfxPath = "C:\Vault\certs\vault-cert.pfx"
$pfxPass = "vault-temp-$(Get-Random)"

& openssl pkcs12 -export -in $CertPath -inkey $KeyPath -certfile $ChainPath `
    -out $pfxPath -passout "pass:$pfxPass" -name "vault-cert" 2>&1 | Out-Null

$sec  = ConvertTo-SecureString -String $pfxPass -Force -AsPlainText
$cert = Import-PfxCertificate -FilePath $pfxPath `
            -CertStoreLocation Cert:\LocalMachine\My -Password $sec
Log "Imported cert. Thumbprint: $($cert.Thumbprint) Expiry: $($cert.NotAfter)"
Remove-Item $pfxPath -Force

Import-Module WebAdministration
$b = Get-WebBinding -Name $SiteName -Protocol https -Port $Port -ErrorAction SilentlyContinue
if (-not $b) {
    New-WebBinding -Name $SiteName -IP "*" -Port $Port -Protocol https
    $b = Get-WebBinding -Name $SiteName -Protocol https -Port $Port
}
$b.AddSslCertificate($cert.Thumbprint, "My")
Log "IIS HTTPS binding updated on port $Port"

$pool = (Get-Website -Name $SiteName).applicationPool
Restart-WebAppPool -Name $pool
Log "App pool '$pool' restarted. Bind complete."
'@
Set-Content -Path "C:\Vault\hooks\bind-cert.ps1" -Value $bindCert

# ── Vault Agent config ─────────────────────────────────────────────────────
# Written fully rendered by Terraform — no runtime variables needed.
Write-Host "Writing Vault Agent config..."
$agentConfig = @"
${vault_agent_config}
"@
Set-Content -Path "C:\Vault\vault-agent.hcl" -Value $agentConfig

# ── Register as Windows service via NSSM ──────────────────────────────────
Write-Host "Registering Vault Agent as Windows service..."
nssm install VaultAgent "C:\Vault\vault.exe" "agent -config=C:\Vault\vault-agent.hcl"
nssm set VaultAgent AppDirectory   "C:\Vault"
nssm set VaultAgent AppStdout      "C:\Vault\logs\vault-agent-stdout.log"
nssm set VaultAgent AppStderr      "C:\Vault\logs\vault-agent-stderr.log"
nssm set VaultAgent AppRotateFiles 1
nssm set VaultAgent Start          SERVICE_AUTO_START
# Three restart attempts with increasing backoff
nssm set VaultAgent AppThrottle    5000
nssm start VaultAgent

Write-Host "========================================"
Write-Host " Bootstrap complete — VaultAgent running"
Write-Host "========================================"
Stop-Transcript
</powershell>
