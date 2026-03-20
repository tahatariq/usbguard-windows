# USBGuard — Standalone Deployment Package (v4)

## Overview

Manual or script-based deployment for individual machines where BigFix is not available. Includes a full graphical admin interface (HTA), PowerShell backend with 7 protection layers, background volume watcher, and Windows toast notifications to inform users when a blocked device is plugged in.

**Requires local Administrator privileges.** UAC elevation is requested automatically on launch.

> **Note:** Registry keys are not ACL-protected in this package — a local administrator can revert changes via regedit. If you need tamper protection at the registry level, use the BigFix package instead.

---

## Files

| File | Purpose |
|------|---------|
| `Launch_USBGuard.bat` | **Start here** — auto-elevates via UAC, launches the GUI |
| `USBGuard.hta` | Full graphical interface (Windows HTML Application) |
| `USBGuard.ps1` | PowerShell backend — all 7 protection layers + notification system |
| `USBGuard_Advanced.ps1` | List connected USB devices, export policy |

---

## Protection Layers (v4)

| Layer | Mechanism | What it blocks |
|-------|-----------|----------------|
| L1 | `USBSTOR` service `Start=4` | USB flash drives, external HDDs, USB-C drives |
| L2 | `StorageDevicePolicies\WriteProtect=1` | Any writes to removable storage (forensic write-block) |
| L3 | `DenyDeviceClasses` Group Policy (GUIDs) | Disk drive, CD-ROM, floppy/removable classes |
| L4 | `NoDriveTypeAutoRun=0xFF` + `ShellHWDetection` stopped | AutoPlay popup window, AutoRun |
| L5 | WMI Volume Watcher (SYSTEM Scheduled Task) | Auto-ejects within ~1 second of mount + user toast |
| L6 | `thunderbolt` service `Start=4` | Thunderbolt external drives |
| L7 | WPD services disabled + MTP/PTP/Imaging GUIDs denied | Android (MTP), iPhone/iTunes (PTP), cameras, media players |

**Always preserved:** Keyboards, mice, USB audio, USB hubs, USB charging (VBUS power is electrical — unaffected by any layer).

---

## What Gets Blocked vs. Allowed

| Device / Connection | Blocked? |
|---|:-:|
| USB flash drive (2.0 / 3.x) | ✅ |
| USB external hard drive | ✅ |
| USB-C external storage | ✅ |
| Thunderbolt drive | ✅ |
| USB CD/DVD drive | ✅ |
| USB printer | ✅ |
| Android phone — File Transfer (MTP) | ✅ L7 |
| Android phone — via app like ES File Explorer over USB | ✅ L7 |
| iPhone — iTunes file sync / backup | ✅ L7 |
| iPhone — Windows Photos import (PTP) | ✅ L7 |
| USB camera (PTP/MTP) | ✅ L7 |
| USB media player (MTP) | ✅ L7 |
| USB keyboard / mouse | ❌ Never blocked |
| USB headset / audio | ❌ Never blocked |
| USB charging (any device) | ❌ Never blocked |
| Network drives / cloud sync apps | ❌ Out of scope (network layer) |
| Bluetooth file transfer | ❌ Out of scope (different stack) |

---

## How to Use

### GUI (Recommended)
1. Double-click `Launch_USBGuard.bat`
2. Accept the UAC prompt
3. Use the per-category buttons or **Block All / Allow All**
4. Set your company name and notification message in the Notification panel

### Command Line (run PowerShell as Administrator)

```powershell
# Check current status of all layers (returns JSON)
.\USBGuard.ps1 -Action status

# Full block — all 7 layers
.\USBGuard.ps1 -Action block

# Full unblock — restore everything
.\USBGuard.ps1 -Action unblock

# Block/allow USB mass storage only (L1-L4, L5, L6)
.\USBGuard.ps1 -Action block-storage
.\USBGuard.ps1 -Action unblock-storage

# Block/allow MTP/PTP phones and cameras only (L7)
.\USBGuard.ps1 -Action block-phones
.\USBGuard.ps1 -Action unblock-phones

# Block/allow USB printers only
.\USBGuard.ps1 -Action block-printers
.\USBGuard.ps1 -Action unblock-printers

# Install or remove the background volume watcher task only
.\USBGuard.ps1 -Action install-watcher
.\USBGuard.ps1 -Action remove-watcher

# Customise the user notification message
.\USBGuard.ps1 -Action set-notify-config `
    -CompanyName "Acme IT Security" `
    -NotifyMessage "USB storage is blocked by {COMPANY} policy. Call ext 1234 for access."

# List currently connected USB devices (useful for auditing)
.\USBGuard_Advanced.ps1 -Action list-devices

# Export current policy to JSON
.\USBGuard_Advanced.ps1 -Action export-policy
```

---

## User Notification

When any blocked USB device is plugged in while the volume watcher is active:

1. A Windows toast notification fires immediately (before the drive is ejected) so the user understands why the device is not accessible
2. The drive is force-dismounted within ~1 second
3. No AutoPlay window appears (ShellHWDetection is stopped)

The notification message and company name are configurable in the GUI or via `set-notify-config`. The message is stored in `HKLM\SOFTWARE\USBGuard`.

**Note for MTP/PTP devices (phones, cameras):** L7 blocks the WPD driver stack, so the device never enumerates as an accessible device at all — there is no volume to eject. The phone simply shows "charging" or "USB connected" on its screen. No toast is fired because no volume event occurs; the block is silent at the OS level.

---

## Registry Keys Modified

```
HKLM\SYSTEM\CurrentControlSet\Services\USBSTOR
  Start = 4 (blocked) | 3 (allowed)

HKLM\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies
  WriteProtect = 1 (blocked) | 0 (allowed)

HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions
  DenyDeviceClasses = 1
  DenyDeviceClassesRetroactive = 1
  DenyDeviceClasses\1 = {4D36E967-E325-11CE-BFC1-08002BE10318}  (Disk drives)
  DenyDeviceClasses\2 = {4D36E965-E325-11CE-BFC1-08002BE10318}  (CD-ROM)
  DenyDeviceClasses\3 = {4D36E969-E325-11CE-BFC1-08002BE10318}  (Floppy/removable)
  DenyDeviceClasses\4 = {4D36E979-E325-11CE-BFC1-08002BE10318}  (Printers)
  DenyDeviceClasses\5 = {EEC5AD98-8080-425F-922A-DABF3DE3F69A}  (WPD/MTP)
  DenyDeviceClasses\6 = {6BDD1FC6-810F-11D0-BEC7-08002BE2092F}  (PTP/Still Image)

HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer
  NoDriveTypeAutoRun = 255 (0xFF)
  NoDriveAutoRun = 1

HKLM\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver   Start = 4
HKLM\SYSTEM\CurrentControlSet\Services\WUDFRd                Start = 4
HKLM\SYSTEM\CurrentControlSet\Services\WpdUpFltr             Start = 4
HKLM\SYSTEM\CurrentControlSet\Services\thunderbolt           Start = 4

HKLM\SOFTWARE\USBGuard
  CompanyName, NotifyMessage (notification config)
  SavedStart\* (original WPD service Start values, used during unblock)
```

---

## Requirements

- Windows 10 (21H2+) or Windows 11
- PowerShell 5.1+ (built into Windows)
- Administrator privileges (UAC prompt on launch)
- MSHTML / Internet Explorer component for HTA (standard on all Windows versions)

---

## Limitations vs. BigFix Package

- Registry keys are **not ACL-protected** — a local admin can revert via regedit
- No auto-remediation if policy is reverted
- No fleet-wide compliance reporting
- Exceptions must be managed manually per machine

For fleet deployment with tamper protection, use the **USBGuard-BigFix** package.
