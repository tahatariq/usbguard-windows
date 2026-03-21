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
│   ├── USBGuard_Advanced.ps1       # List devices, export policy to JSON
│   ├── USBGuard_Snapshot.ps1       # Pre-block device snapshot + allowlist pre-population
│   ├── USBGuard_ComplianceReport.ps1  # 7-layer HTML compliance report
│   ├── Send-ExceptionNotification.ps1 # Teams/Slack webhook on exception grant/expiry
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
│   ├── unit/AuditNotify.Tests.ps1       # Pester unit tests — audit log + input validation
│   ├── unit/ComplianceReport.Tests.ps1  # Pester unit tests — layer status map + HTML report
│   ├── unit/NotifyWebhook.Tests.ps1     # Pester unit tests — Teams + Slack payload builders
│   ├── simulation/TamperDetection.Simulation.ps1  # End-to-end tamper detection proof
│   ├── simulation/BypassAttempt.Simulation.ps1    # Red-team bypass vector checklist
│   └── integration/BlockUnblock.Tests.ps1  # Pester integration tests
│
├── USBGuard-API/              # Python/FastAPI REST API — BigFix exception management over HTTP
│   ├── app/
│   │   ├── main.py            # FastAPI app, routes, lifespan
│   │   ├── bigfix.py          # BigFix REST API client (action deploy, status query, scheduling)
│   │   ├── date_parser.py     # Flexible date parsing (13 formats, past-date correction)
│   │   ├── models.py          # Pydantic v2 request/response models
│   │   ├── auth.py            # API key middleware (X-API-Key header)
│   │   └── config.py          # Settings loaded from appsettings.json
│   ├── tests/
│   │   ├── test_api.py        # 17 API integration tests (TestClient + mocked BigFix)
│   │   ├── test_date_parser.py # 18 date parsing tests
│   │   ├── test_models.py     # 12 Pydantic validation tests
│   │   └── test_bigfix.py     # 14 scheduling offset + encoding tests
│   ├── appsettings.example.json   # Template — copy to appsettings.json and fill in secrets
│   ├── generate_api_key.py    # Generates a secure random API key, prints rotation instructions
│   ├── requirements.txt
│   ├── web.config             # IIS HttpPlatformHandler config (proxies to uvicorn)
│   └── README.md              # Deployment guide, API reference, scheduling/expiry explanation
│
├── .github/workflows/pester-tests.yml  # CI: matrix (Win2022/Win2025), syntax, Pester, PSScriptAnalyzer
├── .github/workflows/api-tests.yml     # CI: Python 3.12, pytest, runs on path changes to USBGuard-API/
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
- **VolumeWatcher** is a SYSTEM scheduled task running an infinite loop with WMI event subscription (`WITHIN 0.25` — 250ms polling). It checks each new volume against the allowlist; if not allowlisted, auto-ejects and dispatches toast via a temporary per-user scheduled task.
- **Allowlist**: `Add-AllowlistEntry` / `Remove-AllowlistEntry` / `Get-AllowlistEntries` manage trusted device PNP IDs in `HKLM\SOFTWARE\USBGuard\Allowlist`. Matched by prefix (`USBSTOR\DISK&VEN_...`) so the trailing `&0` suffix is ignored.
- **Tamper Detection**: `Install-TamperDetection` installs `USBGuard_TamperDetection` scheduled task (every 5 min, SYSTEM). Checks L1 USBSTOR, L2 WriteProtect, L7 WpdFilesystemDriver; re-applies any reverted values and logs to `tamper.log`, `audit.log`, and EventLog (EventId 1009, Warning).
- **Logging**: `Write-Log` prefixes `[YYYY-MM-DD HH:mm:ss][LEVEL]` and optionally appends to `$OutputFile` (used by HTA to capture PS output).
- **Audit Log**: `Write-AuditEntry` appends a line to `%ProgramData%\USBGuard\audit.log` on every block/unblock action. Format: `[timestamp] ACTION=<action> USER=<domain\user>`.
- **Windows Event Log**: `Write-EventLogEntry` writes to `Application` log, source `USBGuard`. Event IDs 1001–1009 map to each block/unblock/tamper action. Source is auto-created on first write.
- **Input Validation**: `Save-NotifyConfig` strips control characters and enforces `CompanyName ≤ 100 chars`, `NotifyMessage ≤ 500 chars` before writing to registry.

### Action Map
```
status                     → Get-Status → JSON (includes AllowlistCount, TamperDetection)
block                      → L1-L7 all layers
unblock                    → reverse all layers
block-storage              → L1+L2+L3(storage)+L4+L5+L6
unblock-storage            → reverse above
block-phones               → L7 (WPD/MTP/PTP)
unblock-phones             → reverse L7
block-printers             → L3 (printer GUID) + DenyInstall
unblock-printers           → reverse above
install-watcher            → L5 scheduled task only
remove-watcher             → remove L5 task
set-notify-config          → save company name + message to HKLM\SOFTWARE\USBGuard
add-allowlist -DeviceId    → add PNP Device ID prefix to allowlist
remove-allowlist -DeviceId → remove from allowlist
list-allowlist             → output JSON array of allowlist entries
install-tamper-detection   → install USBGuard_TamperDetection task (5-min checks)
remove-tamper-detection    → remove tamper detection task
```

---

## HTA GUI (USBGuard.hta)

- Runs in MSHTML (IE11 engine on Windows 10/11). HTA runs with elevated trust.
- **VBScript layer** (`RunPS`) shells out to `powershell.exe`, captures output via temp file.
- **JavaScript layer** parses JSON status from PS and updates the status cards.
- `refreshStatus()` calls `RunPS('-Action status')` → `parseStatus()` → `updateStatusUI()`.
- `runAction()` gates on `isAdmin`, shows loading overlay, calls PS, refreshes status.
- **Status card IDs**: `card-storage`, `card-writeprotect`, `card-autoplay`, `card-watcher`, `card-phones`, `card-printers`, `card-tamper`
- **Control panels**: Mass Storage, Phones/MTP/PTP, USB Printers (+ Master Control block/unblock all + Tamper Detection enable/disable row)
- **Notification panel**: Company name + message template (saved via `set-notify-config`)
- **Allowlist panel**: List of allowlisted PNP Device IDs with add/remove/refresh controls (calls `add-allowlist`, `remove-allowlist`, `list-allowlist`)
- **Tamper Detection**: Status card + Enable/Disable buttons in Master Control row

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

### CI (GitHub Actions)

**`.github/workflows/pester-tests.yml`** — PowerShell/Pester tests
Jobs: `syntax-check` → `pester-tests (matrix)` + `code-analysis` + `registry-validation` → `documentation-check` → `summary`
**Matrix**: `pester-tests` runs on `windows-2022` (≈ Win10/11) and `windows-latest` (Server 2025). `fail-fast: false` so both complete even if one fails. Artifacts uploaded as `test-results-<os>`; `publish-test-results` collects with `pattern: test-results-*`. Note: `windows-2019` was dropped — GitHub deprecated those runners in early 2026.

**`.github/workflows/api-tests.yml`** — Python/FastAPI tests
Runs on `ubuntu-latest` when anything under `USBGuard-API/` changes. Creates a stub `appsettings.json` (secrets mocked in tests — no real BigFix needed). Publishes JUnit results via `dorny/test-reporter`.

### Test Files (116 tests total)
| File | Tests | Coverage |
|------|-------|----------|
| `unit/Registry.Tests.ps1` | 15 | Registry helpers |
| `unit/StatusDetection.Tests.ps1` | 11 | Status parsing |
| `unit/WpdMtp.Tests.ps1` | 16 | L7 WPD/MTP/PTP block/unblock |
| `unit/AuditNotify.Tests.ps1` | 24 | Write-AuditEntry, Write-EventLogEntry, input validation |
| `unit/ComplianceReport.Tests.ps1` | 20 | Layer status map, HTML report generation |
| `unit/NotifyWebhook.Tests.ps1` | 20 | Teams + Slack payload builders |
| `integration/BlockUnblock.Tests.ps1` | 10 | Idempotency, round-trips |

### Simulation Scripts (manual, require admin)
| Script | What it proves |
|--------|---------------|
| `simulation/TamperDetection.Simulation.ps1` | Reverts USBSTOR Start=3, invokes TamperDetect.ps1, asserts Start restored to 4 and log written |
| `simulation/BypassAttempt.Simulation.ps1` | Attempts 7 bypass vectors (registry revert, service kill, etc.); reports BLOCKED vs SUCCEEDED; restores all changes |

### Remaining Coverage Gaps
- `Install-VolumeWatcher` / `Remove-VolumeWatcher` (requires SYSTEM context / task scheduler)
- `Install-TamperDetection` / `Remove-TamperDetection` (same reason)
- HTA logic is not unit-tested (VBScript/JS — manual testing required)
- L6 Thunderbolt block/unblock not integration-tested

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
