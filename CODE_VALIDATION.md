# USBGuard Code Validation Report

Last updated after bug-fix pass.

---

## Bugs Found and Fixed

| # | File | Severity | Description | Status |
|---|------|----------|-------------|--------|
| 1 | `USBGuard.hta` | **Critical** | `card-phones` / `val-phones` HTML elements missing — L7 MTP/PTP status was silently never displayed in UI | ✅ Fixed: added phones status card to HTML status bar |
| 2 | `USBGuard.hta` | **High** | No Phones/Cameras control panel in UI despite `block-phones` / `unblock-phones` backend support | ✅ Fixed: added Phones & Cameras panel to control grid |
| 3 | `USBGuard.hta` | **Medium** | `eval()` used to parse JSON from PowerShell — insecure in any context | ✅ Fixed: replaced with `JSON.parse()` |
| 4 | `USBGuard.hta` | **Low** | `MtpPtp` status not included in the Activity Log status line | ✅ Fixed: added `Phones/MTP:` field to log output |
| 5 | `USBGuard.hta` | **Low** | `block-phones` / `unblock-phones` missing from the action labels map — showed generic "Applying changes..." | ✅ Fixed: added both labels |
| 6 | `USBGuard.hta` | **Low** | VolumeWatcher `not_installed` state mapped to `allowed` (green card) — misleading, watcher being off is not a safe state | ✅ Fixed: mapped to `unknown` (amber) |

---

## Validation by Component

### USBGuard.ps1 — Core PowerShell Backend

#### Registry Helpers ✅
- `Ensure-RegPath` — creates path if missing, idempotent ✅
- `Set-RegDWord` — ensures path, sets value ✅
- `Remove-RegValue` — safe removal with `-EA SilentlyContinue` ✅
- `Save-OriginalStart` — saves before clobber, does NOT overwrite if already saved ✅
- `Get-SavedStart` — retrieves saved value, returns `$null` if not saved ✅
- `Add-GuidToDenyList` — deduplicates before adding, auto-increments property name ✅
- `Remove-GuidFromDenyList` — iterates safely, no crash if GUID absent ✅

#### Layer 1 (USBSTOR) ✅
```powershell
Set-RegDWord $REG_USBSTOR "Start" 4   # Disable (blocked)
Set-RegDWord $REG_USBSTOR "Start" 3   # Re-enable (allowed)
```
Values correct: 4 = disabled, 3 = demand start. ✅

#### Layer 2 (WriteProtect) ✅
```powershell
Set-RegDWord $REG_STORAGE_POLICY "WriteProtect" 1   # Block writes
Set-RegDWord $REG_STORAGE_POLICY "WriteProtect" 0   # Allow writes
```
Idempotent — path is created if missing. ✅

#### Layer 3 (DenyDeviceClasses) ✅
- GUIDs added: `DISK_DRIVE`, `CDROM`, `FLOPPY`, `PRINTER`
- Sets `DenyDeviceClasses=1` and `DenyDeviceClassesRetroactive=1`
- Cleans up flags when deny list becomes empty after unblock ✅

#### Layer 4 (AutoPlay) ✅
```powershell
NoDriveTypeAutoRun = 0xFF (255)    # Disable all drive types
NoDriveAutoRun = 1                 # Disable AutoRun
NoDriveTypeAutoRun = 0x91 (145)   # Restore default
```
Applied at both HKLM (machine) and HKCU (user) levels. ✅
`NoAutoplayfornonVolume` also set in GPO path. ✅

#### Layer 5 (VolumeWatcher) ✅
```powershell
$wql = "SELECT * FROM __InstanceCreationEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Volume' AND TargetInstance.DriveType = 2"
```
- WQL syntax correct ✅
- DriveType = 2 = removable ✅
- WITHIN 1 = 1-second polling interval ✅
- `$vol.Dismount($true, $false)` — Force=true, RemoveDrives=false ✅
- Falls back to Shell.Application `InvokeVerb("Eject")` if WMI dismount fails ✅
- Toast dispatched via temporary per-user scheduled task (avoids SYSTEM → desktop UI issues) ✅

#### Layer 6 (Thunderbolt) ✅
```powershell
$REG_THUNDERBOLT = "HKLM:\SYSTEM\CurrentControlSet\Services\thunderbolt"
Set-RegDWord $REG_THUNDERBOLT "Start" 4   # Disable
Set-RegDWord $REG_THUNDERBOLT "Start" 3   # Enable
```
Wrapped in `if (Test-Path ...)` — safe on machines without Thunderbolt. ✅

#### Layer 7 (WPD/MTP/PTP) ✅

**GUIDs correct:**
- WPD: `{EEC5AD98-8080-425F-922A-DABF3DE3F69A}` ✅
- WPD Print: `{70AE35D8-BF10-11D0-AC45-0000C0B0BFCB}` ✅
- Imaging/PTP: `{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}` ✅

**Services disabled (Start=4):**
- `WUDFRd` — Windows User-mode Driver Framework ✅
- `WpdUpFltr` — WPD upper filter ✅
- `WpdFilesystemDriver` — exposes MTP as browsable filesystem ✅
- `AppleMobileDeviceService`, `usbaapl64`, `usbaapl` — Apple/iTunes services ✅

**Original Start values saved** via `Save-OriginalStart` before disabling, restored via `Get-SavedStart` during unblock (falls back to 3 if no saved value). ✅

**`DenyInstall`** set on WPD and Imaging class keys as belt-and-suspenders. ✅

**`Get-WpdStatus`** checks both GUID in deny list AND `WpdFilesystemDriver Start=4`; returns `blocked`, `partial`, or `allowed`. ✅

#### Status (Get-Status) ✅
Returns ordered hashtable with: `UsbStorage`, `WriteProtect`, `AutoPlayKilled`, `VolumeWatcher`, `Thunderbolt`, `MtpPtp`, `UsbPrinters`, `CompanyName`, `Timestamp`. Serialized as JSON for HTA consumption. ✅

#### Main Dispatch ✅
All actions covered: `status`, `block`, `unblock`, `block-storage`, `unblock-storage`, `block-phones`, `unblock-phones`, `block-printers`, `unblock-printers`, `install-watcher`, `remove-watcher`, `set-notify-config`. ✅

---

### USBGuard.hta — GUI Application

#### HTML Structure ✅ (post-fix)
- Status cards: `card-storage`, `card-writeprotect`, `card-autoplay`, `card-watcher`, `card-phones` (added), `card-printers` ✅
- Control panels: Mass Storage, Phones & Cameras (added), USB Printers ✅
- Master Control: Block All / Allow All ✅
- Notification panel with company name + message template + live preview ✅

#### VBScript Layer ✅
- `RunPS(psArgs)` — shells to `powershell.exe`, captures to temp file, returns content ✅
- `CheckAdmin()` — `net session` exit code check ✅
- Temp file cleanup after read ✅

#### JavaScript Layer ✅ (post-fix)
- `checkAdminAndStatus()` on load ✅
- `refreshStatus()` → `RunPS(-Action status)` → `parseStatus()` → `updateStatusUI()` ✅
- `JSON.parse()` used for status parsing (was `eval()` — fixed) ✅
- `updateCard()` null-checks both elements before update — silent fail if missing ✅
- `runAction()` gates on `isAdmin`, shows loading overlay, refreshes after ✅
- MtpPtp status logged in Activity Log (was missing — fixed) ✅
- `block-phones` / `unblock-phones` in action labels map (was missing — fixed) ✅
- VolumeWatcher `not_installed` → `unknown` (amber) not `allowed` (green — was misleading, fixed) ✅

---

### USBGuard_Advanced.ps1 ✅
- `list-devices` — WMI query for USB devices, null-safe, formatted output ✅
- `export-policy` — JSON export with timestamp, service states, deny list ✅

---

### BigFix Fixlets

#### Fixlet 1 (ApplyPolicy) ✅
- All 7 layers applied in correct order ✅
- Saves original WPD service Start values before disabling ✅
- Does not overwrite if already saved (idempotent) ✅
- Ejects mounted removable volumes at end ✅
- `action uses wow64 redirection false` — 64-bit registry ✅
- Relevance expression checks all critical layer values ✅

#### Fixlet 2 (DeployWatcher) ✅
- Creates `%ProgramData%\USBGuard` directory safely ✅
- Writes VolumeWatcher.ps1 to disk ✅
- Registers SYSTEM scheduled task with restart policy (10 retries, 1 min interval) ✅
- `MultipleInstances = IgnoreNew` prevents duplicate runs ✅

#### Fixlet 3 (LockACLs) ✅
- Applies DENY ACEs to all protected registry keys ✅
- DENY overrides ALLOW — even local admins blocked ✅
- Sets file ACLs on ProgramData\USBGuard folder ✅
- Only SYSTEM can bypass ✅

#### Fixlet 4 (Unblock) ✅
- **Strips DENY ACEs FIRST** before any registry changes — critical ordering ✅
- Restores WPD service Start values from `SavedStart` registry ✅
- Removes Volume Watcher scheduled task ✅
- Removes `DenyInstall` from class keys ✅
- Restores AutoPlay defaults ✅

#### Fixlet 5 (ComplianceDetection) ✅
- Relevance-only (no action) ✅
- Analysis Properties cover all 7 layers ✅
- `USBGuard_Overall` = COMPLIANT / NON-COMPLIANT aggregate ✅

---

### Tests

#### Unit Tests — Registry.Tests.ps1 ✅
- `Ensure-RegPath` create and idempotent ✅
- `Set-RegDWord` set + overwrite ✅
- `Remove-RegValue` existing, non-existent, missing path ✅
- `Save-OriginalStart` / `Get-SavedStart` roundtrip and no-overwrite ✅
- `Add-GuidToDenyList` deduplication and incrementing ✅
- `Remove-GuidFromDenyList` removal and non-existent ✅

#### Unit Tests — StatusDetection.Tests.ps1 ✅
- USBSTOR blocked/allowed/unknown ✅
- WriteProtect active/inactive/missing ✅
- AutoPlay disabled/enabled ✅
- Thunderbolt blocked/not_present ✅
- JSON serialization/deserialization roundtrip ✅

#### Integration Tests — BlockUnblock.Tests.ps1 ✅
- Block idempotency (block twice = still 4) ✅
- Original value saved only once ✅
- Block → Unblock roundtrip restores value ✅
- Service originally disabled stays disabled after unblock ✅
- GUID add/remove doesn't corrupt deny list ✅
- Multi-layer block/unblock sequence ✅
- Notification config save/retrieve ✅
- `{COMPANY}` placeholder replacement ✅

#### Test Coverage Gaps ⚠️
- No tests for `Get-WpdStatus` (L7 status logic)
- No tests for `Block-WpdMtp` / `Unblock-WpdMtp` end-to-end
- No tests for `Install-VolumeWatcher` / `Remove-VolumeWatcher` (requires SYSTEM/task scheduler)
- `Unblock-StorageRegistry_Test` helper hardcodes `Start=3` instead of restoring saved value (test-only simplification — production code is correct)
- HTA JavaScript not unit-tested (manual testing required)

---

## Overall Assessment

| Area | Status |
|------|--------|
| Registry logic | ✅ Sound |
| Layer separation | ✅ Clean and independently testable |
| Unblock / restore | ✅ Correct (WPD uses saved values; USBSTOR restores to 3 which is standard demand-start) |
| WMI event handling | ✅ Correct |
| GUID-based blocking | ✅ Correct |
| ACL protection (BigFix) | ✅ Solid — DENY ACEs on all protected keys |
| HTA status display | ✅ All 6 bugs fixed |
| Security | ✅ No credentials, no hardcoded paths, `JSON.parse()` not `eval()` |
| Error handling | ✅ `-EA SilentlyContinue` used appropriately throughout |
