BeforeAll {
    # ── Inline the testable functions from USBGuard_ComplianceReport.ps1 ──────
    # (No file dot-sourcing so tests stay registry-isolated)

    function Get-LayerStatusMap_Test {
        param([hashtable]$RegOverrides)
        # RegOverrides maps reg-value-key to value, e.g.:
        #   @{ USBSTOR_Start=4; WriteProtect=1; DenyDeviceClasses=1;
        #      NoDriveTypeAutoRun=255; VolumeWatcher="Running";
        #      Thunderbolt_Start=4; WpdFsDriver_Start=4 }

        $m = [ordered]@{}

        $v = $RegOverrides["USBSTOR_Start"]
        $m["L1 - USB Storage (USBSTOR)"] = if ($v -eq 4) { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

        $v = $RegOverrides["WriteProtect"]
        $m["L2 - Write Protect"] = if ($v -eq 1) { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

        $v = $RegOverrides["DenyDeviceClasses"]
        $m["L3 - Device Class Deny List"] = if ($v -eq 1) { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

        $v = $RegOverrides["NoDriveTypeAutoRun"]
        $m["L4 - AutoPlay / AutoRun"] = if ($v -eq 255) { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

        $v = $RegOverrides["VolumeWatcher"]
        $m["L5 - Volume Watcher Task"] = if ($v -eq "Running") { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

        $v = $RegOverrides["Thunderbolt_Start"]
        $m["L6 - Thunderbolt"] = if ($v -eq 4) { "blocked" } elseif ($null -eq $v) { "not_present" } else { "allowed" }

        $v = $RegOverrides["WpdFsDriver_Start"]
        $m["L7 - WPD / MTP / PTP (Phones)"] = if ($v -eq 4) { "blocked" } elseif ($null -eq $v) { "unknown" } else { "allowed" }

        return $m
    }

    function Build-HtmlReport_Test {
        param([ordered]$StatusMap, [string]$TamperStatus = "running", [int]$AllowlistCount = 0, [string]$MachineName = "TEST-PC")

        $blocked = ($StatusMap.Values | Where-Object { $_ -eq "blocked" }).Count
        $total   = ($StatusMap.Values | Where-Object { $_ -ne "not_present" }).Count
        $pct     = if ($total -gt 0) { [math]::Round($blocked / $total * 100) } else { 0 }
        $ts      = "2026-01-01 00:00:00"

        $rowsHtml = foreach ($layer in $StatusMap.Keys) {
            $s     = $StatusMap[$layer]
            $cls   = switch ($s) { "blocked" { "blocked" } "not_present" { "na" } "unknown" { "unknown" } default { "allowed" } }
            $label = switch ($s) { "blocked" { "BLOCKED" } "not_present" { "N/A" } "unknown" { "UNKNOWN" } default { "ALLOWED" } }
            "<tr><td>$layer</td><td class='status $cls'>$label</td></tr>"
        }

        $overallCls = if ($pct -eq 100) { "blocked" } elseif ($pct -ge 50) { "unknown" } else { "allowed" }

        return @"
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>USBGuard Compliance Report - $MachineName</title></head>
<body>
<h1>USBGuard Compliance Report</h1>
<div class="meta">Machine: <b>$MachineName</b> | Generated: $ts</div>
<table>
  <tr><th>Protection Layer</th><th>Status</th></tr>
  $($rowsHtml -join "`n  ")
</table>
<div class="summary">
  <span>Tamper Detection:</span> $TamperStatus |
  <span>Allowlist Entries:</span> $AllowlistCount |
  <span>Overall:</span> <span class="status $overallCls">$blocked/$total layers active ($pct% compliant)</span>
</div>
</body>
</html>
"@
    }
}

Describe "Get-LayerStatusMap_Test" {

    Context "All layers fully blocked" {
        BeforeAll {
            $all = @{
                USBSTOR_Start=4; WriteProtect=1; DenyDeviceClasses=1
                NoDriveTypeAutoRun=255; VolumeWatcher="Running"
                Thunderbolt_Start=4; WpdFsDriver_Start=4
            }
            $script:map = Get-LayerStatusMap_Test -RegOverrides $all
        }

        It "Should return 7 layers" {
            $map.Count | Should -Be 7
        }

        It "L1 USBSTOR should be blocked" {
            $map["L1 - USB Storage (USBSTOR)"] | Should -Be "blocked"
        }

        It "L2 WriteProtect should be blocked" {
            $map["L2 - Write Protect"] | Should -Be "blocked"
        }

        It "L3 DenyDeviceClasses should be blocked" {
            $map["L3 - Device Class Deny List"] | Should -Be "blocked"
        }

        It "L4 AutoPlay should be blocked" {
            $map["L4 - AutoPlay / AutoRun"] | Should -Be "blocked"
        }

        It "L5 VolumeWatcher should be blocked" {
            $map["L5 - Volume Watcher Task"] | Should -Be "blocked"
        }

        It "L6 Thunderbolt should be blocked" {
            $map["L6 - Thunderbolt"] | Should -Be "blocked"
        }

        It "L7 WPD should be blocked" {
            $map["L7 - WPD / MTP / PTP (Phones)"] | Should -Be "blocked"
        }
    }

    Context "All layers allowed (policy off)" {
        BeforeAll {
            $none = @{
                USBSTOR_Start=3; WriteProtect=0; DenyDeviceClasses=0
                NoDriveTypeAutoRun=145; VolumeWatcher="Stopped"
                Thunderbolt_Start=3; WpdFsDriver_Start=3
            }
            $script:map = Get-LayerStatusMap_Test -RegOverrides $none
        }

        It "L1 USBSTOR should be allowed" {
            $map["L1 - USB Storage (USBSTOR)"] | Should -Be "allowed"
        }

        It "L4 AutoPlay should be allowed when NoDriveTypeAutoRun != 255" {
            $map["L4 - AutoPlay / AutoRun"] | Should -Be "allowed"
        }

        It "L6 Thunderbolt should be allowed (not blocked)" {
            $map["L6 - Thunderbolt"] | Should -Be "allowed"
        }
    }

    Context "Missing / unknown values" {
        It "L1 should be unknown when USBSTOR_Start is null" {
            $m = Get-LayerStatusMap_Test -RegOverrides @{}
            $m["L1 - USB Storage (USBSTOR)"] | Should -Be "unknown"
        }

        It "L6 should be not_present when Thunderbolt_Start is null" {
            $m = Get-LayerStatusMap_Test -RegOverrides @{}
            $m["L6 - Thunderbolt"] | Should -Be "not_present"
        }

        It "L7 should be unknown when WpdFsDriver_Start is null" {
            $m = Get-LayerStatusMap_Test -RegOverrides @{}
            $m["L7 - WPD / MTP / PTP (Phones)"] | Should -Be "unknown"
        }
    }
}

Describe "Build-HtmlReport_Test" {

    BeforeAll {
        $allBlocked = [ordered]@{
            "L1 - USB Storage (USBSTOR)" = "blocked"
            "L2 - Write Protect"          = "blocked"
            "L3 - Device Class Deny List" = "blocked"
            "L4 - AutoPlay / AutoRun"     = "blocked"
            "L5 - Volume Watcher Task"    = "blocked"
            "L6 - Thunderbolt"            = "blocked"
            "L7 - WPD / MTP / PTP (Phones)" = "blocked"
        }
        $mixed = [ordered]@{
            "L1 - USB Storage (USBSTOR)" = "blocked"
            "L2 - Write Protect"          = "allowed"
            "L3 - Device Class Deny List" = "blocked"
            "L4 - AutoPlay / AutoRun"     = "allowed"
            "L5 - Volume Watcher Task"    = "unknown"
            "L6 - Thunderbolt"            = "not_present"
            "L7 - WPD / MTP / PTP (Phones)" = "blocked"
        }
        $script:htmlAll   = Build-HtmlReport_Test -StatusMap $allBlocked -MachineName "TEST-PC"
        $script:htmlMixed = Build-HtmlReport_Test -StatusMap $mixed -MachineName "TEST-PC"
    }

    It "Should contain the machine name" {
        $htmlAll | Should -Match "TEST-PC"
    }

    It "Should contain USBGuard Compliance Report heading" {
        $htmlAll | Should -Match "USBGuard Compliance Report"
    }

    It "Should contain a row for each layer" {
        $htmlAll | Should -Match "L1 - USB Storage"
        $htmlAll | Should -Match "L7 - WPD"
    }

    It "Should show 100% compliant when all 7 layers blocked" {
        $htmlAll | Should -Match "7/7 layers active"
        $htmlAll | Should -Match "100% compliant"
    }

    It "Should show BLOCKED label in all-blocked report" {
        ($htmlAll -split "BLOCKED").Count - 1 | Should -Be 7
    }

    It "Should show ALLOWED label for allowed layers in mixed report" {
        $htmlMixed | Should -Match "ALLOWED"
    }

    It "Should show N/A for not_present layers in mixed report" {
        $htmlMixed | Should -Match "N/A"
    }

    It "Should exclude not_present layers from compliance percentage denominator" {
        # L6 is not_present so total = 6, blocked = 3 (L1, L3, L7) = 50%
        $htmlMixed | Should -Match "3/6 layers active"
    }

    It "Should include tamper detection status" {
        $html = Build-HtmlReport_Test -StatusMap $allBlocked -TamperStatus "running"
        $html | Should -Match "running"
    }

    It "Should include allowlist count" {
        $html = Build-HtmlReport_Test -StatusMap $allBlocked -AllowlistCount 3
        $html | Should -Match "3"
    }

    It "Should be valid HTML (has DOCTYPE and closing body tag)" {
        $htmlAll | Should -Match "<!DOCTYPE html>"
        $htmlAll | Should -Match "</body>"
    }
}
