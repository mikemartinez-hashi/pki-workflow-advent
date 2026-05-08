<powershell>
# Selective error handling -- not Stop for everything
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path "C:\Vault\certs" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\tpl"   | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\hooks" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Vault\logs"  | Out-Null
Start-Transcript -Path "C:\Vault\logs\userdata-transcript.txt" -Append

function Write-Log {
    param($msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$ts] $msg" | Tee-Object -FilePath "C:\Vault\logs\userdata-transcript.txt" -Append
    Write-Host "[$ts] $msg"
}

Write-Log "========================================"
Write-Log " Vault Agent Bootstrap (Windows IIS)"
Write-Log "========================================"

# ── Install IIS ────────────────────────────────────────────────────────────
Write-Log "Installing IIS..."
try {
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction Stop
    Write-Log "IIS installed."
} catch {
    Write-Log "WARNING: IIS install error: $_"
}

# ── Download Vault (pinned version) ────────────────────────────────────────
Write-Log "Downloading Vault ${vault_version}..."
try {
    $vaultVer = "${vault_version}"
    $vaultUrl = "https://releases.hashicorp.com/vault/$vaultVer/vault_$($vaultVer)_windows_amd64.zip"
    Invoke-WebRequest -Uri $vaultUrl -OutFile "C:\Vault\vault.zip" -UseBasicParsing -ErrorAction Stop
    Expand-Archive -Path "C:\Vault\vault.zip" -DestinationPath "C:\Vault" -Force
    Remove-Item "C:\Vault\vault.zip"
    Write-Log "Vault $vaultVer installed at C:\Vault\vault.exe"
} catch {
    Write-Log "ERROR: Vault download failed: $_"
    Stop-Transcript; exit 1
}

# ── Download NSSM directly (no Chocolatey) ─────────────────────────────────
Write-Log "Downloading NSSM..."
try {
    $nssmZipUrl = "https://nssm.cc/release/nssm-2.24.zip"
    Invoke-WebRequest -Uri $nssmZipUrl -OutFile "C:\Vault\nssm.zip" -UseBasicParsing -ErrorAction Stop
    Expand-Archive -Path "C:\Vault\nssm.zip" -DestinationPath "C:\Vault\nssm-tmp" -Force
    Copy-Item "C:\Vault\nssm-tmp\nssm-2.24\win64\nssm.exe" -Destination "C:\Vault\nssm.exe" -Force
    Remove-Item "C:\Vault\nssm.zip", "C:\Vault\nssm-tmp" -Recurse -Force
    Write-Log "NSSM installed at C:\Vault\nssm.exe"
} catch {
    Write-Log "ERROR: NSSM download failed: $_"
    Stop-Transcript; exit 1
}

# ── Download OpenSSL portable (no Chocolatey) ──────────────────────────────
# Used by bind-cert.ps1 for PEM to PFX conversion
Write-Log "Downloading OpenSSL..."
try {
    # OpenSSL 3.x Light for Windows 64-bit from Shining Light Productions
    $opensslUrl = "https://slproweb.com/download/Win64OpenSSL_Light-3_3_2.exe"
    Invoke-WebRequest -Uri $opensslUrl -OutFile "C:\Vault\openssl-installer.exe" -UseBasicParsing -ErrorAction Stop
    Start-Process -FilePath "C:\Vault\openssl-installer.exe" `
        -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-" `
        -Wait -NoNewWindow -ErrorAction Stop
    Remove-Item "C:\Vault\openssl-installer.exe" -Force
    Write-Log "OpenSSL installed."
    # Add to PATH for this session
    $env:Path += ";C:\Program Files\OpenSSL-Win64\bin"
} catch {
    Write-Log "WARNING: OpenSSL install failed: $_. bind-cert.ps1 will attempt to locate openssl.exe at runtime."
}

# ── AppRole credentials ────────────────────────────────────────────────────
Write-Log "Writing AppRole credentials..."
[System.IO.File]::WriteAllText("C:\Vault\role_id",   "${role_id}")
[System.IO.File]::WriteAllText("C:\Vault\secret_id", "${secret_id}")

# ── Vault Agent template files (values baked in by Terraform) ─────────────
Write-Log "Writing Vault Agent template files..."

[System.IO.File]::WriteAllText("C:\Vault\tpl\cert.tpl", @'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ .Data.certificate -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
'@)

[System.IO.File]::WriteAllText("C:\Vault\tpl\key.tpl", @'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ .Data.private_key -}}
{{- end }}
'@)

[System.IO.File]::WriteAllText("C:\Vault\tpl\chain.tpl", @'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ range .Data.ca_chain -}}
{{ . -}}
{{ end -}}
{{- end }}
'@)

# ── bind-cert.ps1 hook ─────────────────────────────────────────────────────
Write-Log "Writing bind-cert hook..."
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

# Find openssl.exe
$opensslCandidates = @(
    "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
    "C:\Program Files (x86)\OpenSSL-Win64\bin\openssl.exe",
    (Get-Command openssl -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
)
$opensslExe = $opensslCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $opensslExe) { Log "ERROR: openssl.exe not found."; exit 1 }

$pfxPath = "C:\Vault\certs\vault-cert.pfx"
$pfxPass = "vault-temp-$(Get-Random)"

& $opensslExe pkcs12 -export -in $CertPath -inkey $KeyPath -certfile $ChainPath `
    -out $pfxPath -passout "pass:$pfxPass" -name "vault-cert" 2>&1 | ForEach-Object { Log $_ }

if (-not (Test-Path $pfxPath)) { Log "ERROR: PFX creation failed."; exit 1 }

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
exit 0
'@)

# ── Vault Agent config ─────────────────────────────────────────────────────
Write-Log "Writing Vault Agent config..."
[System.IO.File]::WriteAllText("C:\Vault\vault-agent.hcl", @"
${vault_agent_config}
"@)

# ── Register VaultAgent service via NSSM ──────────────────────────────────
Write-Log "Registering VaultAgent service..."
try {
    $nssmExe = "C:\Vault\nssm.exe"
    & $nssmExe install   VaultAgent "C:\Vault\vault.exe" "agent -config=C:\Vault\vault-agent.hcl"
    & $nssmExe set       VaultAgent AppDirectory   "C:\Vault"
    & $nssmExe set       VaultAgent AppStdout      "C:\Vault\logs\vault-agent-stdout.log"
    & $nssmExe set       VaultAgent AppStderr      "C:\Vault\logs\vault-agent-stderr.log"
    & $nssmExe set       VaultAgent AppRotateFiles 1
    & $nssmExe set       VaultAgent Start          SERVICE_AUTO_START
    & $nssmExe set       VaultAgent AppThrottle    5000
    & $nssmExe start     VaultAgent
    Write-Log "VaultAgent service started."
} catch {
    Write-Log "ERROR: Service registration failed: $_"
    Stop-Transcript; exit 1
}

Write-Log "========================================"
Write-Log " Bootstrap complete"
Write-Log "========================================"
Stop-Transcript
</powershell>
