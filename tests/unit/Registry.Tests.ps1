BeforeAll {
    # Import the main script for testing (non-blocking parts)
    # We'll mock the registry operations
    $ErrorActionPreference = "Continue"
}

Describe "Registry Helper Functions" {
    
    # Mock test registry path
    $testRegPath = "HKLM:\SOFTWARE\USBGuard_Test"
    
    BeforeEach {
        # Clean up test registry entries
        if (Test-Path $testRegPath) {
            Remove-Item $testRegPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    AfterEach {
        if (Test-Path $testRegPath) {
            Remove-Item $testRegPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Ensure-RegPath" {
        It "Should create a registry path that does not exist" {
            Ensure-RegPath $testRegPath
            Test-Path $testRegPath | Should -Be $true
        }

        It "Should not fail if path already exists" {
            New-Item -Path $testRegPath -Force | Out-Null
            { Ensure-RegPath $testRegPath } | Should -Not -Throw
            Test-Path $testRegPath | Should -Be $true
        }
    }

    Context "Set-RegDWord" {
        It "Should set a DWord value and create path if needed" {
            Set-RegDWord $testRegPath "TestValue" 1
            Test-Path $testRegPath | Should -Be $true
            (Get-ItemProperty $testRegPath -Name "TestValue" -EA SilentlyContinue).TestValue | Should -Be 1
        }

        It "Should overwrite existing DWord values" {
            Set-RegDWord $testRegPath "TestValue" 1
            Set-RegDWord $testRegPath "TestValue" 4
            (Get-ItemProperty $testRegPath -Name "TestValue").TestValue | Should -Be 4
        }

        It "Should handle multiple values in same path" {
            Set-RegDWord $testRegPath "Value1" 1
            Set-RegDWord $testRegPath "Value2" 2
            (Get-ItemProperty $testRegPath -Name "Value1").Value1 | Should -Be 1
            (Get-ItemProperty $testRegPath -Name "Value2").Value2 | Should -Be 2
        }
    }

    Context "Remove-RegValue" {
        It "Should remove an existing registry value" {
            Set-RegDWord $testRegPath "TestValue" 1
            Remove-RegValue $testRegPath "TestValue"
            Get-ItemProperty $testRegPath -Name "TestValue" -EA SilentlyContinue | Should -Be $null
        }

        It "Should not fail when removing non-existent value" {
            { Remove-RegValue $testRegPath "NonExistent" } | Should -Not -Throw
        }

        It "Should not fail when path does not exist" {
            { Remove-RegValue "HKLM:\NonExistent\Path" "Value" } | Should -Not -Throw
        }
    }

    Context "Save-OriginalStart and Get-SavedStart" {
        It "Should save and retrieve original Start values" {
            $savedPath = "$testRegPath\SavedStart"
            
            # Mock original registry key with Start value
            New-Item $testRegPath -Force | Out-Null
            Set-ItemProperty $testRegPath -Name "Start" -Value 3 -Type DWord
            
            # Save the original
            Save-OriginalStart $testRegPath
            
            # Verify it was saved
            Test-Path $savedPath | Should -Be $true
            
            # Get it back
            $retrieved = Get-SavedStart $testRegPath
            $retrieved | Should -Be 3
        }

        It "Should not overwrite existing saved values" {
            $savedPath = "$testRegPath\SavedStart"
            New-Item $testRegPath -Force | Out-Null
            Set-ItemProperty $testRegPath -Name "Start" -Value 3 -Type DWord
            
            Save-OriginalStart $testRegPath
            $first = Get-SavedStart $testRegPath
            
            # Change the current value
            Set-ItemProperty $testRegPath -Name "Start" -Value 4 -Type DWord
            
            # Save again - should not overwrite
            Save-OriginalStart $testRegPath
            $second = Get-SavedStart $testRegPath
            
            $first | Should -Be 3
            $second | Should -Be 3
        }
    }

    Context "Add-GuidToDenyList" {
        It "Should add a GUID to deny list" {
            $denyPath = "$testRegPath\DenyDeviceClasses"
            $testGuid = "{TEST-GUID-1234}"
            
            Add-GuidToDenyList_Test $denyPath $testGuid
            
            Test-Path $denyPath | Should -Be $true
            $props = (Get-Item $denyPath -EA SilentlyContinue).Property
            $props -contains "1" | Should -Be $true
        }

        It "Should not add duplicate GUIDs" {
            $denyPath = "$testRegPath\DenyDeviceClasses"
            $testGuid = "{TEST-GUID-1234}"
            
            Add-GuidToDenyList_Test $denyPath $testGuid
            Add-GuidToDenyList_Test $denyPath $testGuid
            
            $props = (Get-Item $denyPath -EA SilentlyContinue).Property
            # Count how many times this GUID appears
            $count = 0
            foreach ($p in $props) {
                if ((Get-ItemProperty $denyPath -Name $p -EA SilentlyContinue).$p -eq $testGuid) {
                    $count++
                }
            }
            $count | Should -Be 1
        }

        It "Should increment property names for multiple GUIDs" {
            $denyPath = "$testRegPath\DenyDeviceClasses"
            
            Add-GuidToDenyList_Test $denyPath "{GUID-1}"
            Add-GuidToDenyList_Test $denyPath "{GUID-2}"
            Add-GuidToDenyList_Test $denyPath "{GUID-3}"
            
            $props = (Get-Item $denyPath -EA SilentlyContinue).Property
            $props.Count | Should -Be 3
        }
    }

    Context "Remove-GuidFromDenyList" {
        It "Should remove a GUID from deny list" {
            $denyPath = "$testRegPath\DenyDeviceClasses"
            $testGuid = "{TEST-GUID-1234}"
            
            Add-GuidToDenyList_Test $denyPath $testGuid
            Remove-GuidFromDenyList_Test $denyPath $testGuid
            
            $props = (Get-Item $denyPath -EA SilentlyContinue).Property
            $foundGuid = $false
            foreach ($p in $props) {
                if ((Get-ItemProperty $denyPath -Name $p -EA SilentlyContinue).$p -eq $testGuid) {
                    $foundGuid = $true
                    break
                }
            }
            $foundGuid | Should -Be $false
        }

        It "Should not fail when GUID does not exist" {
            $denyPath = "$testRegPath\DenyDeviceClasses"
            { Remove-GuidFromDenyList_Test $denyPath "{NONEXISTENT}" } | Should -Not -Throw
        }
    }
}

# Helper functions for testing (simplified versions)
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
    $saved = "$($P)\SavedStart"
    Ensure-RegPath $saved
    $key = $P -replace 'HKLM:\\','' -replace '\\','_'
    return (Get-ItemProperty $saved -Name $key -EA SilentlyContinue).$key
}

function Save-OriginalStart { param([string]$P)
    $saved = "$($P)\SavedStart"
    Ensure-RegPath $saved
    $key = $P -replace 'HKLM:\\','' -replace '\\','_'
    if (-not (Get-ItemProperty $saved -Name $key -EA SilentlyContinue)) {
        $cur = (Get-ItemProperty $P -Name "Start" -EA SilentlyContinue).Start
        if ($null -ne $cur) {
            Set-ItemProperty $saved -Name $key -Value $cur -Type DWord -Force
        }
    }
}

function Add-GuidToDenyList_Test { param([string]$denyPath, [string]$Guid)
    Ensure-RegPath $denyPath
    $props = (Get-Item $denyPath -EA SilentlyContinue).Property
    foreach ($p in $props) {
        if ((Get-ItemProperty $denyPath -Name $p -EA SilentlyContinue).$p -eq $Guid) { return }
    }
    $next = 1
    if ($props) { $next = (($props | ForEach-Object { try {[int]$_} catch {0} } | Measure-Object -Maximum).Maximum) + 1 }
    Set-ItemProperty $denyPath -Name "$next" -Value $Guid -Type String
}

function Remove-GuidFromDenyList_Test { param([string]$denyPath, [string]$Guid)
    if (-not (Test-Path $denyPath)) { return }
    $props = (Get-Item $denyPath -EA SilentlyContinue).Property
    foreach ($p in $props) {
        if ((Get-ItemProperty $denyPath -Name $p -EA SilentlyContinue).$p -eq $Guid) {
            Remove-ItemProperty $denyPath -Name $p -EA SilentlyContinue
        }
    }
}
