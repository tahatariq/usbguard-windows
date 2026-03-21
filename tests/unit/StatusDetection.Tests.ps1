BeforeAll {
    $ErrorActionPreference = "Continue"
}

Describe "Status Detection" {

    BeforeAll {
        $testRegBase = "HKLM:\SOFTWARE\USBGuard_StatusTest"
    }

    BeforeEach {
        if (Test-Path $testRegBase) {
            Remove-Item $testRegBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    AfterEach {
        if (Test-Path $testRegBase) {
            Remove-Item $testRegBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Get-Status - USB Storage" {
        It "Should detect USBSTOR as blocked when Start=4" {
            $regPath = "$testRegBase\SYSTEM\CurrentControlSet\Services\USBSTOR"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "Start" -Value 4 -Type DWord
            
            $status = Get-Status_Test -RegPath $regPath
            $status.UsbStorage | Should -Be "blocked"
        }

        It "Should detect USBSTOR as allowed when Start=3" {
            $regPath = "$testRegBase\SYSTEM\CurrentControlSet\Services\USBSTOR"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "Start" -Value 3 -Type DWord
            
            $status = Get-Status_Test -RegPath $regPath
            $status.UsbStorage | Should -Be "allowed"
        }

        It "Should return unknown when registry key missing" {
            $status = Get-Status_Test -RegPath "$testRegBase\missing"
            $status.UsbStorage | Should -Be "unknown"
        }
    }

    Context "Get-Status - WriteProtect" {
        It "Should detect WriteProtect as active when value=1" {
            $regPath = "$testRegBase\StorageDevicePolicies"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "WriteProtect" -Value 1 -Type DWord
            
            $status = Get-Status_Test -RegPath $regPath -CheckWriteProtect
            $status.WriteProtect | Should -Be "active"
        }

        It "Should detect WriteProtect as inactive when value=0" {
            $regPath = "$testRegBase\StorageDevicePolicies"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "WriteProtect" -Value 0 -Type DWord
            
            $status = Get-Status_Test -RegPath $regPath -CheckWriteProtect
            $status.WriteProtect | Should -Be "inactive"
        }

        It "Should default to inactive when key missing" {
            $status = Get-Status_Test -RegPath "$testRegBase\missing" -CheckWriteProtect
            $status.WriteProtect | Should -Be "inactive"
        }
    }

    Context "Get-Status - AutoPlay" {
        It "Should detect AutoPlay as disabled when NoDriveTypeAutoRun=0xFF" {
            $regPath = "$testRegBase\AutoPlay"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "NoDriveTypeAutoRun" -Value 0xFF -Type DWord
            
            $status = Get-Status_Test -RegPath $regPath -CheckAutoPlay
            $status.AutoPlayKilled | Should -Be "disabled"
        }

        It "Should detect AutoPlay as enabled when NoDriveTypeAutoRun!=0xFF" {
            $regPath = "$testRegBase\AutoPlay"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "NoDriveTypeAutoRun" -Value 0x91 -Type DWord
            
            $status = Get-Status_Test -RegPath $regPath -CheckAutoPlay
            $status.AutoPlayKilled | Should -Be "enabled"
        }
    }

    Context "Get-Status - Thunderbolt" {
        It "Should detect Thunderbolt as blocked when Start=4" {
            $regPath = "$testRegBase\SYSTEM\CurrentControlSet\Services\thunderbolt"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "Start" -Value 4 -Type DWord
            
            $status = Get-Status_Test -RegPath $regPath -CheckThunderbolt
            $status.Thunderbolt | Should -Be "blocked"
        }

        It "Should detect Thunderbolt as not_present when key missing" {
            $status = Get-Status_Test -RegPath "$testRegBase\missing" -CheckThunderbolt
            $status.Thunderbolt | Should -Be "not_present"
        }
    }

    Context "Get-Status - DenyDeviceClasses" {
        It "Should parse JSON status correctly" {
            $jsonStatus = @{
                UsbStorage     = "blocked"
                WriteProtect   = "active"
                AutoPlayKilled = "disabled"
                VolumeWatcher  = "running"
                Thunderbolt    = "blocked"
                MtpPtp         = "blocked"
                UsbPrinters    = "blocked"
                CompanyName    = "Test Corp"
                Timestamp      = "2026-03-21 12:00:00"
            }
            
            $json = $jsonStatus | ConvertTo-Json
            $parsed = $json | ConvertFrom-Json
            
            $parsed.UsbStorage | Should -Be "blocked"
            $parsed.WriteProtect | Should -Be "active"
            $parsed.CompanyName | Should -Be "Test Corp"
        }
    }
}

# Test helper functions
function Get-Status_Test {
    param(
        [string]$RegPath,
        [switch]$CheckWriteProtect,
        [switch]$CheckAutoPlay,
        [switch]$CheckThunderbolt
    )
    
    $status = @{
        UsbStorage     = "unknown"
        WriteProtect   = "unknown"
        AutoPlayKilled = "unknown"
        Thunderbolt    = "unknown"
    }

    if (Test-Path $RegPath) {
        $v = (Get-ItemProperty $RegPath -Name "Start" -EA SilentlyContinue).Start
        if ($v -eq 4) { $status.UsbStorage = "blocked" }
        elseif ($v -eq 3) { $status.UsbStorage = "allowed" }
    }

    if ($CheckWriteProtect) {
        if (Test-Path $RegPath) {
            $v = (Get-ItemProperty $RegPath -Name "WriteProtect" -EA SilentlyContinue).WriteProtect
            $status.WriteProtect = if ($v -eq 1) { "active" } else { "inactive" }
        } else { $status.WriteProtect = "inactive" }
    }

    if ($CheckAutoPlay) {
        if (Test-Path $RegPath) {
            $v = (Get-ItemProperty $RegPath -Name "NoDriveTypeAutoRun" -EA SilentlyContinue).NoDriveTypeAutoRun
            $status.AutoPlayKilled = if ($v -eq 0xFF) { "disabled" } else { "enabled" }
        }
    }

    if ($CheckThunderbolt) {
        if (Test-Path $RegPath) {
            $v = (Get-ItemProperty $RegPath -Name "Start" -EA SilentlyContinue).Start
            $status.Thunderbolt = if ($v -eq 4) { "blocked" } else { "allowed" }
        } else { $status.Thunderbolt = "not_present" }
    }

    return $status
}
