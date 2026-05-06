# bind-cert.ps1
# Imports Vault-issued certificate into Windows cert store
# and updates IIS HTTPS binding - runs on each cert renewal

param(
    [string]$CertPath    = "C:\Vault\certs\cert.pem",
    [string]$KeyPath     = "C:\Vault\certs\key.pem",
    [string]$ChainPath   = "C:\Vault\certs\chain.pem",
    [string]$SiteName    = "Default Web Site",
    [string]$LogPath     = "C:\Vault\logs\bind-cert.log",
    [int]$Port           = 443
)

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Write-Log {
    param([string]$Message)
    $entry = "[$timestamp] $Message"
    Add-Content -Path $LogPath -Value $entry
    Write-Host $entry
}

Write-Log "Starting cert bind process..."

# Ensure log directory exists
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null

try {
    # Convert PEM to PFX using openssl (must be installed)
    $pfxPath = "C:\Vault\certs\vault-cert.pfx"
    $pfxPass = "vault-temp-$(Get-Random)"

    & openssl pkcs12 -export `
        -in $CertPath `
        -inkey $KeyPath `
        -certfile $ChainPath `
        -out $pfxPath `
        -passout "pass:$pfxPass" `
        -name "vault-cert" 2>&1 | Out-Null

    Write-Log "PFX created at $pfxPath"

    # Import into LocalMachine\My store
    $secPass = ConvertTo-SecureString -String $pfxPass -Force -AsPlainText
    $cert = Import-PfxCertificate `
        -FilePath $pfxPath `
        -CertStoreLocation Cert:\LocalMachine\My `
        -Password $secPass

    Write-Log "Cert imported. Thumbprint: $($cert.Thumbprint)"
    Write-Log "Subject: $($cert.Subject)"
    Write-Log "Expiry:  $($cert.NotAfter)"

    # Remove temp PFX
    Remove-Item $pfxPath -Force

    # Update IIS HTTPS binding
    Import-Module WebAdministration
    $binding = Get-WebBinding -Name $SiteName -Protocol "https" -Port $Port
    if ($binding) {
        $binding.AddSslCertificate($cert.Thumbprint, "My")
        Write-Log "IIS HTTPS binding updated for site: $SiteName on port $Port"
    } else {
        Write-Log "WARNING: No HTTPS binding found for $SiteName on port $Port"
    }

    # Restart IIS app pool to pick up new cert
    $appPool = (Get-Website -Name $SiteName).applicationPool
    Restart-WebAppPool -Name $appPool
    Write-Log "App pool '$appPool' restarted."

    Write-Log "Cert bind complete."

} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
