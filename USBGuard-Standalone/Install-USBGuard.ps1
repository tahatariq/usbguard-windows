#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Intune Win32 App Install Script for USBGuard.
    Applies the full USB lockdown policy, deploys the Volume Watcher, and
    enables tamper detection.

.DESCRIPTION
    This script is intended to be used as the install command for an Intune
    Win32 app package (.intunewin). It calls USBGuard.ps1 sequentially to:
      1. Block all USB storage and phone connections (L1-L7)
      2. Install the Volume Watcher scheduled task (L5)
      3. Install tamper detection (periodic re-enforcement)

    Exit codes:
      0 = success
      1 = one or more steps failed

.NOTES
    Pair with Detect-USBGuard.ps1 (detection) and Uninstall-USBGuard.ps1 (uninstall).
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

# Step 1: Apply full block (L1-L7)
try {
    Write-Host "Applying USB block policy (L1-L7)..."
    & $USBGuard -Action block
    Write-Host "Block policy applied successfully."
}
catch {
    Write-Warning "Failed to apply block policy: $_"
    $exitCode = 1
}

# Step 2: Install Volume Watcher scheduled task (L5)
try {
    Write-Host "Installing Volume Watcher scheduled task..."
    & $USBGuard -Action install-watcher
    Write-Host "Volume Watcher installed successfully."
}
catch {
    Write-Warning "Failed to install Volume Watcher: $_"
    $exitCode = 1
}

# Step 3: Install tamper detection (periodic re-enforcement)
try {
    Write-Host "Installing tamper detection..."
    & $USBGuard -Action install-tamper-detection
    Write-Host "Tamper detection installed successfully."
}
catch {
    Write-Warning "Failed to install tamper detection: $_"
    $exitCode = 1
}

if ($exitCode -eq 0) {
    Write-Host "USBGuard installation completed successfully."
}
else {
    Write-Warning "USBGuard installation completed with errors."
}

exit $exitCode
