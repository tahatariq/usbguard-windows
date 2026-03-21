#Requires -RunAsAdministrator
<#
.SYNOPSIS
    USBGuard Pre-Block Device Snapshot

.DESCRIPTION
    Run this BEFORE applying USBGuard policy to enumerate all currently
    connected USB storage devices and optionally add them to the allowlist
    so they remain accessible after policy is applied.

    Typical workflow:
      1. .\USBGuard_Snapshot.ps1 -Preview      # Review what will be allowlisted
      2. .\USBGuard_Snapshot.ps1 -Apply        # Add all found devices to allowlist
      3. .\USBGuard.ps1 -Action block          # Apply policy

.PARAMETER Preview
    List devices that would be allowlisted without making any changes (default).

.PARAMETER Apply
    Add all found USB storage devices to the USBGuard allowlist.

.PARAMETER USBGuardScript
    Path to USBGuard.ps1. Defaults to the same directory as this script.

.NOTES
    Requires Administrator. Windows 10/11 and Windows Server 2019+.
    Only allowlists mass storage (USBSTOR). Phones/printers are handled
    by separate USBGuard layers and are not enumerated here.
#>

param(
    [switch]$Preview,
    [switch]$Apply,
    [string]$USBGuardScript = "$PSScriptRoot\USBGuard.ps1"
)

# Default to Preview if neither flag given
if (-not $Preview -and -not $Apply) { $Preview = $true }

function Get-UsbStorageDevices {
    $devices = Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceType -eq "USB" -or $_.PNPDeviceID -like "USBSTOR*" }
    return $devices
}

# Build a clean prefix from a full PNP Device ID
# "USBSTOR\DISK&VEN_SanDisk&PROD_Ultra&REV_1.00\4C530001234567&0" -> "USBSTOR\DISK&VEN_SanDisk&PROD_Ultra&REV_1.00\4C530001234567"
function Get-PnpPrefix {
    param([string]$FullId)
    if ($FullId -match '^(.+)&\d+$') { return $Matches[1] }
    return $FullId
}

Write-Host "`nUSBGuard Pre-Block Device Snapshot" -ForegroundColor Cyan
Write-Host ("=" * 55)

$devices = Get-UsbStorageDevices

if (-not $devices) {
    Write-Host "`nNo USB mass storage devices currently connected." -ForegroundColor DarkGray
    Write-Host "Connect devices you want to allow BEFORE running -Apply.`n"
    exit 0
}

Write-Host "`nFound $(@($devices).Count) USB mass storage device(s):`n"

$entries = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($d in @($devices)) {
    $prefix = Get-PnpPrefix -FullId $d.PNPDeviceID
    $size   = if ($d.Size) { "$([math]::Round($d.Size / 1GB, 1)) GB" } else { "unknown size" }
    $entries.Add([pscustomobject]@{
        Caption  = $d.Caption
        Size     = $size
        FullId   = $d.PNPDeviceID
        Prefix   = $prefix
    })
    Write-Host "  Device : $($d.Caption) ($size)" -ForegroundColor White
    Write-Host "  PNP ID : $($d.PNPDeviceID)"
    Write-Host "  Prefix : $prefix`n"
}

if ($Preview) {
    Write-Host "Preview mode - no changes made." -ForegroundColor Yellow
    Write-Host "Run with -Apply to add these $($entries.Count) device(s) to the allowlist.`n"
    exit 0
}

# ── Apply: add to allowlist ───────────────────────────────────────────────────
if (-not (Test-Path $USBGuardScript)) {
    Write-Host "USBGuard.ps1 not found at: $USBGuardScript" -ForegroundColor Red
    Write-Host "Use -USBGuardScript to specify the path." -ForegroundColor Red
    exit 1
}

Write-Host "Adding devices to allowlist..." -ForegroundColor Cyan
$added  = 0
$failed = 0

foreach ($e in $entries) {
    Write-Host "  Adding: $($e.Prefix)"
    try {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $USBGuardScript -Action add-allowlist -DeviceId $e.Prefix
        $added++
    } catch {
        Write-Host "  Failed to add $($e.Prefix): $_" -ForegroundColor Red
        $failed++
    }
}

Write-Host "`nDone. Added: $added  Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Yellow" } else { "Green" })
Write-Host "You can now run: .\USBGuard.ps1 -Action block`n"
