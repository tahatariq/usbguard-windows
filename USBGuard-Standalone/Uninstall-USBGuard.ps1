#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Intune Win32 App Uninstall Script for USBGuard.
    Removes the USB lockdown policy, Volume Watcher, and tamper detection.

.DESCRIPTION
    This script is intended to be used as the uninstall command for an Intune
    Win32 app package (.intunewin). It calls USBGuard.ps1 sequentially to:
      1. Unblock all USB storage and phone connections (restore L1-L7)
      2. Remove the Volume Watcher scheduled task (L5)
      3. Remove tamper detection

    Exit codes:
      0 = success
      1 = one or more steps failed

.NOTES
    Pair with Detect-USBGuard.ps1 (detection) and Install-USBGuard.ps1 (install).
#>

$ErrorActionPreference = 'Stop'

# Resolve the directory where this script lives — USBGuard.ps1 must be alongside it
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$USBGuard  = Join-Path $ScriptDir 'USBGuard.ps1'

if (-not (Test-Path $USBGuard)) {
    Write-Error "USBGuard.ps1 not found at $USBGuard"
    exit 1
}

$exitCode = 0

# Step 1: Remove tamper detection first (so it does not re-apply policy mid-uninstall)
try {
    Write-Host "Removing tamper detection..."
    & $USBGuard -Action remove-tamper-detection
    Write-Host "Tamper detection removed successfully."
}
catch {
    Write-Warning "Failed to remove tamper detection: $_"
    $exitCode = 1
}

# Step 2: Remove Volume Watcher scheduled task (L5)
try {
    Write-Host "Removing Volume Watcher scheduled task..."
    & $USBGuard -Action remove-watcher
    Write-Host "Volume Watcher removed successfully."
}
catch {
    Write-Warning "Failed to remove Volume Watcher: $_"
    $exitCode = 1
}

# Step 3: Unblock all layers (restore L1-L7)
try {
    Write-Host "Removing USB block policy (L1-L7)..."
    & $USBGuard -Action unblock
    Write-Host "Block policy removed successfully."
}
catch {
    Write-Warning "Failed to remove block policy: $_"
    $exitCode = 1
}

if ($exitCode -eq 0) {
    Write-Host "USBGuard uninstallation completed successfully."
}
else {
    Write-Warning "USBGuard uninstallation completed with errors."
}

exit $exitCode
