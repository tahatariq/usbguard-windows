# Intune OMA-URI Configuration for USBGuard

This document provides the OMA-URI paths needed to create **Custom Configuration Profiles** in Microsoft Intune that enforce the same registry settings as USBGuard's 7-layer protection model.

> **When to use this:** If you want Intune to manage registry values directly (via CSP) rather than deploying the USBGuard PowerShell scripts as a Win32 app. Both approaches are valid; OMA-URI gives Intune-native compliance reporting, while the Win32 app approach adds the Volume Watcher (L5) and tamper detection.

---

## Layer 1 — USBSTOR Service (USB Mass Storage)

Disables the USB mass storage driver so flash drives, external HDDs, and USB-C drives are not recognized.

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L1 Disable USBSTOR |
| **OMA-URI** | `./Device/Vendor/MSFT/Policy/Config/Storage/RemovableDiskDenyReadAccess` |
| **Data type** | Integer |
| **Value** | `1` |

For direct registry control (via the Registry CSP):

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L1 USBSTOR Start |
| **OMA-URI** | `./Device/Vendor/MSFT/Policy/Config/ADMX_MicrosoftEdge/RegistryPolicyControl` |
| **Data type** | String |

Alternatively, use the generic Registry CSP path:

```
./Vendor/MSFT/Registry/HKLM/SYSTEM/CurrentControlSet/Services/USBSTOR/Start
```

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L1 USBSTOR Start (Registry CSP) |
| **OMA-URI** | `./Vendor/MSFT/Registry/HKLM/SYSTEM/CurrentControlSet/Services/USBSTOR/Start` |
| **Data type** | Integer |
| **Value** | `4` (disabled) / `3` (enabled) |

---

## Layer 2 — StorageDevicePolicies (Write Protection)

Enforces read-only access on any removable storage that somehow mounts.

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L2 Write Protect |
| **OMA-URI** | `./Vendor/MSFT/Registry/HKLM/SYSTEM/CurrentControlSet/Control/StorageDevicePolicies/WriteProtect` |
| **Data type** | Integer |
| **Value** | `1` (write-blocked) / `0` (writable) |

---

## Layer 3 — DenyDeviceClasses (Device Installation Restriction)

Prevents Windows from installing drivers for specified device classes. This is the most Intune-native layer and uses the built-in DeviceInstallation CSP.

### 3a. Enable Device Class Deny List

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L3 Enable DenyDeviceClasses |
| **OMA-URI** | `./Device/Vendor/MSFT/Policy/Config/DeviceInstallation/PreventInstallationOfMatchingDeviceSetupClasses` |
| **Data type** | String (XML) |
| **Value** | See XML below |

```xml
<enabled/>
<data id="DeviceInstall_Classes_Deny_List" value="1&#xF000;{4D36E967-E325-11CE-BFC1-08002BE10318}&#xF000;2&#xF000;{4D36E965-E325-11CE-BFC1-08002BE10318}&#xF000;3&#xF000;{4D36E969-E325-11CE-BFC1-08002BE10318}&#xF000;4&#xF000;{4D36E979-E325-11CE-BFC1-08002BE10318}&#xF000;5&#xF000;{EEC5AD98-8080-425F-922A-DABF3DE3F69A}&#xF000;6&#xF000;{70AE35D8-BF10-11D0-AC45-0000C0B0BFCB}&#xF000;7&#xF000;{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}"/>
<data id="DeviceInstall_Classes_Deny_Retroactive" value="true"/>
```

**Device Class GUIDs included:**

| # | GUID | Class |
|---|------|-------|
| 1 | `{4D36E967-E325-11CE-BFC1-08002BE10318}` | Disk drives |
| 2 | `{4D36E965-E325-11CE-BFC1-08002BE10318}` | CD-ROM |
| 3 | `{4D36E969-E325-11CE-BFC1-08002BE10318}` | Floppy / removable |
| 4 | `{4D36E979-E325-11CE-BFC1-08002BE10318}` | Printers |
| 5 | `{EEC5AD98-8080-425F-922A-DABF3DE3F69A}` | WPD (MTP/PTP -- Android, media players) |
| 6 | `{70AE35D8-BF10-11D0-AC45-0000C0B0BFCB}` | WPD Print subclass |
| 7 | `{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}` | Still image / PTP cameras / iPhone |

### 3b. Apply Retroactively

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L3 DenyDeviceClasses Retroactive |
| **OMA-URI** | `./Device/Vendor/MSFT/Policy/Config/DeviceInstallation/PreventInstallationOfMatchingDeviceSetupClasses` |
| **Data type** | String (XML) |
| **Value** | Include `DeviceInstall_Classes_Deny_Retroactive` = `true` in the XML above |

> **Note:** The retroactive flag and the deny list are set in the same OMA-URI policy (see the XML above).

---

## Layer 4 — AutoPlay / AutoRun

Disables AutoPlay on all drive types to prevent automatic execution when media is inserted.

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L4 Disable AutoPlay (all drives) |
| **OMA-URI** | `./Device/Vendor/MSFT/Policy/Config/Autoplay/DisallowAutoplayForNonVolumeDevices` |
| **Data type** | Integer |
| **Value** | `1` |

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L4 Set Default AutoRun Behavior |
| **OMA-URI** | `./Device/Vendor/MSFT/Policy/Config/Autoplay/SetDefaultAutoRunBehavior` |
| **Data type** | Integer |
| **Value** | `1` (do not execute any autorun commands) |

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L4 Turn Off AutoPlay |
| **OMA-URI** | `./Device/Vendor/MSFT/Policy/Config/Autoplay/TurnOffAutoPlay` |
| **Data type** | Integer |
| **Value** | `1` (all drives) |

For the NoDriveTypeAutoRun registry value directly:

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L4 NoDriveTypeAutoRun (Registry) |
| **OMA-URI** | `./Vendor/MSFT/Registry/HKLM/SOFTWARE/Microsoft/Windows/CurrentVersion/Policies/Explorer/NoDriveTypeAutoRun` |
| **Data type** | Integer |
| **Value** | `255` (0xFF -- all drive types) |

---

## Layer 5 — Volume Watcher

> **Note:** The Volume Watcher is a PowerShell-based scheduled task and cannot be deployed via OMA-URI alone. Use the Win32 app deployment (Install-USBGuard.ps1) or a PowerShell script deployment in Intune to install it.

---

## Layer 6 — Thunderbolt

Disables the Thunderbolt driver to prevent Thunderbolt-attached external storage.

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L6 Disable Thunderbolt |
| **OMA-URI** | `./Vendor/MSFT/Registry/HKLM/SYSTEM/CurrentControlSet/Services/thunderbolt/Start` |
| **Data type** | Integer |
| **Value** | `4` (disabled) / `3` (enabled) |

---

## Layer 7 — WPD Stack (MTP/PTP)

Disables the Windows Portable Devices driver stack to block phone file transfer (Android MTP, iPhone PTP/iTunes), cameras, and media players.

### 7a. WpdFilesystemDriver

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L7 Disable WpdFilesystemDriver |
| **OMA-URI** | `./Vendor/MSFT/Registry/HKLM/SYSTEM/CurrentControlSet/Services/WpdFilesystemDriver/Start` |
| **Data type** | Integer |
| **Value** | `4` (disabled) |

### 7b. WUDFRd (User-mode Driver Framework)

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L7 Disable WUDFRd |
| **OMA-URI** | `./Vendor/MSFT/Registry/HKLM/SYSTEM/CurrentControlSet/Services/WUDFRd/Start` |
| **Data type** | Integer |
| **Value** | `4` (disabled) |

### 7c. WpdUpFltr (WPD Upper Filter)

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - L7 Disable WpdUpFltr |
| **OMA-URI** | `./Vendor/MSFT/Registry/HKLM/SYSTEM/CurrentControlSet/Services/WpdUpFltr/Start` |
| **Data type** | Integer |
| **Value** | `4` (disabled) |

---

## USBGuard Configuration Registry Keys

These are custom keys under `HKLM\SOFTWARE\USBGuard` used by the USBGuard scripts for configuration and state tracking.

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - CompanyName |
| **OMA-URI** | `./Vendor/MSFT/Registry/HKLM/SOFTWARE/USBGuard/CompanyName` |
| **Data type** | String |
| **Value** | Your company name (shown in user notifications) |

| Setting | Value |
|---------|-------|
| **Name** | USBGuard - NotifyMessage |
| **OMA-URI** | `./Vendor/MSFT/Registry/HKLM/SOFTWARE/USBGuard/NotifyMessage` |
| **Data type** | String |
| **Value** | Custom notification message for end users |

---

## Deployment Checklist

1. **Create a Custom Configuration Profile** in Intune (Devices > Configuration Profiles > Create > Windows 10 and later > Templates > Custom).
2. **Add each OMA-URI row** from the tables above as a separate setting in the profile.
3. **Assign** the profile to the desired device groups.
4. **For Layer 5 (Volume Watcher):** Deploy Install-USBGuard.ps1 as an Intune Win32 app or use Devices > Scripts to push the watcher installation separately.
5. **Monitor compliance** via Intune device configuration status and the Detect-USBGuard.ps1 detection script.

---

## Compliance Monitoring

To verify endpoints are enforcing all layers, use a **Compliance Policy** with a custom script:

- **Script:** Detect-USBGuard.ps1
- **Detection rule:** Exit code 0 = compliant
- **Schedule:** Every 8 hours (or as desired)

This catches machines where a layer was reverted outside of Intune (e.g., local admin tampering).
