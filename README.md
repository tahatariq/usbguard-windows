# USBGuard — Enterprise USB Device Management

Blocks USB storage, phones, and cameras on Windows machines. Two deployment options share the same 7-layer protection model — pick the one that fits your environment:

| | Standalone | BigFix |
|---|---|---|
| **Best for** | Single machines, labs, kiosks, no management server | Corporate fleets managed by HCL BigFix |
| **Tamper protection** | Relies on UAC + tamper detection task | DENY ACEs — even local admins cannot revert |
| **Auto-remediation** | Tamper detection re-applies within 5 min | BigFix Baseline re-applies within 4 hours |
| **Exception workflow** | Manual (unblock + re-block) | Fixlet 4 targeted at specific machines, full audit trail |
| **User notification** | ✅ Windows toast popup | Requires BigFix Client UI or GPO logon script |
| **Fleet reporting** | ❌ | ✅ Analysis Properties in Web Reports |
| **Requires network** | No | Yes (BigFix agent must check in) |

**Not sure which to use?** If you manage machines through HCL BigFix, use the BigFix package. For everything else, use Standalone.

---

## What Gets Blocked

| Device | Blocked | Layer |
|--------|:-------:|-------|
| USB flash drive (2.0 / 3.x) | ✅ | L1 + L3 |
| USB external hard drive | ✅ | L1 + L3 |
| USB-C external storage | ✅ | L1 + L3 |
| Thunderbolt drive | ✅ | L6 |
| USB CD/DVD drive | ✅ | L3 |
| USB printer | ✅ | L3 |
| Android phone — File Transfer (MTP) | ✅ | L7 |
| iPhone — iTunes sync / backup | ✅ | L7 |
| iPhone / Android — Windows Photos import | ✅ | L7 |
| USB camera or media player (PTP/MTP) | ✅ | L7 |
| **USB keyboard / mouse** | ❌ Never blocked | — |
| **USB headset / audio** | ❌ Never blocked | — |
| **USB charging (any device)** | ❌ Never blocked | — |
| Network drives, cloud sync, Bluetooth | ❌ Out of scope | — |

---

## The 7 Protection Layers

| Layer | What It Does |
|-------|-------------|
| L1 | Disables the USB storage class driver (`USBSTOR`) |
| L2 | Write-protects any removable storage that manages to mount (forensic-grade) |
| L3 | Prevents device class installation via Group Policy GUIDs |
| L4 | Kills AutoPlay popup and AutoRun |
| L5 | Background watcher: auto-ejects any USB volume within ~1 second of mount and shows a toast notification to the user |
| L6 | Disables the Thunderbolt driver |
| L7 | Disables the Windows Portable Devices (WPD) driver stack — silently blocks Android, iPhone, cameras, media players at the driver level |

---

## Project Structure

```
usbguard-windows/
├── USBGuard-Standalone/
│   ├── Launch_USBGuard.bat              ← Start here for GUI
│   ├── USBGuard.hta                     ← Graphical admin interface
│   ├── USBGuard.ps1                     ← PowerShell backend (all 7 layers)
│   ├── USBGuard_Advanced.ps1            ← List connected USB devices, export policy
│   ├── USBGuard_Snapshot.ps1            ← Pre-block device snapshot + allowlist setup
│   ├── USBGuard_ComplianceReport.ps1    ← HTML compliance report
│   └── Send-ExceptionNotification.ps1   ← Teams/Slack webhook on exception grant
│
├── USBGuard-BigFix/
│   ├── Fixlet1_ApplyPolicy.bes          ← All 7 layers (run first)
│   ├── Fixlet2_DeployWatcher.bes        ← Volume Watcher scheduled task
│   ├── Fixlet3_LockACLs.bes             ← DENY ACEs (run last, locks everything)
│   ├── Fixlet4_Unblock.bes              ← Temporary exception (targeted use only)
│   └── Fixlet5_ComplianceDetection.bes  ← Per-layer audit + Analysis Properties
│
├── USBGuard-API/                        ← Python/FastAPI REST API for exception management
│   ├── app/                             ← FastAPI app (routes, BigFix client, auth, models)
│   ├── tests/                           ← 59 pytest tests (BigFix fully mocked)
│   ├── appsettings.example.json         ← Copy to appsettings.json and fill in secrets
│   ├── web.config                       ← IIS HttpPlatformHandler config
│   └── README.md                        ← API deployment + reference guide
│
├── tests/
│   ├── unit/                            ← Pester unit tests (112 tests)
│   ├── integration/                     ← Block/unblock roundtrip tests (10 tests)
│   └── simulation/                      ← Manual end-to-end validation scripts
│
├── Run-Tests.ps1                        ← Local PowerShell test runner
└── .github/workflows/
    ├── pester-tests.yml                 ← CI: Win2022 + Win2025 matrix
    └── api-tests.yml                    ← CI: Python/pytest on ubuntu-latest
```

---

## Choosing the Right Package

### Use Standalone if:
- You're locking down a single machine, a shared workstation, or a lab computer
- You don't have HCL BigFix
- You want a graphical admin interface
- You want user toast notifications when a USB device is rejected

### Use BigFix if:
- You manage a fleet of Windows machines through HCL BigFix
- You need registry-level tamper protection (DENY ACEs that block even local admins)
- You need compliance reporting across all endpoints
- You need an auditable exception workflow

---

## Quick-Start Links

- **Standalone deployment:** [USBGuard-Standalone/README.md](USBGuard-Standalone/README.md)
- **BigFix fleet deployment:** [USBGuard-BigFix/README.md](USBGuard-BigFix/README.md)

---

## Requirements

| Component | Requirement |
|-----------|-------------|
| OS | Windows 10 (21H2 or later) or Windows 11 |
| PowerShell | 5.1+ — built into Windows, nothing to install |
| Privileges | Administrator (Standalone: UAC prompt on launch; BigFix: runs as SYSTEM) |
| HTA engine | MSHTML / IE component — present on all Windows versions by default |
| BigFix | HCL / IBM BigFix 9.5 or later, BESClient running as LocalSystem |

---

## Testing

```powershell
# Run all tests from the repo root (requires admin for registry tests)
.\Run-Tests.ps1

# Unit tests only (no admin needed for most)
.\Run-Tests.ps1 -Unit

# Integration tests (requires admin)
.\Run-Tests.ps1 -Integration
```

CI runs automatically on every push via GitHub Actions — syntax check, Pester tests, PSScriptAnalyzer, and registry path validation across Windows Server 2022 and 2025.
