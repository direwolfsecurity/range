<#
.SYNOPSIS
  Trust the range root certificate on Windows (Edge, Chrome, Firefox and most programs).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Install-RangeRoot.ps1 -Fingerprint <sha256>

.EXAMPLE
  .\Install-RangeRoot.ps1 -File .\root_ca.crt -Fingerprint <sha256>

.EXAMPLE
  .\Install-RangeRoot.ps1 -Remove

.NOTES
  Run in PowerShell as Administrator. It adds the root to the computer's
  "Trusted Root Certification Authorities" store, and tells Firefox to use that store.
  On a domain, a Group Policy can do the same for every PC (see the CA README).
  License: GPL-3.0, Dire Wolf Security.
#>
param(
    [string]$Url = "http://ca.lab",
    [string]$File = "",
    [string]$Fingerprint = "",
    [string]$Name = "Dire Wolf Range Root CA",
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: run PowerShell as Administrator."; exit 1 }

$firefoxKey = "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\Certificates"

if ($Remove) {
    $found = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*CN=$Name*" }
    foreach ($c in $found) {
        Remove-Item -Path ("Cert:\LocalMachine\Root\" + $c.Thumbprint)
        Write-Host "Removed $($c.Subject)"
    }
    if (-not $found) { Write-Host "Nothing named '$Name' in the root store." }
    exit 0
}

# 1. Get the certificate
$tmp = Join-Path $env:TEMP "range_root_ca.crt"
if ($File) {
    Copy-Item $File $tmp -Force
    Write-Host "From file $File"
} else {
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$Url/root_ca.crt" -OutFile $tmp
    } catch {
        Write-Host "ERROR: could not download $Url/root_ca.crt. Does ca.lab resolve? (Resolve-DnsName ca.lab)"
        exit 1
    }
    Write-Host "Downloaded $Url/root_ca.crt"
}
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $tmp

# 2. Check the fingerprint (SHA-256 of the certificate, as plain lowercase hex)
$sha = [System.Security.Cryptography.SHA256]::Create()
$got = ($sha.ComputeHash($cert.RawData) | ForEach-Object { $_.ToString("x2") }) -join ""
Write-Host "Name:        $($cert.Subject)"
Write-Host "Fingerprint: $got"
if ($Fingerprint) {
    $want = ($Fingerprint -replace "[:\s]", "").ToLower()
    if ($got -ne $want) {
        Write-Host "ERROR: fingerprint does NOT match. Someone may have swapped the certificate. Not installing it."
        exit 1
    }
    Write-Host "Matches the one you gave."
} else {
    $answer = Read-Host "Does it match the fingerprint your teacher posted? [y/N]"
    if ($answer -ne "y") { Write-Host "Not installing it."; exit 1 }
}

# 3. Computer root store (Edge, Chrome and most Windows programs use it)
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Write-Host "Added to Trusted Root Certification Authorities (Local Computer)."

# 4. Firefox: use the Windows store too
New-Item -Path $firefoxKey -Force | Out-Null
New-ItemProperty -Path $firefoxKey -Name "ImportEnterpriseRoots" -Value 1 -PropertyType DWord -Force | Out-Null
Write-Host "Firefox told to trust the Windows store (restart Firefox, check about:policies)."

Remove-Item $tmp -Force
Write-Host "Done. Test it: curl.exe -I https://ca.lab/health"
