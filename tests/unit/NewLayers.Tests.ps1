BeforeAll {
    $ErrorActionPreference = "Continue"

    # ── Registry helpers (inlined from USBGuard.ps1 for test isolation) ───────

    function Ensure-RegPath { param([string]$P)
        if (-not (Test-Path $P)) { New-Item -Path $P -Force | Out-Null }
    }

    function Set-RegDWord { param([string]$P,[string]$N,[int]$V)
        Ensure-RegPath $P
        Set-ItemProperty -Path $P -Name $N -Value $V -Type DWord -Force
    }

    function Get-SavedStart_Test { param([string]$P, [string]$SavedPath)
        Ensure-RegPath $SavedPath
        $key = $P -replace 'HKLM:\\','' -replace '\\','_'
        return (Get-ItemProperty $SavedPath -Name $key -EA SilentlyContinue).$key
    }

    function Save-OriginalStart_Test { param([string]$P, [string]$SavedPath)
        Ensure-RegPath $SavedPath
        $key = $P -replace 'HKLM:\\','' -replace '\\','_'
        if (-not (Get-ItemProperty $SavedPath -Name $key -EA SilentlyContinue)) {
            $cur = (Get-ItemProperty $P -Name "Start" -EA SilentlyContinue).Start
            if ($null -ne $cur) {
                Set-ItemProperty $SavedPath -Name $key -Value $cur -Type DWord -Force
            }
        }
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

    # ── Layer 8: SD Card Block / Unblock ─────────────────────────────────────

    function Block-SdCard_Test {
        param([string]$SdbusPath, [string]$SavedPath)
        if (Test-Path $SdbusPath) {
            Save-OriginalStart_Test $SdbusPath $SavedPath
            Set-RegDWord $SdbusPath "Start" 4
        }
    }

    function Unblock-SdCard_Test {
        param([string]$SdbusPath, [string]$SavedPath)
        if (Test-Path $SdbusPath) {
            $restore = Get-SavedStart_Test $SdbusPath $SavedPath
            $startVal = if ($null -ne $restore) { $restore } else { 3 }
            Set-RegDWord $SdbusPath "Start" $startVal
        }
    }

    # ── Layer 9: Bluetooth File Transfer Block / Unblock ─────────────────────

    function Block-BluetoothFileTransfer_Test {
        param([string[]]$SvcPaths, [string]$SavedPath, [string]$DenyClassesPath, [string]$ObexGuid)
        foreach ($svc in $SvcPaths) {
            if (Test-Path $svc) {
                Save-OriginalStart_Test $svc $SavedPath
                Set-RegDWord $svc "Start" 4
            }
        }
        Add-GuidToTestDenyList $DenyClassesPath $ObexGuid
    }

    function Unblock-BluetoothFileTransfer_Test {
        param([string[]]$SvcPaths, [string]$SavedPath, [string]$DenyClassesPath, [string]$ObexGuid)
        foreach ($svc in $SvcPaths) {
            if (Test-Path $svc) {
                $restore = Get-SavedStart_Test $svc $SavedPath
                $startVal = if ($null -ne $restore) { $restore } else { 3 }
                Set-RegDWord $svc "Start" $startVal
            }
        }
        Remove-GuidFromTestDenyList $DenyClassesPath $ObexGuid
    }

    # ── Layer 10: FireWire Block / Unblock ───────────────────────────────────

    function Block-FireWire_Test {
        param([string]$FirewirePath, [string]$SavedPath)
        if (Test-Path $FirewirePath) {
            Save-OriginalStart_Test $FirewirePath $SavedPath
            Set-RegDWord $FirewirePath "Start" 4
        }
    }

    function Unblock-FireWire_Test {
        param([string]$FirewirePath, [string]$SavedPath)
        if (Test-Path $FirewirePath) {
            $restore = Get-SavedStart_Test $FirewirePath $SavedPath
            $startVal = if ($null -ne $restore) { $restore } else { 3 }
            Set-RegDWord $FirewirePath "Start" $startVal
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Layer 8 — SD Card (sdbus)
# ═══════════════════════════════════════════════════════════════════════════════

Describe "Block-SdCard / Unblock-SdCard (Layer 8)" {

    BeforeAll {
        $testRegBase = "HKLM:\SOFTWARE\USBGuard_SdCardTest"
        $sdbusPath   = "$testRegBase\Services\sdbus"
        $savedPath   = "$testRegBase\SavedStart"
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

    Context "Block-SdCard_Test" {
        It "Should set sdbus Start=4 when service path exists" {
            New-Item $sdbusPath -Force | Out-Null
            Set-ItemProperty $sdbusPath -Name "Start" -Value 3 -Type DWord

            Block-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath

            (Get-ItemProperty $sdbusPath -Name "Start").Start | Should -Be 4
        }

        It "Should call Save-OriginalStart before blocking" {
            New-Item $sdbusPath -Force | Out-Null
            Set-ItemProperty $sdbusPath -Name "Start" -Value 2 -Type DWord

            Block-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath

            $saved = Get-SavedStart_Test $sdbusPath $savedPath
            $saved | Should -Be 2
        }

        It "Should not fail when sdbus service path does not exist" {
            { Block-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath } | Should -Not -Throw
        }

        It "Should be idempotent - blocking twice preserves original saved value" {
            New-Item $sdbusPath -Force | Out-Null
            Set-ItemProperty $sdbusPath -Name "Start" -Value 3 -Type DWord

            Block-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath
            Block-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath

            $saved = Get-SavedStart_Test $sdbusPath $savedPath
            $saved | Should -Be 3
            (Get-ItemProperty $sdbusPath -Name "Start").Start | Should -Be 4
        }
    }

    Context "Unblock-SdCard_Test" {
        It "Should restore sdbus to saved Start value" {
            New-Item $sdbusPath -Force | Out-Null
            Set-ItemProperty $sdbusPath -Name "Start" -Value 3 -Type DWord

            Block-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath
            Unblock-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath

            (Get-ItemProperty $sdbusPath -Name "Start").Start | Should -Be 3
        }

        It "Should fall back to Start=3 when no saved value exists" {
            New-Item $sdbusPath -Force | Out-Null
            Set-ItemProperty $sdbusPath -Name "Start" -Value 4 -Type DWord

            Unblock-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath

            (Get-ItemProperty $sdbusPath -Name "Start").Start | Should -Be 3
        }

        It "Should not fail when sdbus service path does not exist" {
            { Unblock-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath } | Should -Not -Throw
        }

        It "Block then Unblock roundtrip restores original Start value" {
            New-Item $sdbusPath -Force | Out-Null
            Set-ItemProperty $sdbusPath -Name "Start" -Value 2 -Type DWord

            Block-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath
            (Get-ItemProperty $sdbusPath -Name "Start").Start | Should -Be 4

            Unblock-SdCard_Test -SdbusPath $sdbusPath -SavedPath $savedPath
            (Get-ItemProperty $sdbusPath -Name "Start").Start | Should -Be 2
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Layer 9 — Bluetooth File Transfer (OBEX / RFCOMM)
# ═══════════════════════════════════════════════════════════════════════════════

Describe "Block-BluetoothFileTransfer / Unblock-BluetoothFileTransfer (Layer 9)" {

    BeforeAll {
        $testRegBase      = "HKLM:\SOFTWARE\USBGuard_BtTest"
        $btObexPath       = "$testRegBase\Services\BthOBEX"
        $btRfcommPath     = "$testRegBase\Services\RFCOMM"
        $savedPath        = "$testRegBase\SavedStart"
        $denyClassesPath  = "$testRegBase\DeviceInstall\Restrictions\DenyDeviceClasses"
        $GUID_BT_OBEX     = "{E0CBF06C-CD8B-4647-BB8A-263B43F0F974}"
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

    Context "Block-BluetoothFileTransfer_Test" {
        It "Should disable BthOBEX and RFCOMM services (Start=4)" {
            New-Item $btObexPath -Force | Out-Null
            Set-ItemProperty $btObexPath -Name "Start" -Value 3 -Type DWord
            New-Item $btRfcommPath -Force | Out-Null
            Set-ItemProperty $btRfcommPath -Name "Start" -Value 3 -Type DWord

            Block-BluetoothFileTransfer_Test `
                -SvcPaths @($btObexPath, $btRfcommPath) `
                -SavedPath $savedPath `
                -DenyClassesPath $denyClassesPath `
                -ObexGuid $GUID_BT_OBEX

            (Get-ItemProperty $btObexPath -Name "Start").Start | Should -Be 4
            (Get-ItemProperty $btRfcommPath -Name "Start").Start | Should -Be 4
        }

        It "Should save original Start values before disabling" {
            New-Item $btObexPath -Force | Out-Null
            Set-ItemProperty $btObexPath -Name "Start" -Value 3 -Type DWord
            New-Item $btRfcommPath -Force | Out-Null
            Set-ItemProperty $btRfcommPath -Name "Start" -Value 2 -Type DWord

            Block-BluetoothFileTransfer_Test `
                -SvcPaths @($btObexPath, $btRfcommPath) `
                -SavedPath $savedPath `
                -DenyClassesPath $denyClassesPath `
                -ObexGuid $GUID_BT_OBEX

            $savedObex   = Get-SavedStart_Test $btObexPath $savedPath
            $savedRfcomm = Get-SavedStart_Test $btRfcommPath $savedPath
            $savedObex   | Should -Be 3
            $savedRfcomm | Should -Be 2
        }

        It "Should add Bluetooth OBEX GUID to the deny list" {
            Block-BluetoothFileTransfer_Test `
                -SvcPaths @() `
                -SavedPath $savedPath `
                -DenyClassesPath $denyClassesPath `
                -ObexGuid $GUID_BT_OBEX

            $props  = (Get-Item $denyClassesPath -EA SilentlyContinue).Property
            $values = $props | ForEach-Object { (Get-ItemProperty $denyClassesPath -Name $_ -EA SilentlyContinue).$_ }
            $values | Should -Contain $GUID_BT_OBEX
        }

        It "Should not duplicate GUID when blocking twice" {
            Block-BluetoothFileTransfer_Test -SvcPaths @() -SavedPath $savedPath -DenyClassesPath $denyClassesPath -ObexGuid $GUID_BT_OBEX
            Block-BluetoothFileTransfer_Test -SvcPaths @() -SavedPath $savedPath -DenyClassesPath $denyClassesPath -ObexGuid $GUID_BT_OBEX

            $props = (Get-Item $denyClassesPath -EA SilentlyContinue).Property
            $count = ($props | Where-Object {
                (Get-ItemProperty $denyClassesPath -Name $_ -EA SilentlyContinue).$_ -eq $GUID_BT_OBEX
            }).Count
            $count | Should -Be 1
        }
    }

    Context "Unblock-BluetoothFileTransfer_Test" {
        It "Should restore BthOBEX and RFCOMM services to saved values" {
            New-Item $btObexPath -Force | Out-Null
            Set-ItemProperty $btObexPath -Name "Start" -Value 3 -Type DWord
            New-Item $btRfcommPath -Force | Out-Null
            Set-ItemProperty $btRfcommPath -Name "Start" -Value 2 -Type DWord

            Block-BluetoothFileTransfer_Test `
                -SvcPaths @($btObexPath, $btRfcommPath) `
                -SavedPath $savedPath `
                -DenyClassesPath $denyClassesPath `
                -ObexGuid $GUID_BT_OBEX

            Unblock-BluetoothFileTransfer_Test `
                -SvcPaths @($btObexPath, $btRfcommPath) `
                -SavedPath $savedPath `
                -DenyClassesPath $denyClassesPath `
                -ObexGuid $GUID_BT_OBEX

            (Get-ItemProperty $btObexPath -Name "Start").Start   | Should -Be 3
            (Get-ItemProperty $btRfcommPath -Name "Start").Start | Should -Be 2
        }

        It "Should fall back to Start=3 when no saved values exist" {
            New-Item $btObexPath -Force | Out-Null
            Set-ItemProperty $btObexPath -Name "Start" -Value 4 -Type DWord

            Unblock-BluetoothFileTransfer_Test `
                -SvcPaths @($btObexPath) `
                -SavedPath $savedPath `
                -DenyClassesPath $denyClassesPath `
                -ObexGuid $GUID_BT_OBEX

            (Get-ItemProperty $btObexPath -Name "Start").Start | Should -Be 3
        }

        It "Should remove Bluetooth OBEX GUID from the deny list" {
            Block-BluetoothFileTransfer_Test -SvcPaths @() -SavedPath $savedPath -DenyClassesPath $denyClassesPath -ObexGuid $GUID_BT_OBEX
            Unblock-BluetoothFileTransfer_Test -SvcPaths @() -SavedPath $savedPath -DenyClassesPath $denyClassesPath -ObexGuid $GUID_BT_OBEX

            $props = (Get-Item $denyClassesPath -EA SilentlyContinue).Property
            $values = if ($props) {
                $props | ForEach-Object { (Get-ItemProperty $denyClassesPath -Name $_ -EA SilentlyContinue).$_ }
            } else { @() }
            $values | Should -Not -Contain $GUID_BT_OBEX
        }

        It "Block then Unblock roundtrip restores original state" {
            New-Item $btObexPath -Force | Out-Null
            Set-ItemProperty $btObexPath -Name "Start" -Value 3 -Type DWord
            New-Item $btRfcommPath -Force | Out-Null
            Set-ItemProperty $btRfcommPath -Name "Start" -Value 3 -Type DWord

            Block-BluetoothFileTransfer_Test `
                -SvcPaths @($btObexPath, $btRfcommPath) `
                -SavedPath $savedPath `
                -DenyClassesPath $denyClassesPath `
                -ObexGuid $GUID_BT_OBEX

            (Get-ItemProperty $btObexPath -Name "Start").Start   | Should -Be 4
            (Get-ItemProperty $btRfcommPath -Name "Start").Start | Should -Be 4

            Unblock-BluetoothFileTransfer_Test `
                -SvcPaths @($btObexPath, $btRfcommPath) `
                -SavedPath $savedPath `
                -DenyClassesPath $denyClassesPath `
                -ObexGuid $GUID_BT_OBEX

            (Get-ItemProperty $btObexPath -Name "Start").Start   | Should -Be 3
            (Get-ItemProperty $btRfcommPath -Name "Start").Start | Should -Be 3
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Layer 10 — FireWire / IEEE 1394
# ═══════════════════════════════════════════════════════════════════════════════

Describe "Block-FireWire / Unblock-FireWire (Layer 10)" {

    BeforeAll {
        $testRegBase   = "HKLM:\SOFTWARE\USBGuard_FireWireTest"
        $firewirePath  = "$testRegBase\Services\1394ohci"
        $savedPath     = "$testRegBase\SavedStart"
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

    Context "Block-FireWire_Test" {
        It "Should set 1394ohci Start=4 when service path exists" {
            New-Item $firewirePath -Force | Out-Null
            Set-ItemProperty $firewirePath -Name "Start" -Value 3 -Type DWord

            Block-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath

            (Get-ItemProperty $firewirePath -Name "Start").Start | Should -Be 4
        }

        It "Should call Save-OriginalStart before blocking" {
            New-Item $firewirePath -Force | Out-Null
            Set-ItemProperty $firewirePath -Name "Start" -Value 1 -Type DWord

            Block-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath

            $saved = Get-SavedStart_Test $firewirePath $savedPath
            $saved | Should -Be 1
        }

        It "Should not fail when 1394ohci service path does not exist" {
            { Block-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath } | Should -Not -Throw
        }

        It "Should be idempotent - blocking twice preserves original saved value" {
            New-Item $firewirePath -Force | Out-Null
            Set-ItemProperty $firewirePath -Name "Start" -Value 3 -Type DWord

            Block-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath
            Block-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath

            $saved = Get-SavedStart_Test $firewirePath $savedPath
            $saved | Should -Be 3
            (Get-ItemProperty $firewirePath -Name "Start").Start | Should -Be 4
        }
    }

    Context "Unblock-FireWire_Test" {
        It "Should restore 1394ohci to saved Start value" {
            New-Item $firewirePath -Force | Out-Null
            Set-ItemProperty $firewirePath -Name "Start" -Value 3 -Type DWord

            Block-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath
            Unblock-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath

            (Get-ItemProperty $firewirePath -Name "Start").Start | Should -Be 3
        }

        It "Should fall back to Start=3 when no saved value exists" {
            New-Item $firewirePath -Force | Out-Null
            Set-ItemProperty $firewirePath -Name "Start" -Value 4 -Type DWord

            Unblock-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath

            (Get-ItemProperty $firewirePath -Name "Start").Start | Should -Be 3
        }

        It "Should not fail when 1394ohci service path does not exist" {
            { Unblock-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath } | Should -Not -Throw
        }

        It "Block then Unblock roundtrip restores original Start value" {
            New-Item $firewirePath -Force | Out-Null
            Set-ItemProperty $firewirePath -Name "Start" -Value 1 -Type DWord

            Block-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath
            (Get-ItemProperty $firewirePath -Name "Start").Start | Should -Be 4

            Unblock-FireWire_Test -FirewirePath $firewirePath -SavedPath $savedPath
            (Get-ItemProperty $firewirePath -Name "Start").Start | Should -Be 1
        }
    }
}
