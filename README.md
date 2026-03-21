# USBGuard — Enterprise USB Device Management

Comprehensive USB device lockdown for Windows. Enforces a **policy-wide block** on all removable storage, phones, cameras, and printers across a fleet, with the ability to grant **per-machine temporary exceptions** through BigFix. Two deployment variants share the same 7-layer protection model.

---

## What It Blocks

| Device / Connection | Blocked | Layer |
|---|:-:|---|
| USB flash drive (2.0 / 3.x) | ✅ | L1 + L3 |
| USB external hard drive | ✅ | L1 + L3 |
| USB-C external storage | ✅ | L1 + L3 |
| Thunderbolt drive | ✅ | L6 |
| USB CD/DVD drive | ✅ | L3 |
| USB printer | ✅ | L3 |
| Android phone — File Transfer (MTP) | ✅ | L7 |
| iPhone — iTunes sync / backup (PTP) | ✅ | L7 |
| iPhone — Windows Photos import (PTP) | ✅ | L7 |
| USB camera (PTP/MTP) | ✅ | L7 |
| USB media player (MTP) | ✅ | L7 |
| USB keyboard / mouse | ❌ Never blocked | — |
| USB headset / audio | ❌ Never blocked | — |
| USB charging (any device) | ❌ Never blocked | — |
| Network drives / cloud sync | ❌ Out of scope | — |

---

## The 7 Protection Layers

| Layer | Mechanism | Effect |
|-------|-----------|--------|
| L1 | `USBSTOR` service `Start=4` | Disables USB storage class driver |
| L2 | `StorageDevicePolicies\WriteProtect=1` | Forensic write-block on any storage |
| L3 | `DenyDeviceClasses` (GUIDs) | Blocks disk, CD-ROM, floppy, printer install/use |
| L4 | `NoDriveTypeAutoRun=0xFF` + ShellHWDetection stopped | Kills AutoPlay popup |
| L5 | WMI Volume Watcher (SYSTEM scheduled task) | Auto-ejects within ~1s + user toast notification |
| L6 | `thunderbolt` service `Start=4` | Disables Thunderbolt storage |
| L7 | WPD stack disabled + MTP/PTP/Imaging GUIDs denied | Blocks Android, iPhone, cameras, media players |

---

## Project Structure

```
usb-block/
├── USBGuard-Standalone/           # GUI + PowerShell backend for individual machines
│   ├── USBGuard.ps1               # Core backend — all 7 layers, watcher, notifications
│   ├── USBGuard_Advanced.ps1      # List connected USB devices, export policy JSON
│   ├── USBGuard.hta               # Interactive GUI (Windows HTML Application)
│   └── Launch_USBGuard.bat        # UAC-elevating launcher
│
├── USBGuard-BigFix/               # Enterprise fleet deployment via HCL BigFix
│   ├── Fixlet1_ApplyPolicy.bes    # All 7 layers — idempotent, runs as SYSTEM
│   ├── Fixlet2_DeployWatcher.bes  # Volume Watcher scheduled task deployment
│   ├── Fixlet3_LockACLs.bes       # DENY ACEs on all protected registry keys
│   ├── Fixlet4_Unblock.bes        # Per-machine exception — strips ACEs + clears policy
│   └── Fixlet5_ComplianceDetection.bes  # Audit fixlet + Analysis Properties
│
├── tests/
│   ├── unit/Registry.Tests.ps1          # Registry helper function tests
│   ├── unit/StatusDetection.Tests.ps1   # Status detection tests
│   ├── unit/WpdMtp.Tests.ps1            # Layer 7 WPD/MTP/PTP tests
│   └── integration/BlockUnblock.Tests.ps1  # Block/unblock roundtrip tests
│
├── .github/workflows/pester-tests.yml  # CI pipeline
├── Run-Tests.ps1                  # Local test runner
├── CODE_VALIDATION.md             # Bug tracker and validation report
└── CLAUDE.md                      # AI project context file
```

---

## Quick Start

### Standalone (single machine)

```batch
:: Double-click or run from admin prompt:
Launch_USBGuard.bat
```

The GUI lets you block/allow by category, configure user notifications, and see live status of all 7 layers.

### Command Line (PowerShell as Administrator)

```powershell
# Check status of all layers (returns JSON)
.\USBGuard.ps1 -Action status

# Full block — all 7 layers
.\USBGuard.ps1 -Action block

# Full unblock — restore everything
.\USBGuard.ps1 -Action unblock

# Granular control
.\USBGuard.ps1 -Action block-storage      # L1-L4, L5, L6
.\USBGuard.ps1 -Action unblock-storage
.\USBGuard.ps1 -Action block-phones       # L7 — Android/iPhone/cameras
.\USBGuard.ps1 -Action unblock-phones
.\USBGuard.ps1 -Action block-printers     # L3 printer GUID
.\USBGuard.ps1 -Action unblock-printers
.\USBGuard.ps1 -Action install-watcher    # L5 scheduled task only
.\USBGuard.ps1 -Action remove-watcher

# Customise the user toast notification
.\USBGuard.ps1 -Action set-notify-config `
    -CompanyName "Acme IT Security" `
    -NotifyMessage "USB storage is blocked by {COMPANY} policy. Call ext 1234."

# Audit tools
.\USBGuard_Advanced.ps1 -Action list-devices
.\USBGuard_Advanced.ps1 -Action export-policy
```

### Enterprise (BigFix fleet)

Deploy in order:

```
Fixlet 1 (policy)  →  Fixlet 2 (watcher)  →  Fixlet 3 (lock ACLs)
```

Add all three to a Baseline scheduled every 4 hours for continuous auto-remediation.

**Granting a temporary exception:**
1. BigFix Console → run **Fixlet 4** targeted at specific computer(s) only
2. After the exception window, re-apply Fixlets 1 + 2 + 3
3. BigFix audit trail records the exception grant automatically

---

## Standalone vs BigFix

| Feature | Standalone | BigFix |
|---------|:----------:|:------:|
| Interactive GUI | ✅ HTA | — |
| 7-layer USB protection | ✅ | ✅ |
| MTP/PTP blocking (L7) | ✅ | ✅ |
| User toast notification | ✅ | ❌ (use Client UI or GPO logon script) |
| Registry DENY ACL protection | ❌ | ✅ Fixlet 3 |
| Auto-remediation on tamper | ❌ | ✅ Baseline |
| Fleet compliance reporting | ❌ | ✅ Fixlet 5 Analysis Properties |
| Per-machine exception workflow | Manual | ✅ Fixlet 4 + audit trail |
| Works without network | ✅ | ❌ Needs BigFix agent |

> **Standalone note:** Registry keys are not ACL-protected — a local administrator can revert via regedit. Use the BigFix package for tamper-proof enterprise enforcement.

---

## User Notification

When a blocked USB storage device is plugged in while the Volume Watcher is active:

1. A Windows toast notification fires immediately (before ejection) so the user knows why
2. The drive is force-dismounted within ~1 second
3. No AutoPlay window appears (ShellHWDetection is stopped)

The notification message and company name are configurable in the GUI or via `set-notify-config`. Stored in `HKLM\SOFTWARE\USBGuard`.

**MTP/PTP devices (phones, cameras):** L7 blocks the WPD driver stack silently — no volume event fires, no toast is shown. The phone displays "Charging" or "USB connected". This is by design.

---

## Compliance Reporting (BigFix)

Fixlet 5 provides per-layer Analysis Properties for Web Reports and custom Dashboards:

| Property | Values |
|----------|--------|
| `USBGuard_L1_USBSTOR` | BLOCKED / OPEN / KEY_MISSING |
| `USBGuard_L2_WriteProtect` | ACTIVE / INACTIVE |
| `USBGuard_L3_DenyClasses` | ENFORCED / OFF |
| `USBGuard_L4_AutoPlay` | KILLED / LIVE |
| `USBGuard_L5_Watcher` | INSTALLED / MISSING |
| `USBGuard_L6_Thunderbolt` | BLOCKED / OPEN / NOT_PRESENT |
| `USBGuard_L7_WPD_MTP` | BLOCKED / OPEN / NOT_PRESENT |
| `USBGuard_Overall` | **COMPLIANT** / **NON-COMPLIANT** |

---

## Requirements

| Component | Requirement |
|-----------|-------------|
| OS | Windows 10 21H2+ or Windows 11 |
| PowerShell | 5.1+ (built into Windows, no install needed) |
| Privileges | Administrator (Standalone: UAC prompt; BigFix: SYSTEM) |
| HTA engine | MSHTML / IE component (standard on all Windows) |
| BigFix | HCL / IBM BigFix 9.5+, BESClient as LocalSystem |

---

## Testing

```powershell
# All tests (default = unit only)
.\Run-Tests.ps1

# Specific suites
.\Run-Tests.ps1 -Unit
.\Run-Tests.ps1 -Integration
.\Run-Tests.ps1 -All
.\Run-Tests.ps1 -Syntax          # Syntax check only, no Pester needed
.\Run-Tests.ps1 -All -Coverage   # With code coverage
```

CI runs automatically on push/PR via `.github/workflows/pester-tests.yml`:
- PowerShell syntax check
- Pester unit + integration tests
- PSScriptAnalyzer code quality
- Registry path validation
- Documentation presence check
