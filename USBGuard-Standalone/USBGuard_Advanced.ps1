#Requires -RunAsAdministrator
<#
.SYNOPSIS
    USBGuard Advanced - Additional device enumeration and management
    Lists currently connected USB storage and printer devices
#>

param(
    [ValidateSet("list-devices","block-connected","unblock-connected","export-policy","import-policy")]
    [string]$Action = "list-devices",
    [string]$PolicyFile = "usbguard_policy.json"
)

# ── List all relevant connected USB devices ───────────────────────────────────
function Get-UsbDevices {
    Write-Host "`n[USB MASS STORAGE DEVICES]" -ForegroundColor Cyan
    Write-Host ("-" * 60)
    
    $diskDrives = Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceType -eq "USB" -or $_.PNPDeviceID -like "USBSTOR*" }
    
    if ($diskDrives) {
        foreach ($d in $diskDrives) {
            $size = if ($d.Size) { [math]::Round($d.Size / 1GB, 1) } else { "?" }
            Write-Host "  Device : $($d.Caption)" -ForegroundColor White
            Write-Host "  PNP ID : $($d.PNPDeviceID)"
            Write-Host "  Size   : $size GB"
            Write-Host "  Status : $($d.Status)`n"
        }
    } else {
        Write-Host "  No USB mass storage devices currently connected." -ForegroundColor DarkGray
    }
    
    Write-Host "`n[THUNDERBOLT / USB4 DEVICES]" -ForegroundColor Cyan
    Write-Host ("-" * 60)
    
    $tbDevices = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -like "*THUNDERBOLT*" -or $_.Name -like "*Thunderbolt*" }
    
    if ($tbDevices) {
        foreach ($d in $tbDevices) {
            Write-Host "  Device : $($d.Name)" -ForegroundColor White
            Write-Host "  PNP ID : $($d.PNPDeviceID)`n"
        }
    } else {
        Write-Host "  No Thunderbolt devices currently detected." -ForegroundColor DarkGray
    }
    
    Write-Host "`n[USB PRINTERS]" -ForegroundColor Cyan
    Write-Host ("-" * 60)
    
    $printers = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue |
        Where-Object { $_.PortName -like "USB*" -or $_.Name -like "*USB*" }
    
    if ($printers) {
        foreach ($p in $printers) {
            Write-Host "  Printer: $($p.Name)" -ForegroundColor White
            Write-Host "  Port   : $($p.PortName)"
            Write-Host "  Status : $($p.PrinterStatus)`n"
        }
    } else {
        Write-Host "  No USB printers currently detected." -ForegroundColor DarkGray
    }
    
    Write-Host "`n[EXCLUDED - INTERNAL DRIVES (Not affected by USBGuard)]" -ForegroundColor Yellow
    Write-Host ("-" * 60)
    
    $internalDrives = Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceType -ne "USB" }
    
    foreach ($d in $internalDrives) {
        $size = if ($d.Size) { [math]::Round($d.Size / 1GB, 1) } else { "?" }
        Write-Host "  Drive  : $($d.Caption) [$($d.InterfaceType)] - ${size}GB" -ForegroundColor DarkGray
    }
}

function Export-Policy {
    param([string]$File)
    
    $policy = @{
        ExportDate       = (Get-Date -Format "o")
        UsbStorageStart  = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -ErrorAction SilentlyContinue).Start
        ThunderboltStart = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\thunderbolt" -Name "Start" -ErrorAction SilentlyContinue).Start
        PrinterDenyList  = @()
    }
    
    $denyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceClasses"
    if (Test-Path $denyPath) {
        $keys = (Get-Item $denyPath).Property
        foreach ($k in $keys) {
            $v = (Get-ItemProperty $denyPath -Name $k -ErrorAction SilentlyContinue).$k
            $policy.PrinterDenyList += $v
        }
    }
    
    $policy | ConvertTo-Json | Set-Content -Path $File -Encoding UTF8
    Write-Host "Policy exported to: $File" -ForegroundColor Green
}

switch ($Action) {
    "list-devices"       { Get-UsbDevices }
    "export-policy"      { Export-Policy -File $PolicyFile }
}
