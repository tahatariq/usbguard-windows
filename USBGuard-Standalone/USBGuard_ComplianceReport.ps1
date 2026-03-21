#Requires -RunAsAdministrator
<#
.SYNOPSIS
    USBGuard Compliance Report Generator

.DESCRIPTION
    Reads all 7 protection layers from the registry and generates a color-coded
    HTML compliance report. Also prints a summary to the console.

    Useful for:
      - Auditing a single machine's current posture
      - Attaching to ticketing systems as evidence of policy enforcement
      - Verifying state after applying or removing USBGuard policy

.PARAMETER OutputPath
    Path for the HTML report. Defaults to %ProgramData%\USBGuard\compliance_report.html

.PARAMETER NoHtml
    Print console summary only; do not write an HTML file.

.NOTES
    Requires Administrator (needed to read some protected registry keys).
    Works on Windows 10 21H2+, Windows 11, Windows Server 2019+.
#>

param(
    [string]$OutputPath = "$env:ProgramData\USBGuard\compliance_report.html",
    [switch]$NoHtml
)

# ── Layer status helpers ──────────────────────────────────────────────────────
function Get-LayerStatusMap {
    $m = [ordered]@{}

    # L1 - USBSTOR
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name Start -EA SilentlyContinue).Start
    $m["L1 - USB Storage (USBSTOR)"] = if ($v -eq 4) { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

    # L2 - WriteProtect
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies" -Name WriteProtect -EA SilentlyContinue).WriteProtect
    $m["L2 - Write Protect"] = if ($v -eq 1) { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

    # L3 - DenyDeviceClasses
    $v = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" -Name DenyDeviceClasses -EA SilentlyContinue).DenyDeviceClasses
    $m["L3 - Device Class Deny List"] = if ($v -eq 1) { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

    # L4 - AutoPlay
    $v = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name NoDriveTypeAutoRun -EA SilentlyContinue).NoDriveTypeAutoRun
    $m["L4 - AutoPlay / AutoRun"] = if ($v -eq 255) { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

    # L5 - VolumeWatcher
    $task = Get-ScheduledTask -TaskName "USBGuard_VolumeWatcher" -EA SilentlyContinue
    $m["L5 - Volume Watcher Task"] = if ($task -and $task.State -ne "Disabled") { "blocked" } elseif ($task) { "allowed" } else { "unknown" }

    # L6 - Thunderbolt
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\thunderbolt" -Name Start -EA SilentlyContinue).Start
    $m["L6 - Thunderbolt"] = if ($v -eq 4) { "blocked" } elseif ($null -eq $v) { "not_present" } else { "allowed" }

    # L7 - WPD/MTP
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver" -Name Start -EA SilentlyContinue).Start
    $m["L7 - WPD / MTP / PTP (Phones)"] = if ($v -eq 4) { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

    # L8 - SD Card Reader
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\sdbus" -Name Start -EA SilentlyContinue).Start
    $m["L8 - SD Card Reader (sdbus)"] = if ($v -eq 4) { "blocked" } elseif ($null -eq $v) { "not_present" } else { "allowed" }

    # L9 - Bluetooth File Transfer
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\BthOBEX" -Name Start -EA SilentlyContinue).Start
    $m["L9 - Bluetooth File Transfer (OBEX)"] = if ($v -eq 4) { "blocked" } elseif ($null -eq $v) { "not_present" } else { "allowed" }

    # L10 - FireWire
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\1394ohci" -Name Start -EA SilentlyContinue).Start
    $m["L10 - FireWire / IEEE 1394"] = if ($v -eq 4) { "blocked" } elseif ($null -eq $v) { "not_present" } else { "allowed" }

    return $m
}

function Get-TamperDetectionStatus {
    $task = Get-ScheduledTask -TaskName "USBGuard_TamperDetection" -EA SilentlyContinue
    if (-not $task) { return "not_installed" }
    return $task.State.ToString().ToLower()
}

function Get-AllowlistCount {
    $p = "HKLM:\SOFTWARE\USBGuard\Allowlist"
    if (-not (Test-Path $p)) { return 0 }
    return @((Get-Item $p).Property).Count
}

# ── Console output ────────────────────────────────────────────────────────────
function Write-ConsoleSummary {
    param($StatusMap, [string]$TamperStatus, [int]$AllowlistCount)

    Write-Host "`nUSBGuard Compliance Report" -ForegroundColor Cyan
    Write-Host "  Machine  : $env:COMPUTERNAME"
    Write-Host "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ("=" * 55)

    foreach ($layer in $StatusMap.Keys) {
        $s = $StatusMap[$layer]
        $color = switch ($s) {
            "blocked"     { "Green" }
            "not_present" { "DarkGray" }
            "unknown"     { "Yellow" }
            default       { "Red" }
        }
        $icon = switch ($s) {
            "blocked"     { "[BLOCKED]  " }
            "not_present" { "[N/A]      " }
            "unknown"     { "[UNKNOWN]  " }
            default       { "[ALLOWED]  " }
        }
        Write-Host "  $icon $layer" -ForegroundColor $color
    }

    Write-Host ("-" * 55)
    Write-Host "  Tamper Detection : $TamperStatus"
    Write-Host "  Allowlist Entries: $AllowlistCount"

    $blocked = ($StatusMap.Values | Where-Object { $_ -eq "blocked" }).Count
    $total   = ($StatusMap.Values | Where-Object { $_ -ne "not_present" }).Count
    $pct     = if ($total -gt 0) { [math]::Round($blocked / $total * 100) } else { 0 }

    Write-Host ("-" * 55)
    $overallColor = if ($pct -eq 100) { "Green" } elseif ($pct -ge 50) { "Yellow" } else { "Red" }
    Write-Host "  Overall: $blocked/$total layers active ($pct% compliant)" -ForegroundColor $overallColor
    Write-Host ""
}

# ── HTML report builder ───────────────────────────────────────────────────────
function Build-HtmlReport {
    param($StatusMap, [string]$TamperStatus, [int]$AllowlistCount)

    $blocked = ($StatusMap.Values | Where-Object { $_ -eq "blocked" }).Count
    $total   = ($StatusMap.Values | Where-Object { $_ -ne "not_present" }).Count
    $pct     = if ($total -gt 0) { [math]::Round($blocked / $total * 100) } else { 0 }
    $ts      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $rowsHtml = foreach ($layer in $StatusMap.Keys) {
        $s    = $StatusMap[$layer]
        $cls  = switch ($s) { "blocked" { "blocked" } "not_present" { "na" } "unknown" { "unknown" } default { "allowed" } }
        $label = switch ($s) { "blocked" { "BLOCKED" } "not_present" { "N/A" } "unknown" { "UNKNOWN" } default { "ALLOWED" } }
        "<tr><td>$layer</td><td class='status $cls'>$label</td></tr>"
    }

    $overallCls = if ($pct -eq 100) { "blocked" } elseif ($pct -ge 50) { "unknown" } else { "allowed" }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>USBGuard Compliance Report - $env:COMPUTERNAME</title>
<style>
  body { font-family: Segoe UI, sans-serif; background: #1a1a2e; color: #e0e0e0; margin: 40px; }
  h1   { color: #00d4ff; font-size: 1.6em; }
  .meta { color: #888; font-size: 0.9em; margin-bottom: 24px; }
  table { border-collapse: collapse; width: 100%; max-width: 700px; }
  th, td { padding: 10px 16px; text-align: left; border-bottom: 1px solid #333; }
  th { background: #16213e; color: #00d4ff; }
  tr:hover { background: #16213e; }
  .status { font-weight: bold; border-radius: 4px; padding: 3px 10px; }
  .blocked { color: #00e676; }
  .allowed { color: #ff5252; }
  .unknown { color: #ffd740; }
  .na      { color: #666; }
  .summary { margin-top: 24px; padding: 16px; background: #16213e; border-radius: 8px; max-width: 700px; }
  .summary span { font-weight: bold; }
</style>
</head>
<body>
<h1>USBGuard Compliance Report</h1>
<div class="meta">Machine: <b>$env:COMPUTERNAME</b> &nbsp;|&nbsp; Generated: $ts</div>
<table>
  <tr><th>Protection Layer</th><th>Status</th></tr>
  $($rowsHtml -join "`n  ")
</table>
<div class="summary">
  <span>Tamper Detection:</span> $TamperStatus &nbsp;|&nbsp;
  <span>Allowlist Entries:</span> $AllowlistCount &nbsp;|&nbsp;
  <span>Overall:</span> <span class="status $overallCls">$blocked/$total layers active ($pct% compliant)</span>
</div>

<h2 style="color:#00d4ff;font-size:1.2em;margin-top:32px;">Compliance Control Mapping</h2>
<table>
  <tr><th>Layer</th><th>NIST 800-53</th><th>CIS Control</th><th>Description</th></tr>
  <tr><td>L1 USBSTOR</td><td>MP-7, SI-3</td><td>CIS 10.3</td><td>Media protection — removable storage</td></tr>
  <tr><td>L2 WriteProtect</td><td>MP-7, SI-12</td><td>CIS 10.5</td><td>Media protection — write block</td></tr>
  <tr><td>L3 DenyDeviceClasses</td><td>CM-7, SI-3</td><td>CIS 2.7</td><td>Least functionality — device class restriction</td></tr>
  <tr><td>L4 AutoPlay</td><td>SI-3, SC-18</td><td>CIS 10.1</td><td>Malicious code protection — AutoRun</td></tr>
  <tr><td>L5 VolumeWatcher</td><td>SI-4, AU-6</td><td>CIS 10.4</td><td>System monitoring — real-time ejection</td></tr>
  <tr><td>L6 Thunderbolt</td><td>MP-7, AC-19</td><td>CIS 10.3</td><td>Access control — external ports</td></tr>
  <tr><td>L7 WPD/MTP/PTP</td><td>MP-7, SI-3</td><td>CIS 10.3</td><td>Media protection — mobile device data</td></tr>
  <tr><td>L8 SD Card</td><td>MP-7, AC-19</td><td>CIS 10.3</td><td>Media protection — SD card readers</td></tr>
  <tr><td>L9 Bluetooth FT</td><td>AC-18, SC-40</td><td>CIS 15.7</td><td>Wireless access — file transfer</td></tr>
  <tr><td>L10 FireWire</td><td>MP-7, AC-19</td><td>CIS 10.3</td><td>Media protection — legacy DMA ports</td></tr>
  <tr><td>Tamper Detection</td><td>SI-7, AU-9</td><td>CIS 10.4</td><td>Software integrity — policy enforcement</td></tr>
</table>
</body>
</html>
"@
}

# ── Main ──────────────────────────────────────────────────────────────────────
$statusMap     = Get-LayerStatusMap
$tamperStatus  = Get-TamperDetectionStatus
$allowlistCount = Get-AllowlistCount

Write-ConsoleSummary -StatusMap $statusMap -TamperStatus $tamperStatus -AllowlistCount $allowlistCount

if (-not $NoHtml) {
    $dir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    $htmlContent = Build-HtmlReport -StatusMap $statusMap -TamperStatus $tamperStatus -AllowlistCount $allowlistCount
    Set-Content -Path $OutputPath -Value $htmlContent -Encoding UTF8

    # Generate integrity hash for non-repudiation
    $hashPath = "$OutputPath.sha256"
    $hash = (Get-FileHash -Path $OutputPath -Algorithm SHA256).Hash
    $hashLine = "$hash  $(Split-Path $OutputPath -Leaf)  Generated=$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')  Machine=$env:COMPUTERNAME"
    Set-Content -Path $hashPath -Value $hashLine -Encoding UTF8
    Write-Host "Report written to: $OutputPath" -ForegroundColor Cyan
    Write-Host "Integrity hash:    $hashPath ($hash)" -ForegroundColor DarkGray
}
