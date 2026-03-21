#Requires -RunAsAdministrator
<#
.SYNOPSIS
    USBGuard - Bypass Attempt Simulation (Red-Team Checklist)

.DESCRIPTION
    Attempts the known bypass vectors against an active USBGuard policy and
    reports whether each attempt was blocked or succeeded.

    In BigFix mode (Fixlet 3 applied), DENY ACEs prevent even Administrators
    from reverting protected keys - those attempts will show [BLOCKED].
    In Standalone mode (no DENY ACEs), registry writes succeed but the
    tamper detection task will re-apply them within 5 minutes.

    This script RESTORES all values it changes - it is safe to run on a
    production machine.

.NOTES
    Requires Administrator. Safe - all changes are reverted at the end.
#>

param(
    [switch]$NoRestore  # Skip restore at end (for debugging only)
)

$BLOCKED = 0
$SUCCEEDED = 0
$results   = [System.Collections.Generic.List[pscustomobject]]::new()

function Test-Bypass {
    param(
        [string]$Label,
        [scriptblock]$Attempt,
        [scriptblock]$Restore
    )
    $outcome = $null
    try {
        & $Attempt
        $outcome = "SUCCEEDED"
        $script:SUCCEEDED++
    } catch {
        $outcome = "BLOCKED ($($_.Exception.Message -replace '\r?\n',' '))"
        $script:BLOCKED++
    }
    # Always try to restore, ignore errors
    try { & $Restore } catch {}

    $color = if ($outcome -eq "SUCCEEDED") { "Yellow" } else { "Green" }
    Write-Host "  [$outcome] $Label" -ForegroundColor $color
    $script:results.Add([pscustomobject]@{ Vector = $Label; Outcome = $outcome })
}

Write-Host "`nUSBGuard Bypass Attempt Simulation" -ForegroundColor Cyan
Write-Host ("=" * 55)
Write-Host "Each bypass vector is attempted then immediately restored.`n"

# ── Vector 1: Revert USBSTOR driver (L1) ─────────────────────────────────────
Write-Host "[L1] USBSTOR driver re-enable"
$usbstorPath = "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR"
$origUsbstor = (Get-ItemProperty $usbstorPath -Name Start -EA SilentlyContinue).Start

Test-Bypass "Set USBSTOR Start=3 (re-enable USB drives)" `
    { Set-ItemProperty $usbstorPath -Name Start -Value 3 -Type DWord -Force -EA Stop } `
    { if ($null -ne $origUsbstor) { Set-ItemProperty $usbstorPath -Name Start -Value $origUsbstor -Type DWord -Force -EA SilentlyContinue } }

# ── Vector 2: Disable WriteProtect (L2) ──────────────────────────────────────
Write-Host "`n[L2] WriteProtect disable"
$wpPath = "HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies"
$origWp  = (Get-ItemProperty $wpPath -Name WriteProtect -EA SilentlyContinue).WriteProtect

Test-Bypass "Set WriteProtect=0 (allow writes to removable storage)" `
    { Set-ItemProperty $wpPath -Name WriteProtect -Value 0 -Type DWord -Force -EA Stop } `
    { if ($null -ne $origWp) { Set-ItemProperty $wpPath -Name WriteProtect -Value $origWp -Type DWord -Force -EA SilentlyContinue } }

# ── Vector 3: Remove DenyDeviceClasses key (L3) ───────────────────────────────
Write-Host "`n[L3] DenyDeviceClasses removal"
$denyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
$denyFlag = (Get-ItemProperty $denyPath -Name DenyDeviceClasses -EA SilentlyContinue).DenyDeviceClasses

Test-Bypass "Set DenyDeviceClasses=0 (re-enable device class installs)" `
    { Set-ItemProperty $denyPath -Name DenyDeviceClasses -Value 0 -Type DWord -Force -EA Stop } `
    { if ($null -ne $denyFlag) { Set-ItemProperty $denyPath -Name DenyDeviceClasses -Value $denyFlag -Type DWord -Force -EA SilentlyContinue } }

# ── Vector 4: Re-enable AutoPlay (L4) ────────────────────────────────────────
Write-Host "`n[L4] AutoPlay re-enable"
$apPath  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
$origAp  = (Get-ItemProperty $apPath -Name NoDriveTypeAutoRun -EA SilentlyContinue).NoDriveTypeAutoRun

Test-Bypass "Set NoDriveTypeAutoRun=145 (restore default AutoPlay)" `
    { Set-ItemProperty $apPath -Name NoDriveTypeAutoRun -Value 145 -Type DWord -Force -EA Stop } `
    { if ($null -ne $origAp) { Set-ItemProperty $apPath -Name NoDriveTypeAutoRun -Value $origAp -Type DWord -Force -EA SilentlyContinue } }

# ── Vector 5: Re-enable WPD stack (L7) ────────────────────────────────────────
Write-Host "`n[L7] WPD/MTP driver re-enable"
$wpdPath  = "HKLM:\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver"
$origWpd  = (Get-ItemProperty $wpdPath -Name Start -EA SilentlyContinue).Start

Test-Bypass "Set WpdFilesystemDriver Start=3 (re-enable phone/MTP access)" `
    { Set-ItemProperty $wpdPath -Name Start -Value 3 -Type DWord -Force -EA Stop } `
    { if ($null -ne $origWpd) { Set-ItemProperty $wpdPath -Name Start -Value $origWpd -Type DWord -Force -EA SilentlyContinue } }

# ── Vector 6: Stop VolumeWatcher task (L5) ────────────────────────────────────
Write-Host "`n[L5] VolumeWatcher task stop"
Test-Bypass "Stop-ScheduledTask USBGuard_VolumeWatcher" `
    { Stop-ScheduledTask -TaskName "USBGuard_VolumeWatcher" -EA Stop } `
    { Start-ScheduledTask -TaskName "USBGuard_VolumeWatcher" -EA SilentlyContinue }

# ── Vector 7: Kill ShellHWDetection (L4 component) ───────────────────────────
Write-Host "`n[L4] ShellHWDetection service"
Test-Bypass "Start-Service ShellHWDetection (re-enable AutoPlay service)" `
    { Start-Service -Name "ShellHWDetection" -EA Stop } `
    { Stop-Service -Name "ShellHWDetection" -Force -EA SilentlyContinue }

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n$('=' * 55)"
Write-Host "Results:"
$results | Format-Table -AutoSize

Write-Host "Blocked   : $BLOCKED / $($results.Count)" -ForegroundColor Green
Write-Host "Succeeded : $SUCCEEDED / $($results.Count)" -ForegroundColor $(if ($SUCCEEDED -gt 0) { "Yellow" } else { "Green" })

if ($SUCCEEDED -gt 0) {
    Write-Host "`nNote: Succeeded attempts were immediately restored." -ForegroundColor Yellow
    Write-Host "      In standalone mode, tamper detection re-applies within 5 min." -ForegroundColor Yellow
    Write-Host "      In BigFix mode, DENY ACEs should block these - run Fixlet 3 to lock." -ForegroundColor Yellow
}

exit 0
