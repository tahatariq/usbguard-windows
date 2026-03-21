# USBGuard — Standalone Deployment Guide

Step-by-step guide to deploying USBGuard on a single Windows machine. No BigFix required. Designed for IT admins locking down individual workstations, shared lab computers, or kiosks.

---

## Before You Start

**What you need:**
- Windows 10 (21H2 or later) or Windows 11
- A local Administrator account (you will be prompted by UAC)
- The `USBGuard-Standalone` folder copied to the machine — for example, to `C:\Tools\USBGuard\`

**What USBGuard will NOT block:**
- USB keyboards and mice
- USB audio devices and headsets
- USB charging (phones charging over USB are fine — only data is blocked)
- Network drives, cloud sync (OneDrive, Dropbox), Bluetooth

---

## Step 1 — Identify Devices That Should Stay Allowed (Optional but Recommended)

If the machine already has USB storage devices plugged in that you want to keep working after the block (for example, a USB dongle used for software licensing), run the snapshot tool first to add them to the allowlist.

> Skip this step if there are no USB storage devices currently plugged in, or if you want everything blocked without exceptions.

1. Open PowerShell **as Administrator**
2. Navigate to the USBGuard folder:
   ```powershell
   cd C:\Tools\USBGuard
   ```
3. Preview what would be allowlisted (no changes made):
   ```powershell
   .\USBGuard_Snapshot.ps1 -Preview
   ```
   This lists all currently connected USB storage devices and their device IDs.

4. If the list looks correct, add them all to the allowlist:
   ```powershell
   .\USBGuard_Snapshot.ps1 -Apply
   ```

> **What is the allowlist?** Devices on the allowlist bypass the Volume Watcher (L5). They will still be subject to L1–L4 unless you specifically unblock storage for them. The allowlist is mainly used to prevent the auto-eject from firing on a specific trusted device.

---

## Step 2 — Launch the Admin GUI

1. Double-click `Launch_USBGuard.bat`
2. Click **Yes** on the UAC prompt
3. The USBGuard admin interface will open

The status bar at the top shows the current state of all 7 layers in real time:
- **Green / BLOCKED** — that layer is active and blocking
- **Red / ALLOWED** — that layer is off, devices can get through
- **Amber / UNKNOWN** — USBGuard cannot read the status (key missing or task not installed)

---

## Step 3 — Configure User Notifications

Before blocking, set the notification message users will see when they plug in a USB device.

1. Scroll down to the **Notification Settings** panel
2. Enter your company name (e.g. `Acme IT Security`)
3. Enter a message (e.g. `USB storage is blocked by IT policy. Call ext 1234 for temporary access.`)
4. Click **Save Notification Settings**

> You can use `{COMPANY}` as a placeholder in the message — it will be replaced by the company name you entered.

---

## Step 4 — Apply the Block

### Option A — Block Everything (Recommended)

In the GUI, click **Block All** in the Master Control section.

This applies all 7 layers simultaneously:
- USB flash drives and external hard drives → blocked (L1, L2, L3)
- Thunderbolt drives → blocked (L6)
- Phones (Android MTP, iPhone PTP) and cameras → blocked (L7)
- AutoPlay popup → killed (L4)
- Background volume watcher → installed and started (L5)

### Option B — Selective Block

Use the per-category buttons if you only want to block certain device types:

| Button | What it blocks |
|--------|----------------|
| Block Mass Storage | USB drives, external HDDs, USB-C drives (L1–L4, L5, L6) |
| Block Phones/MTP/PTP | Android, iPhone, cameras, media players (L7) |
| Block Printers | USB printers (L3 printer GUID) |

---

## Step 5 — Enable Tamper Detection

Tamper detection runs a background scheduled task every 5 minutes. If a local admin or script reverts any of the protected registry keys, the task automatically re-applies them and writes a log entry.

1. In the GUI, scroll to the **Master Control** section
2. Click **Enable** next to Tamper Detection
3. The `Tamper Detect` status card at the top should turn green

> **Note:** Tamper detection re-applies the three most critical values (USBSTOR Start, WriteProtect, WpdFilesystemDriver Start). For full ACL-level tamper protection that even blocks local admins in regedit, use the BigFix package instead.

---

## Step 6 — Verify the Status

After applying the block, the status bar should show all cards green (BLOCKED). Check each one:

| Card | Should show |
|------|-------------|
| USB Storage | BLOCKED |
| Write Protect | BLOCKED |
| AutoPlay | BLOCKED |
| Volume Watcher | RUNNING |
| Phones/MTP | BLOCKED |
| Printers | BLOCKED |
| Tamper Detect | RUNNING |

If any card is not green, click the corresponding **Block** button for that category.

---

## Step 7 — Generate a Compliance Report (Optional)

To produce a timestamped HTML report showing the status of all 7 layers:

```powershell
.\USBGuard_ComplianceReport.ps1
```

The report is saved to `C:\ProgramData\USBGuard\compliance_report.html`. Open it in any browser.

To see the summary in the console without saving an HTML file:

```powershell
.\USBGuard_ComplianceReport.ps1 -NoHtml
```

---

## Day-to-Day Operations

### Check current status

```powershell
.\USBGuard.ps1 -Action status
```

Returns a JSON summary of all layers. Useful for scripting or automated checks.

### View allowlisted devices

```powershell
.\USBGuard.ps1 -Action list-allowlist
```

### Add a specific device to the allowlist

First, find the device's PNP Device ID:

```powershell
.\USBGuard_Advanced.ps1 -Action list-devices
```

Then add it:

```powershell
.\USBGuard.ps1 -Action add-allowlist -DeviceId "USBSTOR\DISK&VEN_SanDisk&PROD_Ultra&REV_1.00\4C530001234567"
```

> Use the prefix up to (but not including) the trailing `&0` at the end of the device ID.

### Remove a device from the allowlist

```powershell
.\USBGuard.ps1 -Action remove-allowlist -DeviceId "USBSTOR\DISK&VEN_SanDisk&PROD_Ultra&REV_1.00\4C530001234567"
```

---

## Granting a Temporary Exception

To temporarily allow a user to use USB storage on this machine:

1. Open the GUI (`Launch_USBGuard.bat`)
2. Click **Allow All** in the Master Control section
3. The user can now use their USB device
4. When done, click **Block All** to re-apply all layers

> If tamper detection is enabled, it will still run every 5 minutes. You can disable it temporarily via the GUI (**Disable** button next to Tamper Detection) and re-enable it after re-blocking.

---

## Removing USBGuard Completely

To restore the machine to its pre-USBGuard state:

1. Open the GUI and click **Allow All**
2. Click **Disable** next to Tamper Detection
3. In the Master Control section, click **Remove Watcher**

Or via command line:

```powershell
.\USBGuard.ps1 -Action unblock
.\USBGuard.ps1 -Action remove-tamper-detection
.\USBGuard.ps1 -Action remove-watcher
```

---

## Command Reference

All commands must be run in PowerShell **as Administrator**.

```powershell
# ── Status & Reporting ────────────────────────────────────────────
.\USBGuard.ps1 -Action status                    # JSON status of all 7 layers
.\USBGuard_ComplianceReport.ps1                  # HTML compliance report
.\USBGuard_ComplianceReport.ps1 -NoHtml          # Console summary only
.\USBGuard_Advanced.ps1 -Action list-devices     # Show connected USB devices
.\USBGuard_Advanced.ps1 -Action export-policy    # Export current policy to JSON

# ── Block / Unblock ───────────────────────────────────────────────
.\USBGuard.ps1 -Action block                     # All 7 layers on
.\USBGuard.ps1 -Action unblock                   # All 7 layers off
.\USBGuard.ps1 -Action block-storage             # L1-L6 (drives only)
.\USBGuard.ps1 -Action unblock-storage
.\USBGuard.ps1 -Action block-phones              # L7 (Android/iPhone/cameras)
.\USBGuard.ps1 -Action unblock-phones
.\USBGuard.ps1 -Action block-printers            # L3 printer GUID
.\USBGuard.ps1 -Action unblock-printers

# ── Volume Watcher (L5) ───────────────────────────────────────────
.\USBGuard.ps1 -Action install-watcher           # Install background eject task
.\USBGuard.ps1 -Action remove-watcher            # Remove background eject task

# ── Tamper Detection ──────────────────────────────────────────────
.\USBGuard.ps1 -Action install-tamper-detection  # Re-check and re-apply every 5 min
.\USBGuard.ps1 -Action remove-tamper-detection

# ── Allowlist ─────────────────────────────────────────────────────
.\USBGuard.ps1 -Action list-allowlist
.\USBGuard.ps1 -Action add-allowlist    -DeviceId "USBSTOR\DISK&VEN_..."
.\USBGuard.ps1 -Action remove-allowlist -DeviceId "USBSTOR\DISK&VEN_..."

# ── Notification Message ──────────────────────────────────────────
.\USBGuard.ps1 -Action set-notify-config `
    -CompanyName    "Acme IT Security" `
    -NotifyMessage  "USB storage is blocked by {COMPANY} policy. Call ext 1234."

# ── Pre-block Device Snapshot ─────────────────────────────────────
.\USBGuard_Snapshot.ps1 -Preview   # Show what would be allowlisted
.\USBGuard_Snapshot.ps1 -Apply     # Add all connected USB storage to allowlist
```

---

## How User Notifications Work

When a blocked USB storage device is plugged in while the Volume Watcher is running:

1. Windows fires a volume creation event (within 250ms of mount)
2. USBGuard checks if the device is on the allowlist
3. If not allowlisted: a Windows toast notification is shown to the logged-in user
4. The drive is force-dismounted (within ~1 second of mount)
5. No AutoPlay window appears (ShellHWDetection is stopped by L4)

**Phones and cameras (L7):** These are blocked silently at the driver level. The WPD stack never loads, so the device never appears as accessible storage. No volume event fires, so no toast is shown. The phone just shows "Charging" or "USB connected" on its screen.

---

## Troubleshooting

**"Access Denied" when running USBGuard.ps1**
- The script requires Administrator. Run PowerShell as Administrator, or use `Launch_USBGuard.bat` which handles UAC elevation automatically.

**Status card shows UNKNOWN after blocking**
- Some layers depend on hardware that may not be present (e.g. Thunderbolt). UNKNOWN on Thunderbolt means the service key does not exist on this hardware — this is normal.
- For other layers, click the Block button for that category to re-apply.

**Volume Watcher shows UNKNOWN instead of RUNNING**
- The watcher task was not installed. Click **Install Watcher** in the GUI or run `.\USBGuard.ps1 -Action install-watcher`.

**A USB device is being ejected but it should be allowed**
- Add its Device ID to the allowlist. Run `.\USBGuard_Advanced.ps1 -Action list-devices` to find the Device ID, then `.\USBGuard.ps1 -Action add-allowlist -DeviceId "..."`.

**User sees no toast notification when plugging in a USB device**
- The Volume Watcher task must be installed and running. Check the Watcher status card in the GUI.
- The user must be logged in to a desktop session (toasts cannot be shown to non-interactive sessions).

**HTA GUI does not open**
- Try running `mshta.exe USBGuard.hta` from an elevated command prompt.
- Ensure MSHTML / Internet Explorer components are not disabled via Group Policy.

---

## Limitations vs. BigFix Package

- Registry keys are **not ACL-protected** — a determined local admin can revert settings via regedit (tamper detection will re-apply within 5 minutes, but there is a window)
- No fleet-wide compliance reporting
- No auditable exception workflow — exceptions are manual

For full tamper-proof, auditable enterprise enforcement, use the **USBGuard-BigFix** package.
