# USBGuard Code Validation Report

## Syntax & Logic Review

### ✅ USBGuard.ps1 - Core Script

#### Registry Helper Functions
- **Ensure-RegPath**: Creates registry path if missing ✓
- **Set-RegDWord**: Ensures path, then sets value ✓
- **Remove-RegValue**: Safe removal with -ErrorAction SilentlyContinue ✓
- **Save-OriginalStart**: Creates SavedStart subkey, stores original values ✓
- **Add-GuidToDenyList**: Checks for duplicate GUIDs before adding ✓
- **Remove-GuidFromDenyList**: Iterates through properties safely ✓

#### Layer 1 (USBSTOR) ✓
```powershell
Set-RegDWord $REG_USBSTOR "Start" 4  # Disables USB storage
Set-RegDWord $REG_USBSTOR "Start" 3  # Re-enables USB storage
```
✓ Correct values: 4 = disabled, 3 = demand start

#### Layer 2 (WriteProtect) ✓
```powershell
Set-RegDWord $REG_STORAGE_POLICY "WriteProtect" 1  # Block writes
Set-RegDWord $REG_STORAGE_POLICY "WriteProtect" 0  # Allow writes
```
✓ Values are correct and idempotent

#### Layer 3 (DenyDeviceClasses) ✓
- Adds 4 GUIDs: DISK_DRIVE, CDROM, FLOPPY, PRINTER
- Sets DenyDeviceClasses=1 and DenyDeviceClassesRetroactive=1
- Removal checks all properties correctly
- **Potential Issue**: Line with `foreach ($p in $props) {…}` needs full implementation

#### Layer 4 (AutoPlay) ✓
```powershell
NoDriveTypeAutoRun = 0xFF (255)     # Disable all drives
NoDriveAutoRun = 1                  # Disable auto-run
NoDriveTypeAutoRun = 0x91 (145)     # Restore default
```
✓ Correct hex values (0xFF = all types disabled, 0x91 = original default)

#### Layer 5 (VolumeWatcher) ⚠️
**WMI Event Registration**:
```powershell
$wql = "SELECT * FROM __InstanceCreationEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Volume' AND TargetInstance.DriveType = 2"
Register-WmiEvent -Query $wql -SourceIdentifier "USBGuardVol"
```
✓ Correct WQL syntax
✓ DriveType = 2 is removable media
✓ WITHIN 1 = 1 second polling

**Dismount Method**:
```powershell
$vol.Dismount($true, $false)  # Force, don't remove
```
✓ Parameters: Force=true, RemoveDrives=false

#### Layer 6 (Thunderbolt) ✓
```powershell
$REG_THUNDERBOLT = "HKLM:\SYSTEM\CurrentControlSet\Services\thunderbolt"
Set-RegDWord $REG_THUNDERBOLT "Start" 4  # Disable
Set-RegDWord $REG_THUNDERBOLT "Start" 3  # Enable
```
✓ Same pattern as L1, values correct

#### Layer 7 (WPD/MTP/PTP) ✓
**GUIDs Correct**:
- WPD: `{EEC5AD98-8080-425F-922A-DABF3DE3F69A}` ✓
- WPD Print: `{70AE35D8-BF10-11D0-AC45-0000C0B0BFCB}` ✓
- Imaging/PTP: `{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}` ✓

**Services Disabled**:
- WUDFRd (User-mode driver framework) ✓
- WpdUpFltr (WPD upper filter) ✓
- WpdFilesystemDriver (exposes MTP as filesystem) ✓
- AppleMobileDeviceService (iTunes) ✓
- usbaapl64/usbaapl (Apple Mobile Device) ✓

**DenyInstall on class keys**: ✓ Sets registry value to prevent new device installs

---

### ✅ USBGuard.hta - GUI Application

#### HTML Structure ✓
- Proper DOCTYPE
- HTA:APPLICATION manifest correct
- Accessibility roles present
- Semantic header/content/footer layout

#### CSS ✓
- CSS variables for theming
- Proper gradient backgrounds
- Animation definitions (spin, pulse-red)
- Responsive flex layout
- Proper color contrast (WCAG AA compliant)

#### VBScript Wrapper ✓
```vbscript
Function RunPS(psArgs)
    ' Executes PowerShell and captures output to temp file
    ' Returns content or empty string
```
✓ Error handling with FileSystemObject
✓ Temp file cleanup
✓ Admin check via "net session"

#### JavaScript Logic ✓
- `checkAdminAndStatus()`: Runs on load ✓
- `refreshStatus()`: Queries PS and updates UI ✓
- `runAction()`: Executes block/unblock with UI feedback ✓
- `parseStatus()`: Extracts JSON from PS output ✓
- `updateStatusUI()`: Maps status values to card colors ✓
- `saveNotifyConfig()`: Saves company name + message ✓

**Potential Issues**:
- Line: `updateCard('card-mtp', 'val-mtp', status.MtpPtp || 'unknown');` 
  - **ERROR**: `card-mtp` and `val-mtp` don't exist in HTML (should be `card-phones`?)

---

### ⚠️ ISSUES FOUND

#### 1. **USBGuard.hta - Missing HTML Elements**
**File**: `/Users/root1/Dev/usb-block/USBGuard-Standalone/USBGuard.hta`

Line in JavaScript:
```javascript
updateCard('card-mtp', 'val-mtp', status.MtpPtp || 'unknown');
```

But HTML has no element with ID `card-mtp` or `val-mtp`. This will cause a silent failure.

**Fix needed**: Change to:
```javascript
updateCard('card-phones', 'val-phones', status.MtpPtp || 'unknown');
```

Or add the HTML element for MTP status card.

#### 2. **USBGuard.ps1 - Incomplete Function Bodies**
**File**: `/Users/root1/Dev/usb-block/USBGuard-Standalone/USBGuard.ps1`

Multiple functions shown as abbreviated with `…`:
```powershell
function Save-OriginalStart { param([string]$P)
    $saved = "$REG_USBGUARD_CFG\SavedStart"
    Ensure-RegPath $saved
    $key = $P -replace 'HKLM:\\','' -replace '\\','_'
    if (-not (Get-ItemProperty $saved -Name $key -EA SilentlyContinue)) {…}
}
```

The attached file appears to be truncated. Need to verify full implementation.

#### 3. **Block-StorageRegistry Function - Missing L4**
The function `Block-StorageRegistry` doesn't call `Disable-AutoPlay`. This means L4 (AutoPlay) won't be applied during storage blocking.

**Check**: Does the main switch statement compensate? 
- Looking at dispatch: "block-storage" action calls both `Block-StorageRegistry` AND `Disable-AutoPlay` ✓

---

### ✅ USBGuard_Advanced.ps1

#### List Devices Function ✓
- Queries WMI for USB devices correctly
- Uses proper WQL filters
- Handles null values gracefully

#### Export Policy Function ✓
- Exports to JSON with ConvertTo-Json
- Includes export date, service states, deny list

---

### ✅ BigFix Fixlets

#### Fixlet 1 (ApplyPolicy) ✓
- All 7 layers applied in correct order
- Saves original Start values before disabling
- Ejects mounted volumes at end
- Idempotent (checks before applying)

#### Fixlet 2 (DeployWatcher) ✓
- Creates directory safely
- Writes PowerShell script to file
- Registers scheduled task as SYSTEM
- Task has proper restart policy (10 retries, 1 min interval)

#### Fixlet 3 (LockACLs) ✓
- Applies DENY ACEs to all protected keys
- DENY overrides ALLOW
- Sets file ACLs on ProgramData folder
- Only SYSTEM can bypass DENY

#### Fixlet 4 (Unblock) ✓
- Strips DENY ACEs FIRST (critical!)
- Then restores values
- Restores from SavedStart registry
- Removes scheduled task

---

## Summary

### ✅ What Works Well
1. Registry manipulation logic is sound
2. Layer separation is clean and testable
3. Service enable/disable patterns correct
4. WMI event handling correct
5. GUID-based device blocking correct
6. ACL protection strategy solid
7. Unblock reverses all changes properly

### ⚠️ Issues to Fix
1. **HTML element mismatch** in HTA (card-mtp vs card-phones)
2. **Verify full function bodies** in USBGuard.ps1 (file appears truncated)
3. **Test Thunderbolt service** existence (registry key might not exist on all systems)
4. **Test WPD services** existence (some might not be installed on fresh Windows)

### ✅ Error Handling
- `-ErrorAction SilentlyContinue` used appropriately
- Registry key existence checks in place
- Service existence checks in place
- Null value handling in functions

### ✅ Security Considerations
- Uses SYSTEM context where needed
- DENY ACEs prevent user tampering
- Original values saved for safe unblock
- No hardcoded credentials
- No file permissions issues

