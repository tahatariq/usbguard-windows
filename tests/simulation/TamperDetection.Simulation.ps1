#Requires -RunAsAdministrator
<#
.SYNOPSIS
    USBGuard - Tamper Detection End-to-End Simulation

.DESCRIPTION
    Proves the tamper detection task works by:
      1. Verifying USBGuard is in a fully blocked state.
      2. Directly reverting USBSTOR Start to 3 (simulating an attacker bypass).
      3. Invoking TamperDetect.ps1 manually (so you don't wait 5 minutes).
      4. Asserting that USBSTOR Start is restored to 4.
      5. Confirming a tamper log entry was written.

    Run this after Install-TamperDetection has been called at least once
    (so TamperDetect.ps1 exists on disk).

.NOTES
    - Requires Administrator.
    - Does NOT wait for the scheduled task interval - it invokes the script directly.
    - Leaves the system in its original blocked state.
#>

param(
    [string]$TamperScript = "$env:ProgramData\USBGuard\TamperDetect.ps1",
    [string]$TamperLog    = "$env:ProgramData\USBGuard\tamper.log"
)

$PASS = 0
$FAIL = 0

function Assert-That {
    param([string]$Label, [scriptblock]$Condition)
    if (& $Condition) {
        Write-Host "  [PASS] $Label" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  [FAIL] $Label" -ForegroundColor Red
        $script:FAIL++
    }
}

Write-Host "`nUSBGuard Tamper Detection Simulation" -ForegroundColor Cyan
Write-Host ("=" * 50)

# ── Pre-condition checks ──────────────────────────────────────────────────────
Write-Host "`n[1] Pre-condition checks"

Assert-That "TamperDetect.ps1 exists on disk" {
    Test-Path $TamperScript
}

$usbstorPath = "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR"
$startBefore = (Get-ItemProperty $usbstorPath -Name Start -EA SilentlyContinue).Start

Assert-That "USBSTOR is currently blocked (Start=4)" {
    $startBefore -eq 4
}

if ($FAIL -gt 0) {
    Write-Host "`nPre-conditions not met. Apply USBGuard block first, then install tamper detection." -ForegroundColor Yellow
    exit 1
}

# ── Simulate bypass: revert USBSTOR Start to 3 ───────────────────────────────
Write-Host "`n[2] Simulating bypass - setting USBSTOR Start=3"
Set-ItemProperty $usbstorPath -Name Start -Value 3 -Type DWord -Force

Assert-That "USBSTOR Start is now 3 (bypass confirmed)" {
    (Get-ItemProperty $usbstorPath -Name Start -EA SilentlyContinue).Start -eq 3
}

# ── Invoke TamperDetect.ps1 directly ─────────────────────────────────────────
Write-Host "`n[3] Invoking TamperDetect.ps1 directly"
$logLinesBefore = if (Test-Path $TamperLog) { (Get-Content $TamperLog).Count } else { 0 }

try {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $TamperScript
} catch {
    Write-Host "  Error invoking TamperDetect.ps1: $_" -ForegroundColor Red
}

# ── Post-condition checks ─────────────────────────────────────────────────────
Write-Host "`n[4] Post-condition checks"

$startAfter = (Get-ItemProperty $usbstorPath -Name Start -EA SilentlyContinue).Start

Assert-That "USBSTOR Start restored to 4 by tamper detection" {
    $startAfter -eq 4
}

Assert-That "Tamper log was written (new entry added)" {
    if (Test-Path $TamperLog) {
        $linesAfter = (Get-Content $TamperLog).Count
        $linesAfter -gt $logLinesBefore
    } else { $false }
}

Assert-That "Tamper log contains USBSTOR tampering record" {
    if (Test-Path $TamperLog) {
        (Get-Content $TamperLog -Raw) -match "USBSTOR"
    } else { $false }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n[Summary]"
Write-Host "  Passed : $PASS" -ForegroundColor Green
Write-Host "  Failed : $FAIL" -ForegroundColor $(if ($FAIL -gt 0) { "Red" } else { "Green" })

if ($FAIL -gt 0) {
    Write-Host "`nSimulation FAILED. Check output above." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nTamper detection is working correctly." -ForegroundColor Green
    exit 0
}
