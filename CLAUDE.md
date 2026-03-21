# CLAUDE.md — USBGuard Project Context

## Purpose

USBGuard is an enterprise USB device management and lockdown solution for Windows. It enforces a **policy-wide block** on all removable storage and phone data connections across a fleet, with the ability to grant **per-machine temporary exceptions** through BigFix. Security is the primary objective; user experience (clear status, instant feedback, friendly toasts) is secondary.

---

## Architecture Overview

Two deployment variants share the same 7-layer protection model:

```
usb-block/
├── USBGuard-Standalone/       # IT-admin GUI + PS backend, no fleet mgmt
│   ├── USBGuard.ps1           # Core PS5.1 backend — all 7 layers + watcher
│   ├── USBGuard_Advanced.ps1  # List devices, export policy to JSON
│   ├── USBGuard.hta           # HTML Application GUI (IE/MSHTML engine)
│   └── Launch_USBGuard.bat    # UAC-elevating launcher
│
├── USBGuard-BigFix/           # Enterprise fleet deployment via HCL BigFix
│   ├── Fixlet1_ApplyPolicy.bes    # All 7 layers — idempotent, runs as SYSTEM
│   ├── Fixlet2_DeployWatcher.bes  # VolumeWatcher scheduled task (SYSTEM)
│   ├── Fixlet3_LockACLs.bes       # DENY ACEs on all protected registry keys
│   ├── Fixlet4_Unblock.bes        # Exception fixlet — strips ACEs then clears policy
│   └── Fixlet5_ComplianceDetection.bes  # Relevance-only audit + Analysis Properties
│
├── tests/
│   ├── unit/Registry.Tests.ps1          # Pester unit tests — registry helpers
│   ├── unit/StatusDetection.Tests.ps1   # Pester unit tests — status parsing
│   ├── unit/WpdMtp.Tests.ps1            # Pester unit tests — Layer 7 WPD/MTP/PTP
│   └── integration/BlockUnblock.Tests.ps1  # Pester integration tests
│
├── .github/workflows/pester-tests.yml  # CI: syntax, Pester, PSScriptAnalyzer, reg validation
├── Run-Tests.ps1              # Local test runner helper
├── CODE_VALIDATION.md         # Bug tracker / validation report
└── CLAUDE.md                  # This file
```

---

## The 7 Protection Layers

| Layer | Registry / Service | Blocks |
|-------|-------------------|--------|
| L1 | `USBSTOR\Start=4` | USB flash drives, external HDDs, USB-C drives |
| L2 | `StorageDevicePolicies\WriteProtect=1` | Any write to removable storage (forensic write-block) |
| L3 | `DenyDeviceClasses` GUIDs | Disk, CD-ROM, floppy, printer classes (prevent install/use) |
| L4 | `NoDriveTypeAutoRun=0xFF` + ShellHWDetection stopped | AutoPlay popup, AutoRun |
| L5 | WMI Volume Watcher (SYSTEM scheduled task) | Auto-ejects within ~1s of mount + user toast |
| L6 | `thunderbolt\Start=4` | Thunderbolt external drives |
| L7 | WPD stack disabled + MTP/PTP/Imaging GUIDs denied | Android (MTP), iPhone/iTunes (PTP), cameras, media players |

**Never blocked:** Keyboards, mice, USB audio, USB hubs, USB charging (VBUS is electrical).

---

## Key Design Decisions

### Policy = Block by Default, Exception by Request
- The BigFix Baseline enforces all 7 layers + ACL lock across all endpoints
- Exception: use Fixlet 4 targeted at specific computer(s) — BigFix audit trail records who/when
- After the exception window, re-apply Fixlets 1+2+3 to restore policy

### BigFix vs Standalone
| Concern | Standalone | BigFix |
|---------|-----------|--------|
| Registry tamper protection | ❌ (local admin can revert) | ✅ DENY ACEs (Fixlet 3) |
| Auto-remediation | ❌ | ✅ Baseline every 4h |
| Fleet compliance reporting | ❌ | ✅ Analysis Properties (Fixlet 5) |
| Exception workflow | Manual | ✅ Fixlet 4 + audit trail |
| User notification | ✅ Toast | ❌ (use BigFix Client UI or GPO script) |
| Works without network | ✅ | ❌ Needs BES agent |

### DENY ACE Strategy (Fixlet 3)
A DENY ACE overrides ALLOW even for local Administrators. Only SYSTEM (the BigFix service account) can modify the protected keys. Fixlet 4 strips DENY ACEs first before making any changes — this ordering is critical.

### WPD/MTP/PTP (L7) Silent Block
Phones blocked by L7 never enumerate as accessible devices — the WPD driver stack is disabled before Windows can present them. No volume event fires, so no toast is shown. The device shows "Charging" on its screen.

---

## Registry Paths (Quick Reference)

```
HKLM\SYSTEM\CurrentControlSet\Services\USBSTOR               Start: 4=blocked, 3=allowed
HKLM\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies   WriteProtect: 1=blocked, 0=allowed
HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions
  DenyDeviceClasses = 1 | DenyDeviceClassesRetroactive = 1
  DenyDeviceClasses\1..N = {GUID}
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer
  NoDriveTypeAutoRun = 255 (0xFF) | NoDriveAutoRun = 1
HKLM\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver    Start: 4=blocked
HKLM\SYSTEM\CurrentControlSet\Services\WUDFRd                 Start: 4=blocked
HKLM\SYSTEM\CurrentControlSet\Services\WpdUpFltr              Start: 4=blocked
HKLM\SYSTEM\CurrentControlSet\Services\thunderbolt            Start: 4=blocked
HKLM\SOFTWARE\USBGuard                                        Config + SavedStart\*
```

**Device Class GUIDs:**
```
{4D36E967-E325-11CE-BFC1-08002BE10318}  Disk drives
{4D36E965-E325-11CE-BFC1-08002BE10318}  CD-ROM
{4D36E969-E325-11CE-BFC1-08002BE10318}  Floppy/removable
{4D36E979-E325-11CE-BFC1-08002BE10318}  Printers
{EEC5AD98-8080-425F-922A-DABF3DE3F69A}  WPD (MTP/PTP — Android, media players)
{70AE35D8-BF10-11D0-AC45-0000C0B0BFCB}  WPD Print subclass
{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}  Still image / PTP cameras / iPhone
```

---

## PowerShell Backend (USBGuard.ps1)

- **Requires PS 5.1+** (Windows built-in). No external modules.
- `#Requires -RunAsAdministrator` — enforced at the top.
- **All actions** are dispatched via `-Action` parameter with `ValidateSet`.
- **`Get-Status`** returns an `[ordered]@{}` hashtable serialized as JSON — consumed by HTA.
- **`Save-OriginalStart`** idempotently saves WPD service Start values before disabling.
- **`Get-SavedStart`** retrieves saved values for clean restore during unblock.
- **`Add-GuidToDenyList` / `Remove-GuidFromDenyList`** handle the numbered-property pattern Windows uses for device class deny lists.
- **VolumeWatcher** is a SYSTEM scheduled task running an infinite loop with WMI event subscription. It auto-ejects volumes and dispatches toast via a temporary per-user scheduled task.
- **Logging**: `Write-Log` prefixes `[YYYY-MM-DD HH:mm:ss][LEVEL]` and optionally appends to `$OutputFile` (used by HTA to capture PS output).

### Action Map
```
status              → Get-Status → JSON
block               → L1-L7 all layers
unblock             → reverse all layers
block-storage       → L1+L2+L3(storage)+L4+L5+L6
unblock-storage     → reverse above
block-phones        → L7 (WPD/MTP/PTP)
unblock-phones      → reverse L7
block-printers      → L3 (printer GUID) + DenyInstall
unblock-printers    → reverse above
install-watcher     → L5 scheduled task only
remove-watcher      → remove L5 task
set-notify-config   → save company name + message to HKLM\SOFTWARE\USBGuard
```

---

## HTA GUI (USBGuard.hta)

- Runs in MSHTML (IE11 engine on Windows 10/11). HTA runs with elevated trust.
- **VBScript layer** (`RunPS`) shells out to `powershell.exe`, captures output via temp file.
- **JavaScript layer** parses JSON status from PS and updates the status cards.
- `refreshStatus()` calls `RunPS('-Action status')` → `parseStatus()` → `updateStatusUI()`.
- `runAction()` gates on `isAdmin`, shows loading overlay, calls PS, refreshes status.
- **Status card IDs**: `card-storage`, `card-writeprotect`, `card-autoplay`, `card-watcher`, `card-phones`, `card-printers`
- **Control panels**: Mass Storage, Phones/MTP/PTP, USB Printers (+ Master Control block/unblock all)
- **Notification panel**: Company name + message template (saved via `set-notify-config`)

---

## Known Bugs & Fixes Applied

| # | File | Bug | Fix |
|---|------|-----|-----|
| 1 | USBGuard.hta | `card-phones`/`val-phones` IDs missing from HTML — L7 status never displayed | Added phones status card to HTML status bar |
| 2 | USBGuard.hta | No Phones/MTP/PTP control panel in UI | Added phones panel to control grid |
| 3 | USBGuard.hta | `eval()` used to parse JSON (insecure) | Replaced with `JSON.parse()` |
| 4 | USBGuard.hta | MtpPtp status not logged in activity log | Added to status log line |
| 5 | USBGuard.hta | `block-phones`/`unblock-phones` missing from action labels map | Added entries |
| 6 | USBGuard.hta | VolumeWatcher `not_installed` mapped to `allowed` (misleading green) | Changed to `unknown` (amber) |

---

## Testing

### Run Locally (Windows, requires admin for registry tests)
```powershell
.\Run-Tests.ps1              # All tests
.\Run-Tests.ps1 -Unit        # Unit only
.\Run-Tests.ps1 -Integration # Integration only
.\Run-Tests.ps1 -Syntax      # PS syntax check only
```

### CI (GitHub Actions — `.github/workflows/pester-tests.yml`)
Jobs: `syntax-check` → `pester-tests` + `code-analysis` + `registry-validation` → `documentation-check` → `summary`

### Test Coverage Gaps
- No test for `Install-VolumeWatcher` / `Remove-VolumeWatcher` (requires SYSTEM context / task scheduler)
- HTA logic is not unit-tested (VBScript/JS — manual testing required)
- L6 Thunderbolt block/unblock not integration-tested (detection covered in StatusDetection.Tests.ps1)

---

## Deployment Order (BigFix)

```
Fixlet 1 (policy)  →  Fixlet 2 (watcher)  →  Fixlet 3 (lock ACLs)
```
All three should run before the Baseline is activated. Fixlet 3 must follow Fixlet 1 — it locks the values Fixlet 1 wrote.

**Exception workflow:**
1. Target Fixlet 4 at specific computer(s) — never "all endpoints"
2. BigFix strips DENY ACEs then clears all 7 layers
3. After exception window, re-target with Fixlets 1+2+3
4. BigFix audit trail records who granted the exception

---

## Security Notes

- **DENY ACEs** (BigFix only) prevent even local admins from reverting policy via regedit
- **Standalone** package relies on UAC + script trust — a local admin can revert; use BigFix for tamper-proof enforcement
- **WPD block (L7)** is silent — no user-visible feedback for phone blocking by design
- **VolumeWatcher** runs as SYSTEM; toast dispatched via temporary per-user scheduled task to avoid SYSTEM→desktop UI injection issues
- **No credentials** stored anywhere in scripts
- BigFix fixlets use `action uses wow64 redirection false` to ensure 64-bit registry access

---

## Requirements

- **Windows 10 21H2+ or Windows 11**
- **PowerShell 5.1+** (built-in, no install needed)
- **Administrator** (Standalone: UAC prompt on launch; BigFix: SYSTEM)
- **HTA**: MSHTML / IE component (standard on all Windows versions)
- **BigFix**: HCL BigFix / IBM BigFix 9.5+, BESClient as LocalSystem
