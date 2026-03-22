#Requires -RunAsAdministrator
<#
.SYNOPSIS
    USBGuard v4 - USB Mass Storage, Printer, MTP/PTP Lockdown + User Notifications

    LAYERS:
    L1  USBSTOR service Start=4              Flash drives, external HDDs, USB-C drives
    L2  StorageDevicePolicies WriteProtect=1  Forensic write-block on any storage
    L3  DenyDeviceClasses (disk/cdrom/floppy) GUID-based class policy
    L4  AutoPlay killed + ShellHWDetection stopped   No popup window ever
    L5  WMI Volume Watcher (SYSTEM task)     Auto-ejects within 1s + user toast
    L6  Thunderbolt service Start=4          Thunderbolt external drives
    L7  WPD stack disabled + MTP/PTP GUIDs   Android (MTP), iPhone (PTP/iTunes),
                                             cameras, media players via USB

    PRESERVED (never touched):
      HID  {745A17A0-74D3-11D0-B6FE-00A0C90F57DA}  Keyboards, mice
      Hub  {36FC9E60-C465-11CF-8056-444553540000}  USB hubs
      Audio {4D36E96C-E325-11CE-BFC1-08002BE10318}  USB headsets/speakers
      Internal disks  (SATA, NVMe, eMMC - never in USBSTOR class)

    CHARGING: VBUS power is electrical - unaffected by any layer here.
    Phones charge normally even when fully blocked.

    WHAT L7 BLOCKS:
      - Android phones in File Transfer / MTP mode
      - iPhones via iTunes / Apple Mobile Device (APMD uses PTP underneath)
      - Digital cameras (PTP/MTP)
      - Media players, portable DACs, some GPS devices using MTP
      - Any app (iTunes, Windows Photos import, etc.) that relies on WPD transport
#>

param(
    [ValidateSet(
        "status",
        "block","unblock",
        "block-storage","unblock-storage",
        "block-phones","unblock-phones",
        "block-printers","unblock-printers",
        "block-sdcard","unblock-sdcard",
        "block-bluetooth","unblock-bluetooth",
        "block-firewire","unblock-firewire",
        "install-watcher","remove-watcher",
        "set-notify-config",
        "add-allowlist","remove-allowlist","list-allowlist",
        "install-tamper-detection","remove-tamper-detection"
    )]
    [string]$Action = "status",
    [string]$OutputFile    = "",
    [string]$CompanyName   = "",
    [string]$NotifyMessage = "",
    [string]$DeviceId      = ""
)

$ErrorActionPreference = "Continue"

# ── Device class GUIDs ─────────────────────────────────────────────────────────
$GUID_DISK_DRIVE  = "{4D36E967-E325-11CE-BFC1-08002BE10318}"   # Disk drives
$GUID_PRINTER     = "{4D36E979-E325-11CE-BFC1-08002BE10318}"   # Printers
$GUID_CDROM       = "{4D36E965-E325-11CE-BFC1-08002BE10318}"   # CD/DVD
$GUID_FLOPPY      = "{4D36E969-E325-11CE-BFC1-08002BE10318}"   # Removable/floppy
$GUID_WPD         = "{EEC5AD98-8080-425F-922A-DABF3DE3F69A}"   # WPD (MTP/PTP devices)
$GUID_WPD_PRINT   = "{70AE35D8-BF10-11D0-AC45-0000C0B0BFCB}"  # WPD printer subclass
$GUID_IMAGING     = "{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}"   # Still image/PTP cameras
$GUID_BT_OBEX    = "{E0CBF06C-CD8B-4647-BB8A-263B43F0F974}"   # Bluetooth OBEX (file transfer)

# ── WPD service registry paths (Layer 7) ──────────────────────────────────────
# WUDFRd      - Windows User-mode Driver Framework, hosts WPD drivers
# WpdUpFltr   - WPD upper filter (file operations layer)
# WpdFilesystemDriver - exposes MTP device as browsable filesystem to apps like iTunes
# WMPNSS-SVC  - Windows Media Player Network Sharing (uses WPD for sync)
$REG_WPD_SERVICES = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\WUDFRd",
    "HKLM:\SYSTEM\CurrentControlSet\Services\WpdUpFltr",
    "HKLM:\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver"
)
# Apple-specific: blocks iTunes hardware comms entirely (PTP + AFC protocol)
$REG_APPLE_SERVICES = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\AppleMobileDeviceService",
    "HKLM:\SYSTEM\CurrentControlSet\Services\usbaapl64",
    "HKLM:\SYSTEM\CurrentControlSet\Services\usbaapl"
)

# ── Other registry paths ───────────────────────────────────────────────────────
$REG_USBSTOR        = "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR"
$REG_THUNDERBOLT    = "HKLM:\SYSTEM\CurrentControlSet\Services\thunderbolt"
$REG_STORAGE_POLICY = "HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies"
$REG_CLASS_BASE     = "HKLM:\SYSTEM\CurrentControlSet\Control\Class"
$REG_DENY_BASE      = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
$REG_DENY_CLASSES   = "$REG_DENY_BASE\DenyDeviceClasses"
$REG_AUTOPLAY       = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
$REG_AUTOPLAY_USER  = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
$REG_AUTORUN_POLICY = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
$REG_SDBUS          = "HKLM:\SYSTEM\CurrentControlSet\Services\sdbus"
$REG_BT_OBEX        = "HKLM:\SYSTEM\CurrentControlSet\Services\BthOBEX"
$REG_BT_RFCOMM      = "HKLM:\SYSTEM\CurrentControlSet\Services\RFCOMM"
$REG_FIREWIRE       = "HKLM:\SYSTEM\CurrentControlSet\Services\1394ohci"
$REG_USBGUARD_CFG   = "HKLM:\SOFTWARE\USBGuard"
$REG_ALLOWLIST      = "$REG_USBGUARD_CFG\Allowlist"

# ── Scheduled task / paths ─────────────────────────────────────────────────────
$WATCHER_TASK_NAME = "USBGuard_VolumeWatcher"
$TAMPER_TASK_NAME  = "USBGuard_TamperDetection"
$USBGUARD_DIR      = "$env:ProgramData\USBGuard"
$WATCHER_SCRIPT    = "$USBGUARD_DIR\VolumeWatcher.ps1"
$TAMPER_SCRIPT     = "$USBGUARD_DIR\TamperDetect.ps1"
$NOTIFY_SCRIPT     = "$USBGUARD_DIR\Notify.ps1"
$AUDIT_LOG         = "$USBGUARD_DIR\audit.log"

# ── Logging ────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    if ($OutputFile) { Add-Content -Path $OutputFile -Value $line -Encoding UTF8 }
}

# ── Audit & Event Log ──────────────────────────────────────────────────────────
function Write-AuditEntry {
    param([string]$Action, [string]$Detail = "")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $line = "[$ts] ACTION=$Action USER=$user" + $(if ($Detail) { " $Detail" } else { "" })
    try {
        if (-not (Test-Path $USBGUARD_DIR)) { New-Item -Path $USBGUARD_DIR -ItemType Directory -Force | Out-Null }
        Add-Content -Path $AUDIT_LOG -Value $line -Encoding UTF8
    } catch { $null = $_ }  # non-fatal — don't abort the main operation if audit log fails
}

function Write-EventLogEntry {
    param([string]$Message, [int]$EventId = 1000, [string]$EntryType = "Information")
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists("USBGuard")) {
            [System.Diagnostics.EventLog]::CreateEventSource("USBGuard", "Application")
        }
        Write-EventLog -LogName Application -Source "USBGuard" -EventId $EventId -EntryType $EntryType -Message $Message
    } catch { $null = $_ }  # non-fatal — don't abort the main operation if event log write fails
}

# ── Registry helpers ───────────────────────────────────────────────────────────
function Ensure-RegPath { param([string]$P)
    if (-not (Test-Path $P)) { New-Item -Path $P -Force | Out-Null }
}
function Set-RegDWord { param([string]$P,[string]$N,[int]$V)
    Ensure-RegPath $P
    Set-ItemProperty -Path $P -Name $N -Value $V -Type DWord -Force
}
function Remove-RegValue { param([string]$P,[string]$N)
    if (Test-Path $P) { Remove-ItemProperty -Path $P -Name $N -ErrorAction SilentlyContinue }
}
function Get-SavedStart { param([string]$P)
    # Saves original Start value before we clobber it so unblock can restore properly
    $saved = "$REG_USBGUARD_CFG\SavedStart"
    Ensure-RegPath $saved
    $key = $P -replace 'HKLM:\\','' -replace '\\','_'
    return (Get-ItemProperty $saved -Name $key -EA SilentlyContinue).$key
}
function Save-OriginalStart { param([string]$P)
    $saved = "$REG_USBGUARD_CFG\SavedStart"
    Ensure-RegPath $saved
    $key = $P -replace 'HKLM:\\','' -replace '\\','_'
    if (-not (Get-ItemProperty $saved -Name $key -EA SilentlyContinue)) {
        $cur = (Get-ItemProperty $P -Name "Start" -EA SilentlyContinue).Start
        if ($null -ne $cur) {
            Set-ItemProperty $saved -Name $key -Value $cur -Type DWord -Force
        }
    }
}
function Add-GuidToDenyList { param([string]$Guid)
    Ensure-RegPath $REG_DENY_CLASSES
    $props = (Get-Item $REG_DENY_CLASSES -EA SilentlyContinue).Property
    foreach ($p in $props) {
        if ((Get-ItemProperty $REG_DENY_CLASSES -Name $p -EA SilentlyContinue).$p -eq $Guid) { return }
    }
    $next = 1
    if ($props) { $next = (($props | ForEach-Object { try {[int]$_} catch {0} } | Measure-Object -Maximum).Maximum) + 1 }
    Set-ItemProperty $REG_DENY_CLASSES -Name "$next" -Value $Guid -Type String
}
function Remove-GuidFromDenyList { param([string]$Guid)
    if (-not (Test-Path $REG_DENY_CLASSES)) { return }
    $props = (Get-Item $REG_DENY_CLASSES -EA SilentlyContinue).Property
    foreach ($p in $props) {
        if ((Get-ItemProperty $REG_DENY_CLASSES -Name $p -EA SilentlyContinue).$p -eq $Guid) {
            Remove-ItemProperty $REG_DENY_CLASSES -Name $p -EA SilentlyContinue
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  LAYER 7 — WPD / MTP / PTP block
#  Targets: Android MTP, iPhone PTP/iTunes, cameras, media players
# ─────────────────────────────────────────────────────────────────────────────
function Block-WpdMtp {
    Write-Log "L7: Blocking WPD/MTP/PTP stack (Android, iPhone, cameras)..." "INFO"

    # 7a — Deny device class GUIDs: WPD, imaging (PTP cameras), WPD print
    Ensure-RegPath $REG_DENY_BASE
    Set-RegDWord $REG_DENY_BASE "DenyDeviceClasses"            1
    Set-RegDWord $REG_DENY_BASE "DenyDeviceClassesRetroactive" 1
    Ensure-RegPath $REG_DENY_CLASSES
    Add-GuidToDenyList $GUID_WPD
    Add-GuidToDenyList $GUID_WPD_PRINT
    Add-GuidToDenyList $GUID_IMAGING
    Write-Log "L7a: WPD/PTP/Imaging class GUIDs added to deny list" "SUCCESS"

    # 7b — Disable WPD service drivers
    foreach ($svc in $REG_WPD_SERVICES) {
        if (Test-Path $svc) {
            Save-OriginalStart $svc
            Set-RegDWord $svc "Start" 4
            $name = Split-Path $svc -Leaf
            Write-Log "L7b: $name disabled (Start=4)" "SUCCESS"
        }
    }

    # 7c — Disable Apple Mobile Device services (iTunes transport layer)
    foreach ($svc in $REG_APPLE_SERVICES) {
        if (Test-Path $svc) {
            Save-OriginalStart $svc
            Set-RegDWord $svc "Start" 4
            $name = Split-Path $svc -Leaf
            Write-Log "L7c: Apple service $name disabled" "SUCCESS"
        }
    }

    # 7d — Stop any currently running WPD/Apple services
    $runningServices = @("WUDFSvc","WpdUpFltr","AppleMobileDeviceService")
    foreach ($s in $runningServices) {
        try {
            $svc = Get-Service $s -EA SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") {
                Stop-Service $s -Force -EA SilentlyContinue
                Write-Log "L7d: Stopped running service: $s" "SUCCESS"
            }
        } catch { $null = $_ }  # service may not exist on all systems
    }

    # 7e — Deny install on the class keys directly (belt-and-suspenders)
    foreach ($guid in @($GUID_WPD, $GUID_IMAGING)) {
        $cp = "$REG_CLASS_BASE\$guid"
        if (Test-Path $cp) { Set-RegDWord $cp "DenyInstall" 1 }
    }
    Write-Log "L7e: DenyInstall set on WPD and Imaging class keys" "SUCCESS"

    Write-Log "L7: WPD/MTP/PTP fully blocked. Charging unaffected." "SUCCESS"
}

function Unblock-WpdMtp {
    Write-Log "L7: Restoring WPD/MTP/PTP stack..." "INFO"

    Remove-GuidFromDenyList $GUID_WPD
    Remove-GuidFromDenyList $GUID_WPD_PRINT
    Remove-GuidFromDenyList $GUID_IMAGING

    # Restore WPD services to their original Start values (usually 3 = demand)
    foreach ($svc in ($REG_WPD_SERVICES + $REG_APPLE_SERVICES)) {
        if (Test-Path $svc) {
            $name    = Split-Path $svc -Leaf
            $original = Get-SavedStart $svc
            $restore  = if ($null -ne $original) { $original } else { 3 }
            Set-RegDWord $svc "Start" $restore
            Write-Log "L7: $name restored (Start=$restore)" "SUCCESS"
        }
    }

    # Remove DenyInstall from class keys
    foreach ($guid in @($GUID_WPD, $GUID_IMAGING)) {
        $cp = "$REG_CLASS_BASE\$guid"
        if (Test-Path $cp) { Remove-RegValue $cp "DenyInstall" }
    }

    # Clean up deny list flags if now empty
    $remaining = (Get-Item $REG_DENY_CLASSES -EA SilentlyContinue).Property
    if (-not $remaining) {
        Set-RegDWord $REG_DENY_BASE "DenyDeviceClasses"            0
        Set-RegDWord $REG_DENY_BASE "DenyDeviceClassesRetroactive" 0
    }

    Write-Log "L7: WPD/MTP/PTP restored. Reconnect devices." "SUCCESS"
}

# ── Status check for L7 ───────────────────────────────────────────────────────
function Get-WpdStatus {
    # Check WpdFilesystemDriver as the representative service
    $svcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver"
    $guidBlocked = $false
    if (Test-Path $REG_DENY_CLASSES) {
        foreach ($k in (Get-Item $REG_DENY_CLASSES -EA SilentlyContinue).Property) {
            if ((Get-ItemProperty $REG_DENY_CLASSES -Name $k -EA SilentlyContinue).$k -eq $GUID_WPD) {
                $guidBlocked = $true; break
            }
        }
    }
    $svcDisabled = $false
    if (Test-Path $svcPath) {
        $v = (Get-ItemProperty $svcPath -Name "Start" -EA SilentlyContinue).Start
        $svcDisabled = ($v -eq 4)
    }
    if ($guidBlocked -and $svcDisabled) { return "blocked" }
    if ($guidBlocked -or $svcDisabled)  { return "partial" }
    return "allowed"
}

# ─────────────────────────────────────────────────────────────────────────────
#  LAYERS 1-3, 6
# ─────────────────────────────────────────────────────────────────────────────
function Block-StorageRegistry {
    if (Test-Path $REG_USBSTOR) {
        Save-OriginalStart $REG_USBSTOR
        Set-RegDWord $REG_USBSTOR "Start" 4
        Write-Log "L1: USBSTOR disabled (Start=4)" "SUCCESS"
    } else { Write-Log "L1: USBSTOR key not found" "WARN" }

    Ensure-RegPath $REG_STORAGE_POLICY
    Set-RegDWord $REG_STORAGE_POLICY "WriteProtect" 1
    Write-Log "L2: WriteProtect=1 (write-block active)" "SUCCESS"

    Ensure-RegPath $REG_DENY_BASE
    Set-RegDWord $REG_DENY_BASE "DenyDeviceClasses"            1
    Set-RegDWord $REG_DENY_BASE "DenyDeviceClassesRetroactive" 1
    Ensure-RegPath $REG_DENY_CLASSES
    Add-GuidToDenyList $GUID_DISK_DRIVE
    Add-GuidToDenyList $GUID_CDROM
    Add-GuidToDenyList $GUID_FLOPPY
    Write-Log "L3: DenyDeviceClasses policy applied" "SUCCESS"

    if (Test-Path $REG_THUNDERBOLT) {
        Save-OriginalStart $REG_THUNDERBOLT
        Set-RegDWord $REG_THUNDERBOLT "Start" 4
        Write-Log "L6: Thunderbolt disabled" "SUCCESS"
    }

    Eject-AllRemovableVolumes
}

function Unblock-StorageRegistry {
    if (Test-Path $REG_USBSTOR) {
        $restore = Get-SavedStart $REG_USBSTOR
        $startVal = if ($null -ne $restore) { $restore } else { 3 }
        Set-RegDWord $REG_USBSTOR "Start" $startVal
        Write-Log "L1: USBSTOR restored (Start=$startVal)" "SUCCESS"
    }
    Set-RegDWord $REG_STORAGE_POLICY "WriteProtect" 0
    Write-Log "L2: WriteProtect cleared" "SUCCESS"

    Remove-GuidFromDenyList $GUID_DISK_DRIVE
    Remove-GuidFromDenyList $GUID_CDROM
    Remove-GuidFromDenyList $GUID_FLOPPY
    $remaining = (Get-Item $REG_DENY_CLASSES -EA SilentlyContinue).Property
    if (-not $remaining) {
        Set-RegDWord $REG_DENY_BASE "DenyDeviceClasses"            0
        Set-RegDWord $REG_DENY_BASE "DenyDeviceClassesRetroactive" 0
    }
    Write-Log "L3: DenyDeviceClasses cleared" "SUCCESS"

    if (Test-Path $REG_THUNDERBOLT) {
        $restore = Get-SavedStart $REG_THUNDERBOLT
        $startVal = if ($null -ne $restore) { $restore } else { 3 }
        Set-RegDWord $REG_THUNDERBOLT "Start" $startVal
        Write-Log "L6: Thunderbolt restored (Start=$startVal)" "SUCCESS"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  LAYER 4 — AutoPlay / ShellHWDetection
# ─────────────────────────────────────────────────────────────────────────────
function Disable-AutoPlay {
    Ensure-RegPath $REG_AUTOPLAY
    Set-RegDWord $REG_AUTOPLAY      "NoDriveTypeAutoRun" 0xFF
    Set-RegDWord $REG_AUTOPLAY      "NoDriveAutoRun"     1
    Ensure-RegPath $REG_AUTOPLAY_USER
    Set-RegDWord $REG_AUTOPLAY_USER "NoDriveTypeAutoRun" 0xFF
    Set-RegDWord $REG_AUTOPLAY_USER "NoDriveAutoRun"     1
    Ensure-RegPath $REG_AUTORUN_POLICY
    Set-RegDWord $REG_AUTORUN_POLICY "NoAutoplayfornonVolume" 1
    try {
        Set-Service  "ShellHWDetection" -StartupType Disabled -EA SilentlyContinue
        Stop-Service "ShellHWDetection" -Force -EA SilentlyContinue
        Write-Log "L4: ShellHWDetection stopped (no AutoPlay popup)" "SUCCESS"
    } catch { $null = $_ }  # service may not be running; already stopped is acceptable
    Write-Log "L4: AutoPlay disabled (NoDriveTypeAutoRun=0xFF)" "SUCCESS"
}

function Enable-AutoPlay {
    Set-RegDWord $REG_AUTOPLAY      "NoDriveTypeAutoRun" 0x91
    Remove-RegValue $REG_AUTOPLAY   "NoDriveAutoRun"
    Set-RegDWord $REG_AUTOPLAY_USER "NoDriveTypeAutoRun" 0x91
    Remove-RegValue $REG_AUTOPLAY_USER "NoDriveAutoRun"
    Remove-RegValue $REG_AUTORUN_POLICY "NoAutoplayfornonVolume"
    try {
        Set-Service  "ShellHWDetection" -StartupType Automatic -EA SilentlyContinue
        Start-Service "ShellHWDetection" -EA SilentlyContinue
        Write-Log "L4: ShellHWDetection re-enabled" "SUCCESS"
    } catch { $null = $_ }  # service may already be running; not a fatal condition
    Write-Log "L4: AutoPlay restored to defaults" "SUCCESS"
}

# ─────────────────────────────────────────────────────────────────────────────
#  LAYER 5 — VolumeWatcher + Notification
# ─────────────────────────────────────────────────────────────────────────────
function Get-NotifyConfig {
    Ensure-RegPath $REG_USBGUARD_CFG
    $cfg = Get-ItemProperty $REG_USBGUARD_CFG -EA SilentlyContinue
    return @{
        CompanyName = if ($cfg.CompanyName)   { $cfg.CompanyName }   else { "IT Security" }
        Title       = if ($cfg.NotifyTitle)   { $cfg.NotifyTitle }   else { "USB Device Blocked" }
        Message     = if ($cfg.NotifyMessage) { $cfg.NotifyMessage } else { "USB storage and phone data access is disabled by {COMPANY} policy. Charging is unaffected. Contact IT support if you need temporary access." }
    }
}

function Save-NotifyConfig { param([string]$Company,[string]$Message)
    Ensure-RegPath $REG_USBGUARD_CFG
    if ($Company) {
        $Company = $Company.Trim() -replace '[\x00-\x1F\x7F]',''
        if ($Company.Length -gt 100) { $Company = $Company.Substring(0, 100) }
        Set-ItemProperty $REG_USBGUARD_CFG -Name "CompanyName"   -Value $Company -Type String
    }
    if ($Message) {
        $Message = $Message.Trim() -replace '[\x00-\x1F\x7F]',''
        if ($Message.Length -gt 500) { $Message = $Message.Substring(0, 500) }
        Set-ItemProperty $REG_USBGUARD_CFG -Name "NotifyMessage" -Value $Message -Type String
    }
    Write-Log "Notification config saved" "SUCCESS"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Allowlist — trusted USB devices exempt from auto-eject
# ─────────────────────────────────────────────────────────────────────────────
function Add-AllowlistEntry {
    param([string]$Id)
    if (-not $Id) { Write-Log "DeviceId required" "ERROR"; return }
    if ($Id.Length -lt 20 -or $Id -notmatch '&VEN_|&PROD_') {
        Write-Log "Allowlist: Device ID too broad. Include at least VEN_ and PROD_ identifiers for security (got: $Id)" "WARN"
    }
    Ensure-RegPath $REG_ALLOWLIST
    $props = (Get-Item $REG_ALLOWLIST -EA SilentlyContinue).Property
    foreach ($p in $props) {
        if ((Get-ItemProperty $REG_ALLOWLIST -Name $p -EA SilentlyContinue).$p -eq $Id) {
            Write-Log "Device already in allowlist: $Id" "INFO"; return
        }
    }
    $next = 1
    if ($props) { $next = (($props | ForEach-Object { try { [int]$_ } catch { 0 } } | Measure-Object -Maximum).Maximum) + 1 }
    Set-ItemProperty $REG_ALLOWLIST -Name "$next" -Value $Id -Type String -Force
    Write-Log "Allowlist: added $Id" "SUCCESS"
    Write-AuditEntry -Action "allowlist-add" -Detail $Id
}

function Remove-AllowlistEntry {
    param([string]$Id)
    if (-not (Test-Path $REG_ALLOWLIST)) { Write-Log "Allowlist is empty" "INFO"; return }
    $props = (Get-Item $REG_ALLOWLIST -EA SilentlyContinue).Property
    $removed = $false
    foreach ($p in $props) {
        if ((Get-ItemProperty $REG_ALLOWLIST -Name $p -EA SilentlyContinue).$p -eq $Id) {
            Remove-ItemProperty $REG_ALLOWLIST -Name $p -EA SilentlyContinue
            $removed = $true
        }
    }
    if ($removed) { Write-Log "Allowlist: removed $Id" "SUCCESS"; Write-AuditEntry -Action "allowlist-remove" -Detail $Id }
    else { Write-Log "Device not found in allowlist: $Id" "WARN" }
}

function Get-AllowlistEntries {
    if (-not (Test-Path $REG_ALLOWLIST)) { return @() }
    $props = (Get-Item $REG_ALLOWLIST -EA SilentlyContinue).Property
    if (-not $props) { return @() }
    return @($props | ForEach-Object {
        $v = (Get-ItemProperty $REG_ALLOWLIST -Name $_ -EA SilentlyContinue).$_
        if ($v) { $v }
    })
}

function Write-NotifyScript {
    $cfg     = Get-NotifyConfig
    $title   = ($cfg.Title   -replace '`','``' -replace '"','`"' -replace '\$','`$')
    $msgRaw  = ($cfg.Message -replace '\{COMPANY\}', $cfg.CompanyName)
    $msgEsc  = ($msgRaw -replace '`','``' -replace '"','`"' -replace '\$','`$')
    $content = @"
param([string]`$Title = "$title", [string]`$Message = "$msgEsc")
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    `$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    `$xml.LoadXml('<toast duration="long"><visual><binding template="ToastGeneric"><text>' + [System.Security.SecurityElement]::Escape(`$Title) + '</text><text>' + [System.Security.SecurityElement]::Escape(`$Message) + '</text></binding></visual><audio src="ms-winsoundevent:Notification.Looping.Alarm2" loop="false"/></toast>')
    `$toast = [Windows.UI.Notifications.ToastNotification]::new(`$xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("USBGuard").Show(`$toast)
    Start-Sleep -Seconds 3
} catch {
    try { (New-Object -ComObject WScript.Shell).Popup("`$Message", 15, "`$Title", 48) | Out-Null } catch {}
}
"@
    Set-Content -Path $NOTIFY_SCRIPT -Value $content -Encoding UTF8
}

function Write-WatcherScript {
    $content = @'
# USBGuard VolumeWatcher v4 — SYSTEM scheduled task
$logFile      = "$env:ProgramData\USBGuard\watcher.log"
$notifyScript = "$env:ProgramData\USBGuard\Notify.ps1"
$allowlistReg = 'HKLM:\SOFTWARE\USBGuard\Allowlist'

function Log { param([string]$m)
    "[$( (Get-Date -Format 'HH:mm:ss') )] $m" | Add-Content $logFile -Encoding UTF8 -EA SilentlyContinue
}

function Get-AllowlistEntries_W {
    if (-not (Test-Path $allowlistReg)) { return @() }
    $props = (Get-Item $allowlistReg -EA SilentlyContinue).Property
    if (-not $props) { return @() }
    return @($props | ForEach-Object { (Get-ItemProperty $allowlistReg -Name $_ -EA SilentlyContinue).$_ })
}

function Get-UsbDiskPnpId_W {
    param([string]$DriveLetter)
    $dl = $DriveLetter.TrimEnd(':')
    try {
        $parts = Get-WmiObject -Query "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='${dl}:'} WHERE AssocClass=Win32_LogicalDiskToPartition" -EA SilentlyContinue
        foreach ($part in $parts) {
            $disks = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($part.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition" -EA SilentlyContinue
            foreach ($disk in $disks) {
                if ($disk.PNPDeviceID) { return $disk.PNPDeviceID }
            }
        }
    } catch { Log "PNP lookup error: $_" }
    return $null
}

function Test-AllowlistMatch_W {
    param([string]$DriveLetter)
    $entries = Get-AllowlistEntries_W
    if (-not $entries -or $entries.Count -eq 0) { return $false }
    $pnpId = Get-UsbDiskPnpId_W $DriveLetter
    if (-not $pnpId) { return $false }
    $upper = $pnpId.ToUpper()
    foreach ($e in $entries) {
        if ($upper -like "$($e.ToUpper())*") { return $true }
    }
    return $false
}

function Notify-User {
    try {
        $activeUser = $null
        $sessions = query session 2>$null
        foreach ($line in $sessions) {
            if ($line -match 'Active') {
                $parts = ($line -replace '\s+', ' ').Trim().Split(' ')
                foreach ($p in $parts) {
                    if ($p -and $p -notmatch '^(Active|Disc|\d+|console|rdp.*)$' -and $p.Length -gt 1) {
                        $activeUser = $p; break
                    }
                }
                if ($activeUser) { break }
            }
        }
        $psExe  = "powershell.exe"
        $psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$notifyScript`""
        $taskName = "USBGuard_Toast_$(Get-Random -Maximum 99999)"
        if ($activeUser -and $activeUser -match '^[A-Za-z0-9_\-\.\\@]{1,104}$') {
            schtasks /create /tn "$taskName" /tr "$psExe $psArgs" /sc once /st 00:00 /ru "$activeUser" /f /RL LIMITED 2>&1 | Out-Null
            schtasks /run    /tn "$taskName" 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            schtasks /delete /tn "$taskName" /f 2>&1 | Out-Null
            Log "Toast dispatched to: $activeUser"
        } else {
            $cfg = Get-Content "$env:ProgramData\USBGuard\msg.txt" -EA SilentlyContinue
            msg console /TIME:20 "$cfg" 2>&1 | Out-Null
        }
    } catch { Log "Notification error: $_" }
}

function Dismount-Volume { param([string]$DriveLetter, [string]$Label)
    try {
        $vol = Get-WmiObject -Query "SELECT * FROM Win32_Volume WHERE DriveLetter = '${DriveLetter}:'" -EA Stop
        if ($vol) {
            $r = $vol.Dismount($true, $false)
            if ($r.ReturnValue -eq 0) { Log "Dismounted: $DriveLetter ($Label)"; return }
        }
    } catch { Log "WMI dismount error ${DriveLetter}: $_" }
    try {
        $sh = New-Object -ComObject Shell.Application
        $sh.Namespace(17).ParseName("${DriveLetter}:").InvokeVerb("Eject")
        Log "Shell eject sent: $DriveLetter"
    } catch { Log "Shell eject failed ${DriveLetter}: $_" }
}

Log "VolumeWatcher v4 started (PID $PID)"
$wql = "SELECT * FROM __InstanceCreationEvent WITHIN 0.25 WHERE TargetInstance ISA 'Win32_Volume' AND TargetInstance.DriveType = 2"
try { Register-WmiEvent -Query $wql -SourceIdentifier "USBGuardVol" -EA Stop; Log "WMI subscription active" }
catch { Log "FATAL: WMI failed: $_"; exit 1 }

while ($true) {
    $e = Wait-Event -SourceIdentifier "USBGuardVol" -Timeout 60
    if ($e) {
        try {
            $vol = $e.SourceEventArgs.NewEvent.TargetInstance
            $dl  = $vol.DriveLetter; $label = $vol.Label
            Log "New removable volume: $dl label='$label'"
            if (Test-AllowlistMatch_W $dl) {
                Log "Allowlisted device on $dl ($label) - access permitted"
            } else {
                Notify-User
                Start-Sleep -Milliseconds 500
                Dismount-Volume -DriveLetter $dl -Label $label
            }
        } catch { Log "Event error: $_" }
        Remove-Event      -SourceIdentifier "USBGuardVol" -EA SilentlyContinue
        try {
            Register-WmiEvent -Query $wql -SourceIdentifier "USBGuardVol" -EA Stop
        } catch {
            Log "FATAL: WMI re-subscription failed: $_ — exiting for task restart"
            exit 1
        }
    }
    Log "Watcher alive"
}
'@
    Set-Content -Path $WATCHER_SCRIPT -Value $content -Encoding UTF8
}

function Install-VolumeWatcher {
    Write-Log "L5: Installing volume watcher..."
    if (-not (Test-Path $USBGUARD_DIR)) { New-Item $USBGUARD_DIR -ItemType Directory -Force | Out-Null }
    Write-WatcherScript
    Write-NotifyScript
    $cfg = Get-NotifyConfig
    ($cfg.Message -replace '\{COMPANY\}', $cfg.CompanyName) | Set-Content "$USBGUARD_DIR\msg.txt" -Encoding UTF8

    $psArgs   = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WATCHER_SCRIPT`""
    $action   = New-ScheduledTaskAction  -Execute "powershell.exe" -Argument $psArgs
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
                    -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) `
                    -StartWhenAvailable -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Unregister-ScheduledTask -TaskName $WATCHER_TASK_NAME -Confirm:$false -EA SilentlyContinue
    Register-ScheduledTask -TaskName $WATCHER_TASK_NAME `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "USBGuard: auto-ejects removable storage and notifies user" -Force | Out-Null
    Start-ScheduledTask -TaskName $WATCHER_TASK_NAME -EA SilentlyContinue
    Write-Log "L5: VolumeWatcher task installed and started" "SUCCESS"
}

function Remove-VolumeWatcher {
    Stop-ScheduledTask       -TaskName $WATCHER_TASK_NAME -EA SilentlyContinue
    Unregister-ScheduledTask -TaskName $WATCHER_TASK_NAME -Confirm:$false -EA SilentlyContinue
    foreach ($f in @($WATCHER_SCRIPT, $NOTIFY_SCRIPT, "$USBGUARD_DIR\msg.txt")) {
        if (Test-Path $f) { Remove-Item $f -Force -EA SilentlyContinue }
    }
    Write-Log "L5: VolumeWatcher removed" "SUCCESS"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Tamper Detection — periodic check every 5 min, re-applies if reverted
# ─────────────────────────────────────────────────────────────────────────────
function Write-TamperScript {
    $content = @'
# USBGuard TamperDetect — runs every 5 minutes as SYSTEM
$logFile  = "$env:ProgramData\USBGuard\tamper.log"
$audLog   = "$env:ProgramData\USBGuard\audit.log"
$tampered = $false

function TLog { param([string]$m)
    $ts = Get-Date -Format "HH:mm:ss"
    "[$ts] $m" | Add-Content $logFile -Encoding UTF8 -EA SilentlyContinue
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ACTION=TAMPER_DETECTED USER=$user $m" | Add-Content $audLog -Encoding UTF8 -EA SilentlyContinue
}

# L1: USBSTOR Start must be 4
$v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name 'Start' -EA SilentlyContinue).Start
if ($null -ne $v -and $v -ne 4) {
    TLog "TAMPER L1: USBSTOR Start=$v expected 4 - restoring"
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name 'Start' -Value 4 -Type DWord -Force
    $tampered = $true
}

# L2: WriteProtect must be 1
$v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies' -Name 'WriteProtect' -EA SilentlyContinue).WriteProtect
if ($null -ne $v -and $v -ne 1) {
    TLog "TAMPER L2: WriteProtect=$v expected 1 - restoring"
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies' -Name 'WriteProtect' -Value 1 -Type DWord -Force
    $tampered = $true
}

# L7: WpdFilesystemDriver Start must be 4
$v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver' -Name 'Start' -EA SilentlyContinue).Start
if ($null -ne $v -and $v -ne 4) {
    TLog "TAMPER L7: WpdFilesystemDriver Start=$v expected 4 - restoring"
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WpdFilesystemDriver' -Name 'Start' -Value 4 -Type DWord -Force
    $tampered = $true
}

# L5: VolumeWatcher watchdog — restart if stopped
try {
    $watcherTask = Get-ScheduledTask -TaskName 'USBGuard_VolumeWatcher' -EA SilentlyContinue
    if ($watcherTask) {
        if ($watcherTask.State -ne 'Running' -and $watcherTask.State -ne 'Ready') {
            TLog "TAMPER L5: VolumeWatcher task state=$($watcherTask.State) - restarting"
            Start-ScheduledTask -TaskName 'USBGuard_VolumeWatcher' -EA SilentlyContinue
            $tampered = $true
        }
    }
} catch {}

if ($tampered) {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists('USBGuard')) {
            [System.Diagnostics.EventLog]::CreateEventSource('USBGuard', 'Application')
        }
        Write-EventLog -LogName Application -Source 'USBGuard' -EventId 1009 -EntryType Warning -Message 'USBGuard: Registry tampering detected - policy re-applied.'
    } catch {}
    TLog "TAMPER REMEDIATED"
} else {
    "[$( (Get-Date -Format 'HH:mm:ss') )] OK - policy intact" | Add-Content $logFile -Encoding UTF8 -EA SilentlyContinue
}
'@
    Set-Content -Path $TAMPER_SCRIPT -Value $content -Encoding UTF8
}

function Install-TamperDetection {
    Write-Log "Installing tamper detection (every 5 min)..." "INFO"
    if (-not (Test-Path $USBGUARD_DIR)) { New-Item $USBGUARD_DIR -ItemType Directory -Force | Out-Null }
    Write-TamperScript
    $psArgs    = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$TAMPER_SCRIPT`""
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
    $trigger   = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date) -RepetitionDuration ([TimeSpan]::MaxValue)
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -StartWhenAvailable -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Unregister-ScheduledTask -TaskName $TAMPER_TASK_NAME -Confirm:$false -EA SilentlyContinue
    Register-ScheduledTask -TaskName $TAMPER_TASK_NAME `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "USBGuard: Detects and remediates USB policy tampering every 5 minutes" -Force | Out-Null
    Start-ScheduledTask -TaskName $TAMPER_TASK_NAME -EA SilentlyContinue
    Write-Log "Tamper detection installed and started" "SUCCESS"
    Write-AuditEntry -Action "install-tamper-detection"
}

function Remove-TamperDetection {
    Stop-ScheduledTask       -TaskName $TAMPER_TASK_NAME -EA SilentlyContinue
    Unregister-ScheduledTask -TaskName $TAMPER_TASK_NAME -Confirm:$false -EA SilentlyContinue
    if (Test-Path $TAMPER_SCRIPT) { Remove-Item $TAMPER_SCRIPT -Force -EA SilentlyContinue }
    Write-Log "Tamper detection removed" "SUCCESS"
    Write-AuditEntry -Action "remove-tamper-detection"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Eject currently mounted removable volumes
# ─────────────────────────────────────────────────────────────────────────────
function Eject-AllRemovableVolumes {
    $vols = Get-WmiObject Win32_Volume -Filter "DriveType=2" -EA SilentlyContinue
    if (-not $vols) { Write-Log "No removable volumes mounted" "INFO"; return }
    foreach ($v in $vols) {
        try {
            $r = $v.Dismount($true, $false)
            if ($r.ReturnValue -eq 0) { Write-Log "Ejected: $($v.DriveLetter) ($($v.Label))" "SUCCESS" }
            else {
                try {
                    $sh = New-Object -ComObject Shell.Application
                    $sh.Namespace(17).ParseName("$($v.DriveLetter):").InvokeVerb("Eject")
                } catch { $null = $_ }  # Shell.Application fallback; ignore if unavailable
            }
        } catch { Write-Log "Eject error $($v.DriveLetter): $_" "WARN" }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  Printers
# ─────────────────────────────────────────────────────────────────────────────
function Block-UsbPrinters {
    Ensure-RegPath $REG_DENY_BASE
    Set-RegDWord $REG_DENY_BASE "DenyDeviceClasses"            1
    Set-RegDWord $REG_DENY_BASE "DenyDeviceClassesRetroactive" 1
    Ensure-RegPath $REG_DENY_CLASSES
    Add-GuidToDenyList $GUID_PRINTER
    $cp = "$REG_CLASS_BASE\$GUID_PRINTER"
    if (Test-Path $cp) { Set-RegDWord $cp "DenyInstall" 1 }
    Write-Log "USB Printers blocked" "SUCCESS"
}

function Unblock-UsbPrinters {
    Remove-GuidFromDenyList $GUID_PRINTER
    $cp = "$REG_CLASS_BASE\$GUID_PRINTER"
    if (Test-Path $cp) { Remove-RegValue $cp "DenyInstall" }
    $rem = (Get-Item $REG_DENY_CLASSES -EA SilentlyContinue).Property
    if (-not $rem) {
        Set-RegDWord $REG_DENY_BASE "DenyDeviceClasses"            0
        Set-RegDWord $REG_DENY_BASE "DenyDeviceClassesRetroactive" 0
    }
    Write-Log "USB Printers unblocked" "SUCCESS"
}

# ─────────────────────────────────────────────────────────────────────────────
#  LAYER 8 — SD Card Reader (internal PCIe/SDIO)
# ─────────────────────────────────────────────────────────────────────────────
function Block-SdCard {
    if (Test-Path $REG_SDBUS) {
        Save-OriginalStart $REG_SDBUS
        Set-RegDWord $REG_SDBUS "Start" 4
        Write-Log "L8: SD card reader blocked (sdbus Start=4)" "SUCCESS"
    } else { Write-Log "L8: sdbus service not present (no SD reader)" "INFO" }
}
function Unblock-SdCard {
    if (Test-Path $REG_SDBUS) {
        $restore = Get-SavedStart $REG_SDBUS
        $startVal = if ($null -ne $restore) { $restore } else { 3 }
        Set-RegDWord $REG_SDBUS "Start" $startVal
        Write-Log "L8: SD card reader restored (Start=$startVal)" "SUCCESS"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  LAYER 9 — Bluetooth File Transfer (OBEX/RFCOMM)
# ─────────────────────────────────────────────────────────────────────────────
function Block-BluetoothFileTransfer {
    Write-Log "L9: Blocking Bluetooth file transfer (OBEX/RFCOMM)..." "INFO"
    foreach ($svc in @($REG_BT_OBEX, $REG_BT_RFCOMM)) {
        if (Test-Path $svc) {
            Save-OriginalStart $svc
            Set-RegDWord $svc "Start" 4
            $name = Split-Path $svc -Leaf
            Write-Log "L9: $name disabled (Start=4)" "SUCCESS"
        }
    }
    Add-GuidToDenyList $GUID_BT_OBEX
    Write-Log "L9: Bluetooth OBEX GUID added to deny list" "SUCCESS"
    Write-Log "L9: Bluetooth file transfer blocked. BT audio/HID unaffected." "SUCCESS"
}
function Unblock-BluetoothFileTransfer {
    foreach ($svc in @($REG_BT_OBEX, $REG_BT_RFCOMM)) {
        if (Test-Path $svc) {
            $name    = Split-Path $svc -Leaf
            $restore = Get-SavedStart $svc
            $startVal = if ($null -ne $restore) { $restore } else { 3 }
            Set-RegDWord $svc "Start" $startVal
            Write-Log "L9: $name restored (Start=$startVal)" "SUCCESS"
        }
    }
    Remove-GuidFromDenyList $GUID_BT_OBEX
    Write-Log "L9: Bluetooth file transfer restored" "SUCCESS"
}

# ─────────────────────────────────────────────────────────────────────────────
#  LAYER 10 — FireWire / IEEE 1394
# ─────────────────────────────────────────────────────────────────────────────
function Block-FireWire {
    if (Test-Path $REG_FIREWIRE) {
        Save-OriginalStart $REG_FIREWIRE
        Set-RegDWord $REG_FIREWIRE "Start" 4
        Write-Log "L10: FireWire blocked (1394ohci Start=4)" "SUCCESS"
    } else { Write-Log "L10: 1394ohci service not present (no FireWire)" "INFO" }
}
function Unblock-FireWire {
    if (Test-Path $REG_FIREWIRE) {
        $restore = Get-SavedStart $REG_FIREWIRE
        $startVal = if ($null -ne $restore) { $restore } else { 3 }
        Set-RegDWord $REG_FIREWIRE "Start" $startVal
        Write-Log "L10: FireWire restored (Start=$startVal)" "SUCCESS"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  Status
# ─────────────────────────────────────────────────────────────────────────────
function Get-Status {
    $s = [ordered]@{
        UsbStorage      = "unknown"
        WriteProtect    = "unknown"
        AutoPlayKilled  = "unknown"
        VolumeWatcher   = "unknown"
        Thunderbolt     = "unknown"
        MtpPtp          = "unknown"
        UsbPrinters     = "unknown"
        SdCard          = "unknown"
        BluetoothFT     = "unknown"
        FireWire        = "unknown"
        TamperDetection = "unknown"
        AllowlistCount  = 0
        CompanyName     = (Get-NotifyConfig).CompanyName
        Timestamp       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    if (Test-Path $REG_USBSTOR) {
        $v = (Get-ItemProperty $REG_USBSTOR -Name "Start" -EA SilentlyContinue).Start
        $s.UsbStorage = if ($v -eq 4) { "blocked" } else { "allowed" }
    }
    if (Test-Path $REG_STORAGE_POLICY) {
        $v = (Get-ItemProperty $REG_STORAGE_POLICY -Name "WriteProtect" -EA SilentlyContinue).WriteProtect
        $s.WriteProtect = if ($v -eq 1) { "active" } else { "inactive" }
    } else { $s.WriteProtect = "inactive" }

    if (Test-Path $REG_AUTOPLAY) {
        $v = (Get-ItemProperty $REG_AUTOPLAY -Name "NoDriveTypeAutoRun" -EA SilentlyContinue).NoDriveTypeAutoRun
        $s.AutoPlayKilled = if ($v -eq 0xFF) { "disabled" } else { "enabled" }
    } else { $s.AutoPlayKilled = "enabled" }

    $task = Get-ScheduledTask -TaskName $WATCHER_TASK_NAME -EA SilentlyContinue
    $s.VolumeWatcher = if ($task) { $task.State.ToString().ToLower() } else { "not_installed" }

    if (Test-Path $REG_THUNDERBOLT) {
        $v = (Get-ItemProperty $REG_THUNDERBOLT -Name "Start" -EA SilentlyContinue).Start
        $s.Thunderbolt = if ($v -eq 4) { "blocked" } else { "allowed" }
    } else { $s.Thunderbolt = "not_present" }

    $s.MtpPtp = Get-WpdStatus

    # L8: SD Card
    if (Test-Path $REG_SDBUS) {
        $v = (Get-ItemProperty $REG_SDBUS -Name "Start" -EA SilentlyContinue).Start
        $s.SdCard = if ($v -eq 4) { "blocked" } else { "allowed" }
    } else { $s.SdCard = "not_present" }

    # L9: Bluetooth File Transfer
    $btBlocked = $false
    foreach ($svc in @($REG_BT_OBEX, $REG_BT_RFCOMM)) {
        if (Test-Path $svc) {
            $v = (Get-ItemProperty $svc -Name "Start" -EA SilentlyContinue).Start
            if ($v -eq 4) { $btBlocked = $true }
        }
    }
    $s.BluetoothFT = if ($btBlocked) { "blocked" } else { "allowed" }

    # L10: FireWire
    if (Test-Path $REG_FIREWIRE) {
        $v = (Get-ItemProperty $REG_FIREWIRE -Name "Start" -EA SilentlyContinue).Start
        $s.FireWire = if ($v -eq 4) { "blocked" } else { "allowed" }
    } else { $s.FireWire = "not_present" }

    $pb = $false
    if (Test-Path $REG_DENY_CLASSES) {
        foreach ($k in (Get-Item $REG_DENY_CLASSES -EA SilentlyContinue).Property) {
            if ((Get-ItemProperty $REG_DENY_CLASSES -Name $k -EA SilentlyContinue).$k -eq $GUID_PRINTER) { $pb = $true; break }
        }
    }
    $cp = "$REG_CLASS_BASE\$GUID_PRINTER"
    if ((Test-Path $cp) -and (Get-ItemProperty $cp -Name "DenyInstall" -EA SilentlyContinue).DenyInstall -eq 1) { $pb = $true }
    $s.UsbPrinters = if ($pb) { "blocked" } else { "allowed" }

    $tamperTask = Get-ScheduledTask -TaskName $TAMPER_TASK_NAME -EA SilentlyContinue
    $s.TamperDetection = if ($tamperTask) { $tamperTask.State.ToString().ToLower() } else { "not_installed" }

    $s.AllowlistCount = (Get-AllowlistEntries).Count

    return $s
}

# ─────────────────────────────────────────────────────────────────────────────
#  Main dispatch
# ─────────────────────────────────────────────────────────────────────────────
switch ($Action) {

    "status" {
        $s = Get-Status
        $json = $s | ConvertTo-Json
        Write-Host $json
        if ($OutputFile) { Set-Content $OutputFile $json -Encoding UTF8 }
    }

    "block" {
        Write-Log "=== FULL BLOCK (10 layers + notification) ===" "INFO"
        Block-StorageRegistry
        Disable-AutoPlay
        Install-VolumeWatcher
        Block-UsbPrinters
        Block-WpdMtp
        Block-SdCard
        Block-BluetoothFileTransfer
        Block-FireWire
        Write-Log "=== ALL LAYERS ACTIVE ===" "SUCCESS"
        Write-Log "Blocked: USB drives, Thunderbolt, MTP (Android), PTP (iPhone/cameras), Printers, SD cards, BT file transfer, FireWire" "INFO"
        Write-Log "Preserved: Keyboards, mice, USB audio, BT audio/HID, charging" "INFO"
        Write-AuditEntry -Action "block" -Detail "All 10 layers applied"
        Write-EventLogEntry -Message "USBGuard: Full block applied - all 10 layers active." -EventId 1001
    }

    "unblock" {
        Write-Log "=== FULL UNBLOCK ===" "INFO"
        Unblock-StorageRegistry
        Enable-AutoPlay
        Remove-VolumeWatcher
        Unblock-UsbPrinters
        Unblock-WpdMtp
        Unblock-SdCard
        Unblock-BluetoothFileTransfer
        Unblock-FireWire
        Write-Log "=== USB ACCESS FULLY RESTORED ===" "SUCCESS"
        Write-AuditEntry -Action "unblock" -Detail "All layers removed"
        Write-EventLogEntry -Message "USBGuard: Full unblock applied - USB access restored." -EventId 1002
    }

    "block-storage" {
        Block-StorageRegistry; Disable-AutoPlay; Install-VolumeWatcher
        Write-Log "USB Storage blocked" "SUCCESS"
        Write-AuditEntry -Action "block-storage"
        Write-EventLogEntry -Message "USBGuard: USB mass storage blocked (L1-L4, L6)." -EventId 1003
    }
    "unblock-storage" {
        Unblock-StorageRegistry; Enable-AutoPlay; Remove-VolumeWatcher
        Write-Log "USB Storage allowed" "SUCCESS"
        Write-AuditEntry -Action "unblock-storage"
        Write-EventLogEntry -Message "USBGuard: USB mass storage unblocked." -EventId 1004
    }

    "block-phones" {
        Block-WpdMtp
        Write-Log "MTP/PTP (phones/cameras) blocked" "SUCCESS"
        Write-AuditEntry -Action "block-phones"
        Write-EventLogEntry -Message "USBGuard: MTP/PTP stack blocked (Android, iPhone, cameras)." -EventId 1005
    }
    "unblock-phones" {
        Unblock-WpdMtp
        Write-Log "MTP/PTP (phones/cameras) allowed" "SUCCESS"
        Write-AuditEntry -Action "unblock-phones"
        Write-EventLogEntry -Message "USBGuard: MTP/PTP stack unblocked." -EventId 1006
    }

    "block-printers" {
        Block-UsbPrinters
        Write-AuditEntry -Action "block-printers"
        Write-EventLogEntry -Message "USBGuard: USB printers blocked." -EventId 1007
    }
    "unblock-printers" {
        Unblock-UsbPrinters
        Write-AuditEntry -Action "unblock-printers"
        Write-EventLogEntry -Message "USBGuard: USB printers unblocked." -EventId 1008
    }

    "block-sdcard" {
        Block-SdCard
        Write-AuditEntry -Action "block-sdcard"
        Write-EventLogEntry -Message "USBGuard: SD card reader blocked (L8)." -EventId 1010
    }
    "unblock-sdcard" {
        Unblock-SdCard
        Write-AuditEntry -Action "unblock-sdcard"
        Write-EventLogEntry -Message "USBGuard: SD card reader unblocked." -EventId 1011
    }

    "block-bluetooth" {
        Block-BluetoothFileTransfer
        Write-AuditEntry -Action "block-bluetooth"
        Write-EventLogEntry -Message "USBGuard: Bluetooth file transfer blocked (L9)." -EventId 1012
    }
    "unblock-bluetooth" {
        Unblock-BluetoothFileTransfer
        Write-AuditEntry -Action "unblock-bluetooth"
        Write-EventLogEntry -Message "USBGuard: Bluetooth file transfer unblocked." -EventId 1013
    }

    "block-firewire" {
        Block-FireWire
        Write-AuditEntry -Action "block-firewire"
        Write-EventLogEntry -Message "USBGuard: FireWire blocked (L10)." -EventId 1014
    }
    "unblock-firewire" {
        Unblock-FireWire
        Write-AuditEntry -Action "unblock-firewire"
        Write-EventLogEntry -Message "USBGuard: FireWire unblocked." -EventId 1015
    }

    "install-watcher"  { Install-VolumeWatcher }
    "remove-watcher"   { Remove-VolumeWatcher  }

    "set-notify-config" {
        Save-NotifyConfig -Company $CompanyName -Message $NotifyMessage
        if (Test-Path $NOTIFY_SCRIPT) { Write-NotifyScript }
        if (Test-Path "$USBGUARD_DIR\msg.txt") {
            $cfg = Get-NotifyConfig
            ($cfg.Message -replace '\{COMPANY\}', $cfg.CompanyName) | Set-Content "$USBGUARD_DIR\msg.txt" -Encoding UTF8
        }
    }

    "add-allowlist"    { Add-AllowlistEntry    -Id $DeviceId }
    "remove-allowlist" { Remove-AllowlistEntry -Id $DeviceId }
    "list-allowlist"   {
        $entries = Get-AllowlistEntries
        $json = $entries | ConvertTo-Json
        Write-Host $json
        if ($OutputFile) { Set-Content $OutputFile $json -Encoding UTF8 }
    }

    "install-tamper-detection" { Install-TamperDetection }
    "remove-tamper-detection"  { Remove-TamperDetection  }
}
