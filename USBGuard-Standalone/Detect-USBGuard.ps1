# Intune Win32 App Detection Script for USBGuard
# Exit 0 = detected (installed and compliant), Exit 1 = not detected
$compliant = $true

# L1: USBSTOR must be disabled
$v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name 'Start' -EA SilentlyContinue).Start
if ($v -ne 4) { $compliant = $false }

# L7: WPD must be disabled
$v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver' -Name 'Start' -EA SilentlyContinue).Start
if ($v -ne 4) { $compliant = $false }

# L5: VolumeWatcher task must exist
$task = Get-ScheduledTask -TaskName 'USBGuard_VolumeWatcher' -EA SilentlyContinue
if (-not $task) { $compliant = $false }

if ($compliant) { Write-Host "USBGuard detected and compliant"; exit 0 }
else { Write-Host "USBGuard not detected or non-compliant"; exit 1 }
