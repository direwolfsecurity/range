<#
  Set-Secrets.ps1 -- fills the placeholders in out\ with real passwords, ON THIS COMPUTER ONLY.

  Run gencfg.py first. Then:
      powershell -ExecutionPolicy Bypass -File .\Set-Secrets.ps1

  out\ keeps the placeholders. Filled copies go to out\_ready\ (git-ignored, never commit it):
    <ENABLE_SECRET>     enable secret on every Cisco device (you type it)
    <ADMIN_SECRET>      the local 'admin' user on every device (you type it)
    <INSTRUCTOR_IP>     your computer's address, allowed to SSH to the gear (you type it)
    <POD_SECRET:Pnn>    one random password per pod, used for that pod's Proxmox login
                        and its firewall 'student' login (made here)

  Also writes out\_ready\pod-passwords.csv: one row per pod to print and hand out.
  You are only asked for the values the generated files actually use.
  Delete out\_ready\ when you have loaded everything.

  Dire Wolf Security range | https://github.com/direwolfsecurity/range | GPL-3.0
#>
param(
    # Read DWS_ENABLE_SECRET, DWS_ADMIN_SECRET and DWS_INSTRUCTOR_IP from the environment instead of asking.
    [switch]$FromEnvironment
)
$ErrorActionPreference = 'Stop'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$out   = Join-Path $here 'out'
$ready = Join-Path $out '_ready'
if (-not (Test-Path -LiteralPath (Join-Path $out 'pods.csv'))) { throw "No out\pods.csv. Run: python gencfg.py" }

function Read-Secret([string]$prompt, [string]$envName) {
    if ($FromEnvironment) {
        $v = [Environment]::GetEnvironmentVariable($envName)
        if (-not $v) { throw "$envName is not set." }
    } else {
        $a = Read-Host -AsSecureString $prompt
        $b = Read-Host -AsSecureString "$prompt (again)"
        $v = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
        $w = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
        if ($v -ne $w) { throw "The two entries did not match." }
    }
    if ($v.Length -lt 8) { throw "Use at least 8 characters." }
    if ($v -match "[\s?""']") { throw "No spaces, ? or quotes (the Cisco CLI and the shell treat them specially)." }
    return $v
}

# Random 12-character password: letters and digits only, no look-alikes (0/O, 1/l/I).
$chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
$rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
function New-PodPassword {
    $bytes = New-Object byte[] 12
    $rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# Which placeholders are actually used?
$files = @(Get-ChildItem -LiteralPath $out -Recurse -File |
           Where-Object { $_.FullName -notlike "$ready*" -and $_.Name -ne 'pods.csv' })
$all = ($files | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"

$values = @{}
if ($all.Contains('<ENABLE_SECRET>')) { $values['<ENABLE_SECRET>'] = Read-Secret 'Enable secret' 'DWS_ENABLE_SECRET' }
if ($all.Contains('<ADMIN_SECRET>'))  { $values['<ADMIN_SECRET>']  = Read-Secret 'Admin user password' 'DWS_ADMIN_SECRET' }
if ($all.Contains('<INSTRUCTOR_IP>')) {
    $ip = if ($FromEnvironment) { $env:DWS_INSTRUCTOR_IP } else { Read-Host 'Your computer''s IP address' }
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "That does not look like an IPv4 address." }
    $values['<INSTRUCTOR_IP>'] = $ip
}

# One password per pod that appears in any file
$podPw = @{}
foreach ($m in [regex]::Matches($all, '<POD_SECRET:(P\d+)>')) {
    $p = $m.Groups[1].Value
    if (-not $podPw.ContainsKey($p)) { $podPw[$p] = New-PodPassword }
}

# Write filled copies
foreach ($f in $files) {
    $rel  = $f.FullName.Substring($out.Length + 1)
    $dest = Join-Path $ready $rel
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dest)) | Out-Null
    $t = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($k in $values.Keys) { $t = $t.Replace($k, $values[$k]) }
    $t = [regex]::Replace($t, '<POD_SECRET:(P\d+)>', { param($m) $podPw[$m.Groups[1].Value] })
    [System.IO.File]::WriteAllText($dest, $t)
}

# Password sheet
$rows = foreach ($r in (Import-Csv -LiteralPath (Join-Path $out 'pods.csv'))) {
    if (-not $podPw.ContainsKey($r.pod)) { continue }
    [pscustomobject]@{
        Pod = $r.pod; Id = $r.id; Name = $r.name
        ProxmoxLogin = $r.proxmox_user; FirewallLogin = 'student'; FirewallMgmt = $r.fw_mgmt
        Password = $podPw[$r.pod]
    }
}
$sheet = Join-Path $ready 'pod-passwords.csv'
$rows | Export-Csv -LiteralPath $sheet -NoTypeInformation -Encoding UTF8

# Anything left unfilled on a real line? (Cisco comments start with !, shell comments with #)
$left = Get-ChildItem -LiteralPath $ready -Recurse -File | Where-Object { $_.Name -ne 'pod-passwords.csv' } |
        Select-String -Pattern '<ENABLE_SECRET>|<ADMIN_SECRET>|<INSTRUCTOR_IP>|<POD_SECRET:|<MGMT_IP>|<NIC_FOR_' |
        Where-Object { $_.Line -notmatch '^\s*[!#]' }

Write-Host ("Filled {0} files for {1} pods in {2}" -f $files.Count, $podPw.Count, $ready)
if ($left) {
    Write-Host "NOT READY - placeholders still on these lines:" -ForegroundColor Yellow
    $left | ForEach-Object { Write-Host ("   {0}:{1}  {2}" -f $_.Filename, $_.LineNumber, $_.Line.Trim()) }
    Write-Host "   <MGMT_IP>: add fw_mgmt for that pod in student-list.csv.  <NIC_FOR_..>: add its nic. Then run gencfg.py and this again." -ForegroundColor Yellow
}
Write-Host "These files contain passwords. Print pod-passwords.csv, then delete out\_ready\ when you are done." -ForegroundColor Yellow
