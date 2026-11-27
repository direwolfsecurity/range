<#
.SYNOPSIS
  Point a Windows DNS Server at the cyber range root servers.

.DESCRIPTION
  - Removes ALL existing root hints (the 13 Internet roots) and adds yours.
  - Optionally clears forwarders so the server actually recurses from the root.
  - Removes any root (".") trust anchors so DNSSEC validation can't break lookups.
  - Clears the DNS server cache and runs a test.
  Works on a standalone or AD-integrated DNS server (root hints for AD-integrated
  DNS are stored in AD and replicate to other DCs running DNS).

  Run on the Windows DNS SERVER (e.g. your range DC), in an elevated PowerShell.
  Windows *clients* don't use root hints — point them at this DNS server instead.

.EXAMPLE
  .\Set-RangeRootHints.ps1 -Root1IP 10.0.0.10 -Root2IP 10.0.0.11

.EXAMPLE
  .\Set-RangeRootHints.ps1 -Root1IP 10.0.0.10 -Root2IP 10.0.0.11 -ClearForwarders
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Root1Name = 'a.root-servers.net',
    [Parameter(Mandatory)][string]$Root1IP,
    [string]$Root1IP6,
    [string]$Root2Name = 'b.root-servers.net',
    [Parameter(Mandatory)][string]$Root2IP,
    [string]$Root2IP6,
    [switch]$ClearForwarders,
    [switch]$KeepTrustAnchors
)

$ErrorActionPreference = 'Stop'
function Log  ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

# --- Pre-flight ---------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this in an elevated (Administrator) PowerShell.'
}
if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    throw 'DnsServer module not found. Is the DNS Server role installed on this machine?'
}
Import-Module DnsServer

# A server that hosts its own "." zone ignores root hints entirely
if (Get-DnsServerZone -Name '.' -ErrorAction SilentlyContinue) {
    Warn 'This server hosts a "." zone, so root hints are ignored. Remove that zone if you want it to recurse.'
}

# --- Backup current root hints ------------------------------------------------
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $env:SystemRoot "System32\dns\roothints-backup-$stamp.txt"
Get-DnsServerRootHint | ForEach-Object {
    $ns = $_.NameServer.RecordData.NameServer
    $ips = ($_.IPAddress | ForEach-Object { $_.RecordData.IPv4Address, $_.RecordData.IPv6Address } | Where-Object { $_ }) -join ','
    "$ns $ips"
} | Set-Content -Path $backup
Log "Backed up existing root hints to $backup"

# --- Replace root hints -------------------------------------------------------
$existing = Get-DnsServerRootHint
if ($existing) {
    $existing | Remove-DnsServerRootHint -Force
    Log "Removed $(@($existing).Count) existing root hint(s)"
}

function Add-Hint($name, $ip4, $ip6) {
    $fq = $name.TrimEnd('.') + '.'
    $ips = @($ip4); if ($ip6) { $ips += $ip6 }
    Add-DnsServerRootHint -NameServer $fq -IPAddress $ips
    Log "Added root hint $fq -> $($ips -join ', ')"
}
Add-Hint $Root1Name $Root1IP $Root1IP6
Add-Hint $Root2Name $Root2IP $Root2IP6

# --- Forwarders ---------------------------------------------------------------
$fwd = Get-DnsServerForwarder
if ($fwd.IPAddress) {
    if ($ClearForwarders) {
        $fwd.IPAddress | ForEach-Object { Remove-DnsServerForwarder -IPAddress $_ -Force }
        Log 'Cleared forwarders'
    } else {
        Warn "Forwarders are set ($($fwd.IPAddress -join ', ')). Root hints are only used if forwarding fails."
        Warn 'Re-run with -ClearForwarders for true recursion from the range root.'
    }
}
Set-DnsServerForwarder -UseRootHint $true -ErrorAction SilentlyContinue
Set-DnsServerRecursion -Enable $true

# --- DNSSEC trust anchors for "." (real root KSK would fail against a fake root)
if (-not $KeepTrustAnchors) {
    $ta = Get-DnsServerTrustAnchor -Name '.' -ErrorAction SilentlyContinue
    if ($ta) {
        try {
            $ta | Remove-DnsServerTrustAnchor -Force -ErrorAction Stop
            Log 'Removed root trust anchor(s)'
        } catch {
            Warn "Couldn't remove root trust anchors automatically: $($_.Exception.Message)"
            Warn 'Remove them in DNS Manager > Trust Points > "." , or run: Remove-DnsServerTrustAnchor -Name . -Force'
        }
    } else { Log 'No root trust anchors present' }
}

# --- Flush + test -------------------------------------------------------------
Clear-DnsServerCache -Force
Log 'DNS server cache cleared'

Log 'Current root hints:'
Get-DnsServerRootHint | ForEach-Object {
    '   {0,-28} {1}' -f $_.NameServer.RecordData.NameServer,
        (($_.IPAddress | ForEach-Object { $_.RecordData.IPv4Address, $_.RecordData.IPv6Address } | Where-Object { $_ }) -join ', ')
}

Log 'Testing root servers directly:'
foreach ($ip in @($Root1IP, $Root2IP)) {
    try {
        $soa = Resolve-DnsName -Name '.' -Type SOA -Server $ip -DnsOnly -NoHostsFile -ErrorAction Stop |
               Where-Object { $_.Type -eq 'SOA' } | Select-Object -First 1
        Write-Host ("   {0,-15} OK   serial {1}" -f $ip, $soa.SerialNumber)
    } catch {
        Write-Host ("   {0,-15} FAIL {1}" -f $ip, $_.Exception.Message) -ForegroundColor Red
    }
}
Log 'Done. Test recursion with:  Resolve-DnsName <host.in.a.range.tld> -Server 127.0.0.1'