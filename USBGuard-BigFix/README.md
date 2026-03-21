# USBGuard — BigFix Deployment Package (v4)

## Overview

Fleet deployment package for HCL BigFix (formerly IBM BigFix). The BESClient service runs as SYSTEM, so all registry and service operations are privileged and cannot be interrupted by end users during execution.

This package extends the Standalone package with two critical additions:
- **Registry DENY ACLs (Fixlet 3)** — even local administrators cannot modify the protected keys; only SYSTEM (BigFix) can
- **Continuous compliance enforcement (Fixlet 5 + Baseline)** — BigFix auto-remediates any tampered machine within the next check cycle

---

## Files

| File | Purpose |
|------|---------|
| `Fixlet1_ApplyPolicy.bes` | Applies all 7 protection layers (registry + service + WPD/MTP/PTP) |
| `Fixlet2_DeployWatcher.bes` | Deploys VolumeWatcher.ps1 to ProgramData, registers SYSTEM Scheduled Task |
| `Fixlet3_LockACLs.bes` | Applies DENY ACEs to all protected registry keys + ProgramData folder |
| `Fixlet4_Unblock.bes` | Strips DENY ACEs, then clears all 7 layers (for targeted exceptions) |
| `Fixlet5_ComplianceDetection.bes` | Relevance-only audit fixlet + Analysis Property expressions for Web Reports |

---

## Protection Layers (v4)

| Layer | Mechanism | What it blocks | User undo? | Admin undo? | BigFix only? |
|-------|-----------|----------------|:---:|:---:|:---:|
| L1 | `USBSTOR Start=4` | Flash drives, external HDDs, USB-C drives | No | No* | Yes* |
| L2 | `WriteProtect=1` | Any write to removable storage | No | No* | Yes* |
| L3 | `DenyDeviceClasses` (GUIDs) | Disk, CD-ROM, floppy, printer classes | No | No* | Yes* |
| L4 | AutoPlay killed + ShellHWDetection stopped | AutoPlay popup window | No | No* | Yes* |
| L5 | VolumeWatcher Scheduled Task (SYSTEM) | Auto-ejects within ~1s of mount | No | View only | Yes |
| L6 | `thunderbolt Start=4` | Thunderbolt external drives | No | No* | Yes* |
| L7 | WPD services + MTP/PTP/Imaging GUIDs | Android MTP, iPhone/iTunes PTP, cameras | No | No* | Yes* |
| ACL | DENY ACEs on all registry keys | Prevents modification of any above key | No | No | Yes (Fixlet 4) |

*After Fixlet 3 applies DENY ACEs. Without Fixlet 3, a local admin could revert via regedit.

**DENY ACE behaviour:** A DENY ACE overrides ALLOW for all accounts including Administrators. Opening regedit shows the key exists but any modification returns "Access Denied". The only account exempt from a DENY ACE is the account that owns the ACL — which is SYSTEM.

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
| iPhone — iTunes file sync / backup | ✅ L7 |
| iPhone — Windows Photos import (PTP) | ✅ L7 |
| USB camera (PTP/MTP) | ✅ L7 |
| USB keyboard / mouse | ❌ Never blocked |
| USB headset / audio | ❌ Never blocked |
| USB charging (any device) | ❌ Never blocked |
| Network drives / cloud apps | ❌ Out of scope (network layer) |

---

## Deployment Order

```
Fixlet 1  →  Fixlet 2  →  Fixlet 3
 (policy)    (watcher)    (lock ACLs)
```

All three should be deployed together. Fixlet 3 must run after Fixlet 1 — it locks the values Fixlet 1 just wrote.

### Recommended Baseline Setup

1. Create a new **Baseline** in BigFix Console
2. Add **Fixlet 1** — relevance: any layer is missing or wrong value
3. Add **Fixlet 2** — relevance: watcher task not present
4. Add **Fixlet 3** — relevance: always (after policy is confirmed applied)
5. Set Baseline schedule: **every 4 hours**
6. Deploy **Fixlet 5** as an Analysis to populate Web Reports with per-layer compliance data

This means: if someone boots to WinPE, edits the registry offline, and reboots, BigFix re-applies all layers within 4 hours of the next agent check-in.

---

## Granting a Temporary Exception

To give a specific machine temporary USB access:

1. BigFix Console → Fixlets → `USBGuard - Remove USB Block Policy` **(Fixlet 4)**
2. **Target: specific computer(s) only** — never target all endpoints
3. Take Action — BigFix strips DENY ACEs first, then clears all 7 layers
4. After the exception window ends, re-target with Fixlets 1 + 2 + 3

BigFix's built-in audit trail records who initiated the exception action and when. Use this for compliance auditing.

---

## User Notification

Notifications are **not included** in the BigFix package. SYSTEM cannot show desktop UI directly, and the extra dispatch complexity was removed given that registry ACL protection makes the policy robust without it.

Two options if you want users informed:

**Option A — BigFix Client UI** (if the Client UI component is deployed):
```
client notify "USB Device Blocked" "USB storage and phone data access is disabled by IT Security policy. Contact the helpdesk at ext 1234 for temporary access."
```
This fires in the user's session via the BigFix tray agent.

**Option B — GPO logon script**: Deploy a logon script that checks `HKLM\SYSTEM\CurrentControlSet\Services\USBSTOR\Start` and shows a balloon notification if the value is 4. Runs in user context at login — no SYSTEM/UI conflict.

---

## Compliance Reporting (Fixlet 5)

Fixlet 5 contains no action — only relevance and Analysis Property expressions. Add these as individual Analysis Properties in BigFix Console to get per-layer status for every managed endpoint in Web Reports or a custom Dashboard.

Properties included:
- `USBGuard_L1_USBSTOR` — BLOCKED / OPEN / KEY_MISSING
- `USBGuard_L2_WriteProtect` — ACTIVE / INACTIVE
- `USBGuard_L3_DenyClasses` — ENFORCED / OFF
- `USBGuard_L4_AutoPlay` — KILLED / LIVE
- `USBGuard_L5_Watcher` — INSTALLED / MISSING
- `USBGuard_L6_Thunderbolt` — BLOCKED / OPEN / NOT_PRESENT
- `USBGuard_L7_WPD_MTP` — BLOCKED / OPEN / NOT_PRESENT
- `USBGuard_Overall` — **COMPLIANT** / **NON-COMPLIANT**

> **Note:** `USBGuard_L6_Thunderbolt` returns `NOT_PRESENT` on machines without Thunderbolt hardware — these machines are not penalised in `USBGuard_Overall`.

---

## Key Registry Paths (reference / troubleshooting)

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
  NoDriveTypeAutoRun = 255

HKLM\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver   Start = 4
HKLM\SYSTEM\CurrentControlSet\Services\WUDFRd                Start = 4
HKLM\SYSTEM\CurrentControlSet\Services\WpdUpFltr             Start = 4
HKLM\SYSTEM\CurrentControlSet\Services\thunderbolt           Start = 4

HKLM\SOFTWARE\USBGuard\SavedStart\*
  (Original WPD service Start values saved by Fixlet 1, restored by Fixlet 4)
```

---

## Requirements

- HCL BigFix / IBM BigFix 9.5+
- BESClient running as LocalSystem (default)
- Windows 10 (21H2+) or Windows 11 endpoints
- PowerShell 5.1+ on endpoints (built into Windows)

---

## Comparison: Standalone vs. BigFix

| Feature | Standalone | BigFix |
|---------|:----------:|:------:|
| GUI for IT admin use | ✅ HTA | ❌ Not needed |
| 7-layer USB protection | ✅ | ✅ |
| MTP/PTP blocking (L7) | ✅ | ✅ |
| User toast notification | ✅ | ❌ (use Client UI or GPO) |
| Registry DENY ACL protection | ❌ | ✅ Fixlet 3 |
| Auto-remediation on tamper | ❌ | ✅ Baseline |
| Fleet compliance reporting | ❌ | ✅ Analysis Properties |
| Temporary exception workflow | Manual | ✅ Fixlet 4 + audit trail |
| Works without network | ✅ | ❌ Needs BigFix agent |
