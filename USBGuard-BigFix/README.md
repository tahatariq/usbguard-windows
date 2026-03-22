# USBGuard — BigFix Fleet Deployment Guide

Step-by-step guide to deploying USBGuard across a managed fleet using HCL BigFix. This package provides registry-level tamper protection, continuous auto-remediation, auditable exception workflows, and per-layer compliance reporting in Web Reports.

---

## Before You Start

**What you need:**
- HCL BigFix / IBM BigFix 9.5 or later
- BigFix Console access with operator permissions to deploy fixlets
- BESClient running as LocalSystem on endpoints (the default installation)
- Endpoints running Windows 10 (21H2+) or Windows 11

**Key difference from Standalone:**
The BigFix package runs as SYSTEM and applies DENY ACEs to all protected registry keys. This means even a local Administrator cannot revert the policy via regedit — only SYSTEM (i.e. BigFix itself) can modify the protected keys. A local admin opening regedit will see the keys exist but receive "Access Denied" on any modification attempt.

---

## Fixlet Overview

| Fixlet | Purpose | Run order |
|--------|---------|-----------|
| `Fixlet1_ApplyPolicy.bes` | Applies all 10 protection layers | 1st |
| `Fixlet2_DeployWatcher.bes` | Deploys Volume Watcher scheduled task | 2nd |
| `Fixlet3_LockACLs.bes` | Applies DENY ACEs to all protected registry keys | 3rd (always last) |
| `Fixlet4_Unblock.bes` | Grants a temporary exception on a specific machine | On demand only |
| `Fixlet5_ComplianceDetection.bes` | Audit fixlet + Analysis Properties for Web Reports | Ongoing |

> **Critical ordering:** Fixlet 3 must always run after Fixlet 1. Fixlet 3 locks the values that Fixlet 1 wrote. Running Fixlet 3 before Fixlet 1 will lock keys in an unblocked state.

---

## Step 1 — Import the Fixlets

1. Open **BigFix Console**
2. Go to **File → Import** (or drag and drop)
3. Import each `.bes` file in order:
   - `Fixlet1_ApplyPolicy.bes`
   - `Fixlet2_DeployWatcher.bes`
   - `Fixlet3_LockACLs.bes`
   - `Fixlet4_Unblock.bes`
   - `Fixlet5_ComplianceDetection.bes`
4. They will appear under **Fixlets** in the console tree

---

## Step 2 — Initial Deployment to Endpoints

Deploy the fixlets **individually in order** to a test group first, then to all endpoints.

### 2a — Apply the Protection Policy (Fixlet 1)

1. In BigFix Console, locate `USBGuard - Apply USB Block Policy`
2. Right-click → **Take Action**
3. Target: your test group or "All Windows Computers" for full deployment
4. Click **OK**
5. Wait for the action to complete on all targeted machines (check the **Action** tab for status)

Fixlet 1 does the following on each endpoint:
- Saves the original service Start values (used later for clean unblock)
- Sets USBSTOR `Start=4` (L1)
- Sets `WriteProtect=1` (L2)
- Adds device class deny GUIDs for disk, CD-ROM, floppy, printer, WPD, PTP, Bluetooth OBEX (L3)
- Sets `NoDriveTypeAutoRun=255` and stops ShellHWDetection (L4)
- Disables Thunderbolt service (L6)
- Disables WPD driver stack services (L7)
- Disables SD card reader service `sdbus` (L8)
- Disables Bluetooth file transfer services `BthOBEX` and `RFCOMM` (L9)
- Disables FireWire controller service `1394ohci` (L10)

### 2b — Deploy the Volume Watcher (Fixlet 2)

1. Locate `USBGuard - Deploy Volume Watcher`
2. Right-click → **Take Action**
3. Same targeting as Fixlet 1
4. This installs a SYSTEM scheduled task that auto-ejects any USB volume within ~1 second of mount

> **Note:** The Volume Watcher runs as SYSTEM. It dispatches user toast notifications via a temporary per-user scheduled task to avoid SYSTEM→desktop UI injection issues.

### 2c — Lock the Registry (Fixlet 3)

1. Locate `USBGuard - Lock Registry ACLs`
2. Right-click → **Take Action**
3. Same targeting as Fixlets 1 and 2
4. Wait for completion — after this, no local admin can revert the policy via regedit

> Only deploy Fixlet 3 after confirming Fixlet 1 has succeeded on the target machines. Check the Action status tab before proceeding.

---

## Step 3 — Set Up a Baseline for Auto-Remediation

A Baseline re-applies all three fixlets on a schedule. If a machine is offline when you first deploy, or if someone manages to revert the policy (e.g. by booting to WinPE and editing the registry offline), the Baseline will re-apply everything at the next check-in.

1. In BigFix Console, go to **Baselines** → right-click → **New Baseline**
2. Name it: `USBGuard - USB Block Policy`
3. Add the following components in order:
   - `USBGuard - Apply USB Block Policy` (Fixlet 1)
   - `USBGuard - Deploy Volume Watcher` (Fixlet 2)
   - `USBGuard - Lock Registry ACLs` (Fixlet 3)
4. Set the relevance for each component to re-run when the policy is not in the expected state (the fixlets include relevance expressions for this)
5. Set the Baseline schedule: **Every 4 hours** (recommended) or at minimum every 8 hours
6. Deploy the Baseline to all endpoints

After this, any machine that drifts out of compliance will be automatically remediated within 4 hours of its next BigFix agent check-in.

---

## Step 4 — Enable Compliance Reporting (Fixlet 5)

Fixlet 5 contains no action — it is an audit-only fixlet that provides Analysis Properties for Web Reports.

1. Locate `USBGuard - Compliance Detection`
2. Right-click → **Activate as Analysis**
3. In the Analysis dialog, confirm the properties:
   - `USBGuard_L1_USBSTOR` — BLOCKED / OPEN / KEY_MISSING
   - `USBGuard_L2_WriteProtect` — ACTIVE / INACTIVE
   - `USBGuard_L3_DenyClasses` — ENFORCED / OFF
   - `USBGuard_L4_AutoPlay` — KILLED / LIVE
   - `USBGuard_L5_Watcher` — INSTALLED / MISSING
   - `USBGuard_L6_Thunderbolt` — BLOCKED / OPEN / NOT_PRESENT
   - `USBGuard_L7_WPD_MTP` — BLOCKED / OPEN / NOT_PRESENT
   - `USBGuard_L8_SdCard` — BLOCKED / OPEN / NOT_PRESENT
   - `USBGuard_L9_Bluetooth` — BLOCKED / OPEN / NOT_PRESENT
   - `USBGuard_L10_FireWire` — BLOCKED / OPEN / NOT_PRESENT
   - `USBGuard_Overall` — **COMPLIANT** / **NON-COMPLIANT**
4. Click **OK** — BigFix will now collect these values from every managed endpoint

To view results:
- **BigFix Console:** Select any computer → **Properties** tab → scroll to USBGuard properties
- **Web Reports:** Create a report using the `USBGuard_Overall` property to see a fleet-wide compliance dashboard

> `USBGuard_L6_Thunderbolt`, `USBGuard_L8_SdCard`, `USBGuard_L9_Bluetooth`, and `USBGuard_L10_FireWire` return `NOT_PRESENT` on machines without the corresponding hardware. These machines are not counted as non-compliant in `USBGuard_Overall`.

---

## Granting a Temporary Exception

To allow a specific user on a specific machine to use USB storage temporarily:

### Step-by-step

1. BigFix Console → locate `USBGuard - Remove USB Block Policy` **(Fixlet 4)**
2. Right-click → **Take Action**
3. **Target: specific computer(s) only** — double-check you are not targeting all endpoints
4. Click **OK**

Fixlet 4 does the following:
- Strips all DENY ACEs from the protected registry keys (this must happen first — without this step, even SYSTEM cannot modify the keys)
- Restores USBSTOR, WriteProtect, AutoPlay, Thunderbolt, WPD, sdbus, BthOBEX, RFCOMM, and 1394ohci services to their original values
- Removes the Volume Watcher scheduled task
- Creates an **automatic re-apply task** (`USBGuard_ExceptionExpiry`) that fires **8 hours later**, re-applies all 10 layers and then deletes itself

### After the exception window

If you want to re-apply policy manually before the 8-hour timer:
1. Re-run **Fixlet 1** targeted at that machine
2. Re-run **Fixlet 2** targeted at that machine
3. Re-run **Fixlet 3** targeted at that machine

The Baseline will also catch it at the next 4-hour cycle.

### Sending a notification to your team (optional)

Before or after running Fixlet 4, you can notify your security team via a webhook using `Send-ExceptionNotification.ps1` from the Standalone package:

```powershell
# Teams notification
.\Send-ExceptionNotification.ps1 `
    -WebhookUrl   "https://your-org.webhook.office.com/..." `
    -MachineName  "LAPTOP-JSMITH" `
    -GrantedBy    "IT Helpdesk" `
    -ExpiryHours  8 `
    -Platform     Teams

# Slack notification
.\Send-ExceptionNotification.ps1 `
    -WebhookUrl   "https://hooks.slack.com/services/..." `
    -MachineName  "LAPTOP-JSMITH" `
    -GrantedBy    "IT Helpdesk" `
    -ExpiryHours  8 `
    -Platform     Slack
```

BigFix's built-in audit trail (under the Action history) records who initiated Fixlet 4 and when, providing a permanent compliance record of every exception granted.

---

## Verifying Deployment

After the Baseline has run across your fleet, verify the rollout:

1. In BigFix Console, select a target computer
2. Go to the **Properties** tab
3. Look for the `USBGuard_Overall` Analysis Property — it should show `COMPLIANT`
4. Check individual layer properties if needed

To verify on a specific endpoint directly (requires admin PowerShell on that machine):

```powershell
# From the USBGuard-Standalone folder on the endpoint
.\USBGuard_ComplianceReport.ps1 -NoHtml
```

---

## Understanding DENY ACEs (Tamper Protection)

After Fixlet 3 runs, the protected registry keys have a DENY ACE applied for the `Administrators` group. This means:

- A local admin opening `regedit.exe` can **view** the keys but **cannot modify** them
- Scripts running as Administrator receive "Access Denied" on any write attempt
- Only SYSTEM (the BigFix BESClient service account) can modify the keys
- This protection survives reboots and local admin group changes

**The only way to remove it is:**
1. Run Fixlet 4 as SYSTEM via BigFix (which strips the DENY ACEs before making any changes)
2. Boot to WinPE/external OS and edit the registry offline (which BigFix will re-apply at next check-in)

---

## User Notifications

The BigFix package does not include user notifications by default (SYSTEM cannot show desktop UI directly). Two options:

**Option A — BigFix Client UI** (if the BigFix Client UI component is deployed on endpoints):
```
client notify "USB Device Blocked" "USB storage and phone data access is disabled by IT Security policy. Contact the helpdesk at ext 1234 for temporary access."
```

**Option B — GPO logon script:**
Deploy a Group Policy logon script that runs in the user context, checks `HKLM\SYSTEM\CurrentControlSet\Services\USBSTOR\Start`, and shows a balloon or toast notification if the value is 4. This runs as the logged-in user so there is no SYSTEM→desktop session conflict.

---

## Key Registry Paths (Reference / Troubleshooting)

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
  DenyDeviceClasses\7 = {E0CBF06C-CD8B-4647-BB8A-263B43F0F974}  (Bluetooth OBEX — L9)

HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer
  NoDriveTypeAutoRun = 255 (0xFF)

HKLM\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver  Start = 4
HKLM\SYSTEM\CurrentControlSet\Services\WUDFRd               Start = 4
HKLM\SYSTEM\CurrentControlSet\Services\WpdUpFltr            Start = 4
HKLM\SYSTEM\CurrentControlSet\Services\thunderbolt          Start = 4
HKLM\SYSTEM\CurrentControlSet\Services\sdbus                Start = 4  (L8 — SD card reader)
HKLM\SYSTEM\CurrentControlSet\Services\BthOBEX              Start = 4  (L9 — Bluetooth OBEX)
HKLM\SYSTEM\CurrentControlSet\Services\RFCOMM               Start = 4  (L9 — Bluetooth RFCOMM)
HKLM\SYSTEM\CurrentControlSet\Services\1394ohci             Start = 4  (L10 — FireWire)

HKLM\SOFTWARE\USBGuard\SavedStart\*
  (Original service Start values saved by Fixlet 1 — used by Fixlet 4 to restore cleanly)
```

---

## Troubleshooting

**Fixlet 1 shows "Not Relevant" on some machines**
- The machine may already be fully compliant (policy already applied). Check the `USBGuard_Overall` Analysis Property.
- If the machine has never had USBGuard applied, check that the BESClient service is running as LocalSystem.

**Fixlet 3 fails with "Access Denied"**
- Fixlet 3 must run as SYSTEM via BigFix. Ensure `action uses wow64 redirection false` is set in the fixlet (it is, by default). Do not attempt to run it manually from a non-SYSTEM context.

**Fixlet 4 fails — cannot strip DENY ACEs**
- Only SYSTEM can remove DENY ACEs applied by Fixlet 3. Fixlet 4 runs as SYSTEM via BigFix and handles this automatically. If Fixlet 4 fails, check that BESClient is running as LocalSystem (not a standard service account).

**Machine shows NON-COMPLIANT in Web Reports after Baseline ran**
- Check the individual layer properties to identify which layer is missing.
- Check the BigFix Action history for errors on that machine.
- If the machine was offline during Baseline execution, it will be remediated at the next check-in.

**Thunderbolt / SD card / Bluetooth / FireWire shows NOT_PRESENT on a machine**
- This is expected for machines without the corresponding hardware. The service key does not exist on those machines. `USBGuard_Overall` does not penalise machines for hardware-absent layers.

**After Fixlet 4, the machine still shows blocked**
- Fixlet 4 clears the registry values and removes the watcher task. A reboot may be required for the WPD driver stack (L7) to reload. The `USBGuard_ExceptionExpiry` scheduled task will re-apply policy after 8 hours regardless.
