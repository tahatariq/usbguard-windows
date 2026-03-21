BeforeAll {
    $ErrorActionPreference = "Continue"

    function Get-WpdStatus_Test {
        param([string]$denyClassesPath, [string]$svcPath, [string]$wpdGuid)

        $guidBlocked = $false
        if (Test-Path $denyClassesPath) {
            foreach ($k in (Get-Item $denyClassesPath -EA SilentlyContinue).Property) {
                if ((Get-ItemProperty $denyClassesPath -Name $k -EA SilentlyContinue).$k -eq $wpdGuid) {
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

    function Add-GuidToTestDenyList {
        param([string]$denyPath, [string]$guid)
        if (-not (Test-Path $denyPath)) { New-Item $denyPath -Force | Out-Null }
        $props = (Get-Item $denyPath -EA SilentlyContinue).Property
        foreach ($p in $props) {
            if ((Get-ItemProperty $denyPath -Name $p -EA SilentlyContinue).$p -eq $guid) { return }
        }
        $next = 1
        if ($props) { $next = (($props | ForEach-Object { try { [int]$_ } catch { 0 } } | Measure-Object -Maximum).Maximum) + 1 }
        Set-ItemProperty $denyPath -Name "$next" -Value $guid -Type String
    }

    function Remove-GuidFromTestDenyList {
        param([string]$denyPath, [string]$guid)
        if (-not (Test-Path $denyPath)) { return }
        $props = (Get-Item $denyPath -EA SilentlyContinue).Property
        foreach ($p in $props) {
            if ((Get-ItemProperty $denyPath -Name $p -EA SilentlyContinue).$p -eq $guid) {
                Remove-ItemProperty $denyPath -Name $p -EA SilentlyContinue
            }
        }
    }

    function Block-WpdMtp_Test {
        param([string]$denyBasePath, [string]$denyClassesPath, [string]$savedPath, [string[]]$svcPaths, [string[]]$guids)

        if (-not (Test-Path $denyBasePath)) { New-Item $denyBasePath -Force | Out-Null }
        Set-ItemProperty $denyBasePath -Name "DenyDeviceClasses"            -Value 1 -Type DWord -Force
        Set-ItemProperty $denyBasePath -Name "DenyDeviceClassesRetroactive" -Value 1 -Type DWord -Force
        if (-not (Test-Path $denyClassesPath)) { New-Item $denyClassesPath -Force | Out-Null }

        foreach ($guid in $guids) { Add-GuidToTestDenyList $denyClassesPath $guid }

        foreach ($svcPath in $svcPaths) {
            if (-not (Test-Path $svcPath)) { continue }
            $key = $svcPath -replace 'HKLM:\\','' -replace '\\','_'
            if (-not (Test-Path $savedPath)) { New-Item $savedPath -Force | Out-Null }
            if (-not (Get-ItemProperty $savedPath -Name $key -EA SilentlyContinue)) {
                $cur = (Get-ItemProperty $svcPath -Name "Start" -EA SilentlyContinue).Start
                if ($null -ne $cur) { Set-ItemProperty $savedPath -Name $key -Value $cur -Type DWord -Force }
            }
            Set-ItemProperty $svcPath -Name "Start" -Value 4 -Type DWord -Force
        }
    }

    function Unblock-WpdMtp_Test {
        param([string]$denyBasePath, [string]$denyClassesPath, [string]$savedPath, [string[]]$svcPaths, [string[]]$guids)

        foreach ($guid in $guids) { Remove-GuidFromTestDenyList $denyClassesPath $guid }

        foreach ($svcPath in $svcPaths) {
            if (-not (Test-Path $svcPath)) { continue }
            $key = $svcPath -replace 'HKLM:\\','' -replace '\\','_'
            $original = if (Test-Path $savedPath) { (Get-ItemProperty $savedPath -Name $key -EA SilentlyContinue).$key } else { $null }
            $restore = if ($null -ne $original) { $original } else { 3 }
            Set-ItemProperty $svcPath -Name "Start" -Value $restore -Type DWord -Force
        }

        if (Test-Path $denyClassesPath) {
            $remaining = (Get-Item $denyClassesPath -EA SilentlyContinue).Property
            if (-not $remaining) {
                if (Test-Path $denyBasePath) {
                    Set-ItemProperty $denyBasePath -Name "DenyDeviceClasses"            -Value 0 -Type DWord -Force
                    Set-ItemProperty $denyBasePath -Name "DenyDeviceClassesRetroactive" -Value 0 -Type DWord -Force
                }
            }
        }
    }
}

Describe "WPD/MTP/PTP (Layer 7) — Status Detection and Block/Unblock" {

    BeforeAll {
        $testRegBase     = "HKLM:\SOFTWARE\USBGuard_WpdTest"
        $denyBasePath    = "$testRegBase\DeviceInstall\Restrictions"
        $denyClassesPath = "$testRegBase\DeviceInstall\Restrictions\DenyDeviceClasses"
        $savedPath       = "$testRegBase\SavedStart"
        $svcPath         = "$testRegBase\Services\WpdFilesystemDriver"

        $GUID_WPD        = "{EEC5AD98-8080-425F-922A-DABF3DE3F69A}"
        $GUID_IMAGING    = "{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}"
        $GUID_WPD_PRINT  = "{70AE35D8-BF10-11D0-AC45-0000C0B0BFCB}"
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

    Context "Get-WpdStatus_Test" {
        It "Should return 'blocked' when GUID in deny list AND service Start=4" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 4 -Type DWord
            Add-GuidToTestDenyList $denyClassesPath $GUID_WPD

            Get-WpdStatus_Test $denyClassesPath $svcPath $GUID_WPD | Should -Be "blocked"
        }

        It "Should return 'partial' when GUID in deny list but service not disabled" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 3 -Type DWord
            Add-GuidToTestDenyList $denyClassesPath $GUID_WPD

            Get-WpdStatus_Test $denyClassesPath $svcPath $GUID_WPD | Should -Be "partial"
        }

        It "Should return 'partial' when service Start=4 but GUID not in deny list" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 4 -Type DWord
            New-Item $denyClassesPath -Force | Out-Null

            Get-WpdStatus_Test $denyClassesPath $svcPath $GUID_WPD | Should -Be "partial"
        }

        It "Should return 'allowed' when GUID not in list and service not disabled" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 3 -Type DWord

            Get-WpdStatus_Test $denyClassesPath $svcPath $GUID_WPD | Should -Be "allowed"
        }

        It "Should return 'allowed' when neither path exists" {
            Get-WpdStatus_Test $denyClassesPath $svcPath $GUID_WPD | Should -Be "allowed"
        }
    }

    Context "Block-WpdMtp_Test" {
        It "Should add all three WPD GUIDs to the deny list" {
            $guids = @($GUID_WPD, $GUID_WPD_PRINT, $GUID_IMAGING)
            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) $guids

            $props = (Get-Item $denyClassesPath -EA SilentlyContinue).Property
            $values = $props | ForEach-Object { (Get-ItemProperty $denyClassesPath -Name $_ -EA SilentlyContinue).$_ }

            $values | Should -Contain $GUID_WPD
            $values | Should -Contain $GUID_WPD_PRINT
            $values | Should -Contain $GUID_IMAGING
        }

        It "Should set DenyDeviceClasses=1 and DenyDeviceClassesRetroactive=1" {
            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @() @($GUID_WPD)

            (Get-ItemProperty $denyBasePath -Name "DenyDeviceClasses").DenyDeviceClasses | Should -Be 1
            (Get-ItemProperty $denyBasePath -Name "DenyDeviceClassesRetroactive").DenyDeviceClassesRetroactive | Should -Be 1
        }

        It "Should set service Start=4" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 3 -Type DWord

            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) @($GUID_WPD)

            (Get-ItemProperty $svcPath -Name "Start").Start | Should -Be 4
        }

        It "Should save original Start value before disabling" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 3 -Type DWord

            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) @($GUID_WPD)

            $key = $svcPath -replace 'HKLM:\\','' -replace '\\','_'
            $saved = (Get-ItemProperty $savedPath -Name $key -EA SilentlyContinue).$key
            $saved | Should -Be 3
        }

        It "Should be idempotent — blocking twice keeps Start=4 and saves original only once" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 3 -Type DWord

            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) @($GUID_WPD)
            Set-ItemProperty $svcPath -Name "Start" -Value 4 -Type DWord
            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) @($GUID_WPD)

            $key = $svcPath -replace 'HKLM:\\','' -replace '\\','_'
            $saved = (Get-ItemProperty $savedPath -Name $key -EA SilentlyContinue).$key
            $saved | Should -Be 3

            $props = (Get-Item $denyClassesPath -EA SilentlyContinue).Property
            $count = ($props | Where-Object {
                (Get-ItemProperty $denyClassesPath -Name $_ -EA SilentlyContinue).$_ -eq $GUID_WPD
            }).Count
            $count | Should -Be 1
        }
    }

    Context "Unblock-WpdMtp_Test" {
        It "Should remove WPD GUIDs from the deny list" {
            $guids = @($GUID_WPD, $GUID_WPD_PRINT, $GUID_IMAGING)
            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @() $guids
            Unblock-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @() $guids

            $props = (Get-Item $denyClassesPath -EA SilentlyContinue).Property
            $values = if ($props) {
                $props | ForEach-Object { (Get-ItemProperty $denyClassesPath -Name $_ -EA SilentlyContinue).$_ }
            } else { @() }

            $values | Should -Not -Contain $GUID_WPD
            $values | Should -Not -Contain $GUID_WPD_PRINT
            $values | Should -Not -Contain $GUID_IMAGING
        }

        It "Should restore service to saved Start value" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 3 -Type DWord

            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) @($GUID_WPD)
            Unblock-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) @($GUID_WPD)

            (Get-ItemProperty $svcPath -Name "Start").Start | Should -Be 3
        }

        It "Should fall back to Start=3 when no saved value exists" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 4 -Type DWord

            Unblock-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) @($GUID_WPD)

            (Get-ItemProperty $svcPath -Name "Start").Start | Should -Be 3
        }

        It "Should preserve a service that was originally disabled (Start=4)" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 4 -Type DWord

            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) @($GUID_WPD)
            Unblock-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) @($GUID_WPD)

            (Get-ItemProperty $svcPath -Name "Start").Start | Should -Be 4
        }

        It "Should clear DenyDeviceClasses flags when deny list becomes empty" {
            $guids = @($GUID_WPD, $GUID_WPD_PRINT, $GUID_IMAGING)
            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @() $guids
            Unblock-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @() $guids

            $dc = (Get-ItemProperty $denyBasePath -Name "DenyDeviceClasses" -EA SilentlyContinue).DenyDeviceClasses
            $dc | Should -Be 0
        }

        It "Block then Unblock roundtrip — status returns 'allowed' afterward" {
            New-Item $svcPath -Force | Out-Null
            Set-ItemProperty $svcPath -Name "Start" -Value 3 -Type DWord
            $guids = @($GUID_WPD, $GUID_WPD_PRINT, $GUID_IMAGING)

            Block-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) $guids
            $midStatus = Get-WpdStatus_Test $denyClassesPath $svcPath $GUID_WPD
            $midStatus | Should -Be "blocked"

            Unblock-WpdMtp_Test $denyBasePath $denyClassesPath $savedPath @($svcPath) $guids
            $finalStatus = Get-WpdStatus_Test $denyClassesPath $svcPath $GUID_WPD
            $finalStatus | Should -Be "allowed"
        }
    }
}
