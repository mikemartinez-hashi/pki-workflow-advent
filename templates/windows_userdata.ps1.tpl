<powershell>
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path "C:\Vault\certs" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\tpl"   | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\hooks" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\logs"  | Out-Null
Start-Transcript -Path "C:\Vault\logs\userdata-transcript.txt"

Write-Host "========================================"
Write-Host " Vault Agent Bootstrap (Windows IIS)"
Write-Host "========================================"

# ── Install Vault ──────────────────────────────────────────────────────────
Write-Host "Downloading Vault..."
$latestUrl = "https://api.releases.hashicorp.com/v1/releases/vault/latest?license_class=oss"
$vaultVer  = (Invoke-RestMethod -Uri $latestUrl).version
$vaultUrl  = "https://releases.hashicorp.com/vault/$vaultVer/vault_$($vaultVer)_windows_amd64.zip"
Invoke-WebRequest -Uri $vaultUrl -OutFile "C:\Vault\vault.zip" -UseBasicParsing
Expand-Archive -Path "C:\Vault\vault.zip" -DestinationPath "C:\Vault" -Force
Remove-Item "C:\Vault\vault.zip"
Write-Host "Vault $vaultVer installed."

# ── Install IIS ────────────────────────────────────────────────────────────
Write-Host "Installing IIS..."
Install-WindowsFeature -Name Web-Server -IncludeManagementTools

# ── Install Chocolatey ─────────────────────────────────────────────────────
Write-Host "Installing Chocolatey..."
Set-ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Reload PATH so choco-installed tools are immediately available
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + `
            [System.Environment]::GetEnvironmentVariable("Path","User")

# ── Install OpenSSL and NSSM via Chocolatey ───────────────────────────────
Write-Host "Installing OpenSSL and NSSM..."
& "C:\ProgramData\chocolatey\bin\choco.exe" install openssl nssm -y --no-progress
if ($LASTEXITCODE -ne 0) { throw "Chocolatey install failed" }

# Reload PATH again after OpenSSL and NSSM install
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + `
            [System.Environment]::GetEnvironmentVariable("Path","User")

# Verify NSSM is findable
$nssmPath = (Get-Command nssm -ErrorAction SilentlyContinue)?.Source
if (-not $nssmPath) { $nssmPath = "C:\ProgramData\chocolatey\bin\nssm.exe" }
Write-Host "NSSM path: $nssmPath"

# ── AppRole credentials ────────────────────────────────────────────────────
Write-Host "Writing AppRole credentials..."
[System.IO.File]::WriteAllText("C:\Vault\role_id",   "${role_id}")
[System.IO.File]::WriteAllText("C:\Vault\secret_id", "${secret_id}")

# ── Vault Agent template files (values baked in by Terraform) ─────────────
Write-Host "Writing Vault Agent template files..."

# cert.tpl — Terraform has already substituted pki_role_path, common_name, cert_ttl
[System.IO.File]::WriteAllText("C:\Vault\tpl\cert.tpl", @'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ .Data.certificate -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
'@)

# key.tpl
[System.IO.File]::WriteAllText("C:\Vault\tpl\key.tpl", @'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ .Data.private_key -}}
{{- end }}
'@)

# chain.tpl
[System.IO.File]::WriteAllText("C:\Vault\tpl\chain.tpl", @'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
'@)

# ── bind-cert.ps1 hook ─────────────────────────────────────────────────────
Write-Host "Writing bind-cert hook..."
[System.IO.File]::WriteAllText("C:\Vault\hooks\bind-cert.ps1", @'
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
Log "Imported. Thumbprint: $($cert.Thumbprint)  Expiry: $($cert.NotAfter)"
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
Log "App pool '$pool' restarted. Done."
'@)

# ── Vault Agent config ─────────────────────────────────────────────────────
Write-Host "Writing Vault Agent config..."
[System.IO.File]::WriteAllText("C:\Vault\vault-agent.hcl", @"
${vault_agent_config}
"@)

# ── Register VaultAgent service via NSSM ──────────────────────────────────
Write-Host "Registering VaultAgent service..."
& $nssmPath install VaultAgent "C:\Vault\vault.exe" "agent -config=C:\Vault\vault-agent.hcl"
& $nssmPath set VaultAgent AppDirectory  "C:\Vault"
& $nssmPath set VaultAgent AppStdout     "C:\Vault\logs\vault-agent-stdout.log"
& $nssmPath set VaultAgent AppStderr     "C:\Vault\logs\vault-agent-stderr.log"
& $nssmPath set VaultAgent AppRotateFiles 1
& $nssmPath set VaultAgent Start         SERVICE_AUTO_START
& $nssmPath start VaultAgent

Write-Host "VaultAgent service started."
Write-Host "========================================"
Write-Host " Bootstrap complete"
Write-Host "========================================"
Stop-Transcript
</powershell>
