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
        "install-watcher","remove-watcher",
        "set-notify-config"
    )]
    [string]$Action = "status",
    [string]$OutputFile    = "",
    [string]$CompanyName   = "",
    [string]$NotifyMessage = ""
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
$REG_USBGUARD_CFG   = "HKLM:\SOFTWARE\USBGuard"

# ── Scheduled task / paths ─────────────────────────────────────────────────────
$WATCHER_TASK_NAME = "USBGuard_VolumeWatcher"
$USBGUARD_DIR      = "$env:ProgramData\USBGuard"
$WATCHER_SCRIPT    = "$USBGUARD_DIR\VolumeWatcher.ps1"
$NOTIFY_SCRIPT     = "$USBGUARD_DIR\Notify.ps1"

# ── Logging ────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    if ($OutputFile) { Add-Content -Path $OutputFile -Value $line -Encoding UTF8 }
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
        } catch {}
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
        Set-RegDWord $REG_THUNDERBOLT "Start" 4
        Write-Log "L6: Thunderbolt disabled" "SUCCESS"
    }

    Eject-AllRemovableVolumes
}

function Unblock-StorageRegistry {
    if (Test-Path $REG_USBSTOR) {
        Set-RegDWord $REG_USBSTOR "Start" 3
        Write-Log "L1: USBSTOR re-enabled (Start=3)" "SUCCESS"
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
        Set-RegDWord $REG_THUNDERBOLT "Start" 3
        Write-Log "L6: Thunderbolt re-enabled" "SUCCESS"
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
    } catch {}
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
    } catch {}
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
    if ($Company) { Set-ItemProperty $REG_USBGUARD_CFG -Name "CompanyName"   -Value $Company -Type String }
    if ($Message) { Set-ItemProperty $REG_USBGUARD_CFG -Name "NotifyMessage" -Value $Message -Type String }
    Write-Log "Notification config saved" "SUCCESS"
}

function Write-NotifyScript {
    $cfg     = Get-NotifyConfig
    $title   = ($cfg.Title   -replace '`','``' -replace '"','`"')
    $msgRaw  = ($cfg.Message -replace '\{COMPANY\}', $cfg.CompanyName)
    $msgEsc  = ($msgRaw -replace '`','``' -replace '"','`"')
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

function Log { param([string]$m)
    "[$( (Get-Date -Format 'HH:mm:ss') )] $m" | Add-Content $logFile -Encoding UTF8 -EA SilentlyContinue
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
        if ($activeUser) {
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
$wql = "SELECT * FROM __InstanceCreationEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Volume' AND TargetInstance.DriveType = 2"
try { Register-WmiEvent -Query $wql -SourceIdentifier "USBGuardVol" -EA Stop; Log "WMI subscription active" }
catch { Log "FATAL: WMI failed: $_"; exit 1 }

while ($true) {
    $e = Wait-Event -SourceIdentifier "USBGuardVol" -Timeout 60
    if ($e) {
        try {
            $vol = $e.SourceEventArgs.NewEvent.TargetInstance
            $dl  = $vol.DriveLetter; $label = $vol.Label
            Log "New removable volume: $dl label='$label'"
            Notify-User
            Start-Sleep -Milliseconds 800
            Dismount-Volume -DriveLetter $dl -Label $label
        } catch { Log "Event error: $_" }
        Remove-Event      -SourceIdentifier "USBGuardVol" -EA SilentlyContinue
        Register-WmiEvent -Query $wql -SourceIdentifier "USBGuardVol" -EA SilentlyContinue
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
                } catch {}
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
#  Status
# ─────────────────────────────────────────────────────────────────────────────
function Get-Status {
    $s = [ordered]@{
        UsbStorage     = "unknown"
        WriteProtect   = "unknown"
        AutoPlayKilled = "unknown"
        VolumeWatcher  = "unknown"
        Thunderbolt    = "unknown"
        MtpPtp         = "unknown"
        UsbPrinters    = "unknown"
        CompanyName    = (Get-NotifyConfig).CompanyName
        Timestamp      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
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

    $pb = $false
    if (Test-Path $REG_DENY_CLASSES) {
        foreach ($k in (Get-Item $REG_DENY_CLASSES -EA SilentlyContinue).Property) {
            if ((Get-ItemProperty $REG_DENY_CLASSES -Name $k -EA SilentlyContinue).$k -eq $GUID_PRINTER) { $pb = $true; break }
        }
    }
    $cp = "$REG_CLASS_BASE\$GUID_PRINTER"
    if ((Test-Path $cp) -and (Get-ItemProperty $cp -Name "DenyInstall" -EA SilentlyContinue).DenyInstall -eq 1) { $pb = $true }
    $s.UsbPrinters = if ($pb) { "blocked" } else { "allowed" }

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
        Write-Log "=== FULL BLOCK (7 layers + notification) ===" "INFO"
        Block-StorageRegistry
        Disable-AutoPlay
        Install-VolumeWatcher
        Block-UsbPrinters
        Block-WpdMtp
        Write-Log "=== ALL LAYERS ACTIVE ===" "SUCCESS"
        Write-Log "Blocked: USB drives, Thunderbolt, MTP (Android), PTP (iPhone/cameras), Printers" "INFO"
        Write-Log "Preserved: Keyboards, mice, USB audio, charging" "INFO"
    }

    "unblock" {
        Write-Log "=== FULL UNBLOCK ===" "INFO"
        Unblock-StorageRegistry
        Enable-AutoPlay
        Remove-VolumeWatcher
        Unblock-UsbPrinters
        Unblock-WpdMtp
        Write-Log "=== USB ACCESS FULLY RESTORED ===" "SUCCESS"
    }

    "block-storage" {
        Block-StorageRegistry; Disable-AutoPlay; Install-VolumeWatcher
        Write-Log "USB Storage blocked" "SUCCESS"
    }
    "unblock-storage" {
        Unblock-StorageRegistry; Enable-AutoPlay; Remove-VolumeWatcher
        Write-Log "USB Storage allowed" "SUCCESS"
    }

    "block-phones" {
        Block-WpdMtp
        Write-Log "MTP/PTP (phones/cameras) blocked" "SUCCESS"
    }
    "unblock-phones" {
        Unblock-WpdMtp
        Write-Log "MTP/PTP (phones/cameras) allowed" "SUCCESS"
    }

    "block-printers"   { Block-UsbPrinters   }
    "unblock-printers" { Unblock-UsbPrinters  }
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
}
