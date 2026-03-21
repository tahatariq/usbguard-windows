BeforeAll {
    $ErrorActionPreference = "Continue"
}

Describe "Block/Unblock Operations - Idempotency" {

    BeforeAll {
        $testRegBase = "HKLM:\SOFTWARE\USBGuard_IntegrationTest"
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

    Context "Block-StorageRegistry Idempotency" {
        It "Should be safe to run block twice in a row" {
            $regPath = "$testRegBase\SYSTEM\CurrentControlSet\Services\USBSTOR"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "Start" -Value 3 -Type DWord
            
            # Block once
            Block-StorageRegistry_Test $regPath
            $firstBlock = (Get-ItemProperty $regPath -Name "Start").Start
            
            # Block again - should not change
            Block-StorageRegistry_Test $regPath
            $secondBlock = (Get-ItemProperty $regPath -Name "Start").Start
            
            $firstBlock | Should -Be 4
            $secondBlock | Should -Be 4
        }

        It "Should save original value only once" {
            $regPath = "$testRegBase\Services\USBSTOR"
            $savedPath = "$testRegBase\SavedStart"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "Start" -Value 3 -Type DWord
            
            # Block once
            Save-OriginalStart_Test $regPath $savedPath
            $firstSave = Get-SavedStart_Test $regPath $savedPath
            
            # Change to 2 and save again
            Set-ItemProperty $regPath -Name "Start" -Value 2 -Type DWord
            Save-OriginalStart_Test $regPath $savedPath
            $secondSave = Get-SavedStart_Test $regPath $savedPath
            
            # Should still be 3 (original not overwritten)
            $firstSave | Should -Be 3
            $secondSave | Should -Be 3
        }
    }

    Context "Block then Unblock Roundtrip" {
        It "Should restore original state after unblock" {
            $regPath = "$testRegBase\Services\USBSTOR"
            $savedPath = "$testRegBase\SavedStart"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "Start" -Value 3 -Type DWord
            
            # Save original
            Save-OriginalStart_Test $regPath $savedPath
            
            # Block
            Block-StorageRegistry_Test $regPath
            (Get-ItemProperty $regPath -Name "Start").Start | Should -Be 4
            
            # Unblock
            Unblock-StorageRegistry_Test $regPath $savedPath
            $restored = (Get-ItemProperty $regPath -Name "Start").Start
            
            $restored | Should -Be 3
        }

        It "Should handle services that were originally disabled" {
            $regPath = "$testRegBase\Services\USBSTOR"
            $savedPath = "$testRegBase\SavedStart"
            New-Item $regPath -Force | Out-Null
            Set-ItemProperty $regPath -Name "Start" -Value 4 -Type DWord  # Already disabled
            
            Save-OriginalStart_Test $regPath $savedPath
            Block-StorageRegistry_Test $regPath
            Unblock-StorageRegistry_Test $regPath $savedPath
            
            # Should still be 4 (disabled)
            $restored = (Get-ItemProperty $regPath -Name "Start").Start
            $restored | Should -Be 4
        }
    }

    Context "GUID Addition and Removal" {
        It "Should not corrupt deny list when adding/removing GUIDs" {
            $denyPath = "$testRegBase\DenyDeviceClasses"
            $guid1 = "{GUID-1}"
            $guid2 = "{GUID-2}"
            $guid3 = "{GUID-3}"
            
            # Add three GUIDs
            Add-GuidToDenyList_Test $denyPath $guid1
            Add-GuidToDenyList_Test $denyPath $guid2
            Add-GuidToDenyList_Test $denyPath $guid3
            
            $before = (Get-Item $denyPath -EA SilentlyContinue).Property.Count
            $before | Should -Be 3
            
            # Remove middle one
            Remove-GuidFromDenyList_Test $denyPath $guid2
            
            $after = (Get-Item $denyPath -EA SilentlyContinue).Property.Count
            $after | Should -Be 2
            
            # Verify remaining GUIDs are intact
            $props = (Get-Item $denyPath -EA SilentlyContinue).Property
            $found1 = $false
            $found3 = $false
            foreach ($p in $props) {
                $val = (Get-ItemProperty $denyPath -Name $p).$p
                if ($val -eq $guid1) { $found1 = $true }
                if ($val -eq $guid3) { $found3 = $true }
            }
            $found1 | Should -Be $true
            $found3 | Should -Be $true
        }
    }

    Context "Multi-Layer Operations" {
        It "Should handle complex block sequence without errors" {
            $usbstorPath = "$testRegBase\Services\USBSTOR"
            $wpPath = "$testRegBase\StorageDevicePolicies"
            $apPath = "$testRegBase\Explorer"
            
            New-Item $usbstorPath -Force | Out-Null
            New-Item $wpPath -Force | Out-Null
            New-Item $apPath -Force | Out-Null
            
            Set-ItemProperty $usbstorPath -Name "Start" -Value 3 -Type DWord
            Set-ItemProperty $apPath -Name "NoDriveTypeAutoRun" -Value 0x91 -Type DWord
            
            # Simulate multi-layer block
            Set-ItemProperty $usbstorPath -Name "Start" -Value 4 -Type DWord
            Set-ItemProperty $wpPath -Name "WriteProtect" -Value 1 -Type DWord
            Set-ItemProperty $apPath -Name "NoDriveTypeAutoRun" -Value 0xFF -Type DWord
            
            # Verify all are set
            (Get-ItemProperty $usbstorPath -Name "Start").Start | Should -Be 4
            (Get-ItemProperty $wpPath -Name "WriteProtect").WriteProtect | Should -Be 1
            (Get-ItemProperty $apPath -Name "NoDriveTypeAutoRun").NoDriveTypeAutoRun | Should -Be 0xFF
        }

        It "Should unblock all layers in correct order" {
            $usbstorPath = "$testRegBase\Services\USBSTOR"
            $wpPath = "$testRegBase\StorageDevicePolicies"
            $savedPath = "$testRegBase\SavedStart"
            
            New-Item $usbstorPath -Force | Out-Null
            New-Item $wpPath -Force | Out-Null
            Set-ItemProperty $usbstorPath -Name "Start" -Value 3 -Type DWord
            Save-OriginalStart_Test $usbstorPath $savedPath
            
            # Block
            Set-ItemProperty $usbstorPath -Name "Start" -Value 4 -Type DWord
            Set-ItemProperty $wpPath -Name "WriteProtect" -Value 1 -Type DWord
            
            # Unblock
            Unblock-StorageRegistry_Test $usbstorPath $savedPath
            Set-ItemProperty $wpPath -Name "WriteProtect" -Value 0 -Type DWord
            
            # Verify
            (Get-ItemProperty $usbstorPath -Name "Start").Start | Should -Be 3
            (Get-ItemProperty $wpPath -Name "WriteProtect").WriteProtect | Should -Be 0
        }
    }

    Context "Notification Configuration" {
        It "Should save and retrieve notification settings" {
            $cfgPath = "$testRegBase\Notify"
            New-Item $cfgPath -Force | Out-Null
            
            Set-ItemProperty $cfgPath -Name "CompanyName" -Value "Acme Corp" -Type String
            Set-ItemProperty $cfgPath -Name "NotifyMessage" -Value "Device blocked by policy" -Type String
            
            $company = (Get-ItemProperty $cfgPath -Name "CompanyName").CompanyName
            $message = (Get-ItemProperty $cfgPath -Name "NotifyMessage").NotifyMessage
            
            $company | Should -Be "Acme Corp"
            $message | Should -Be "Device blocked by policy"
        }

        It "Should handle special characters in messages" {
            $cfgPath = "$testRegBase\Notify"
            New-Item $cfgPath -Force | Out-Null
            
            $specialMsg = "Contact IT Support: support@company.com or ext. 1234 (8am-5pm)"
            Set-ItemProperty $cfgPath -Name "NotifyMessage" -Value $specialMsg -Type String
            
            $retrieved = (Get-ItemProperty $cfgPath -Name "NotifyMessage").NotifyMessage
            $retrieved | Should -Be $specialMsg
        }

        It "Should replace {COMPANY} placeholder correctly" {
            $template = "USB blocked by {COMPANY} policy. Contact {COMPANY} IT."
            $company = "Tech Corp"
            
            $resolved = $template -replace '\{COMPANY\}', $company
            
            $resolved | Should -Be "USB blocked by Tech Corp policy. Contact Tech Corp IT."
        }
    }
}

# Test helper functions
function Block-StorageRegistry_Test {
    param([string]$Path)
    if (Test-Path $Path) {
        Set-ItemProperty -Path $Path -Name "Start" -Value 4 -Type DWord -Force
    }
}

function Unblock-StorageRegistry_Test {
    param([string]$Path, [string]$SavedPath)
    if (Test-Path $Path) {
        $original = Get-SavedStart_Test $Path $SavedPath
        $restore = if ($null -ne $original) { $original } else { 3 }
        Set-ItemProperty -Path $Path -Name "Start" -Value $restore -Type DWord -Force
    }
}

function Save-OriginalStart_Test {
    param([string]$Path, [string]$SavedPath)
    $key = $Path -replace 'HKLM:\\','' -replace '\\','_'
    if (-not (Test-Path $SavedPath)) { New-Item $SavedPath -Force | Out-Null }
    if (-not (Get-ItemProperty $SavedPath -Name $key -EA SilentlyContinue)) {
        $cur = (Get-ItemProperty $Path -Name "Start" -EA SilentlyContinue).Start
        if ($null -ne $cur) {
            Set-ItemProperty $SavedPath -Name $key -Value $cur -Type DWord -Force
        }
    }
}

function Get-SavedStart_Test {
    param([string]$Path, [string]$SavedPath)
    $key = $Path -replace 'HKLM:\\','' -replace '\\','_'
    return (Get-ItemProperty $SavedPath -Name $key -EA SilentlyContinue).$key
}

function Add-GuidToDenyList_Test {
    param([string]$Path, [string]$Guid)
    if (-not (Test-Path $Path)) { New-Item $Path -Force | Out-Null }
    $props = (Get-Item $Path -EA SilentlyContinue).Property
    foreach ($p in $props) {
        if ((Get-ItemProperty $Path -Name $p -EA SilentlyContinue).$p -eq $Guid) { return }
    }
    $next = 1
    if ($props) { $next = (($props | ForEach-Object { try {[int]$_} catch {0} } | Measure-Object -Maximum).Maximum) + 1 }
    Set-ItemProperty $Path -Name "$next" -Value $Guid -Type String
}

function Remove-GuidFromDenyList_Test {
    param([string]$Path, [string]$Guid)
    if (-not (Test-Path $Path)) { return }
    $props = (Get-Item $Path -EA SilentlyContinue).Property
    foreach ($p in $props) {
        if ((Get-ItemProperty $Path -Name $p -EA SilentlyContinue).$p -eq $Guid) {
            Remove-ItemProperty $Path -Name $p -EA SilentlyContinue
        }
    }
}
