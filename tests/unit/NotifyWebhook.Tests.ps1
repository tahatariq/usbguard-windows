BeforeAll {
    # ── Inline payload builders from Send-ExceptionNotification.ps1 ──────────

    function Build-TeamsPayload_Test {
        param(
            [string]$MachineName  = "TEST-PC",
            [string]$GrantedBy    = "DOMAIN\jsmith",
            [string]$ExpiryTime   = "14:00 on 2026-01-01",
            [int]$ExpiryHours     = 8,
            [string]$EventType    = "granted"
        )

        $title  = if ($EventType -eq "granted") { "USB Exception Granted" }   else { "USB Exception Expiring" }
        $color  = if ($EventType -eq "granted") { "warning" }                  else { "attention" }
        $body   = if ($EventType -eq "granted") {
            "USB policy has been temporarily lifted on **$MachineName**. Policy re-applies at $ExpiryTime."
        } else {
            "The USB exception on **$MachineName** expires at $ExpiryTime. Ensure the device is removed."
        }

        $payload = [ordered]@{
            type        = "message"
            attachments = @(
                @{
                    contentType = "application/vnd.microsoft.card.adaptive"
                    content     = [ordered]@{
                        "`$schema" = "http://adaptivecards.io/schemas/adaptive-card.json"
                        type    = "AdaptiveCard"
                        version = "1.4"
                        body    = @(
                            @{ type = "TextBlock"; size = "Large"; weight = "Bolder"; text = $title; color = $color },
                            @{
                                type  = "FactSet"
                                facts = @(
                                    @{ title = "Machine";    value = $MachineName }
                                    @{ title = "Granted By"; value = $GrantedBy   }
                                    @{ title = "Expires At"; value = $ExpiryTime  }
                                    @{ title = "Window";     value = "$ExpiryHours hours" }
                                )
                            },
                            @{ type = "TextBlock"; wrap = $true; text = $body }
                        )
                    }
                }
            )
        }

        return $payload | ConvertTo-Json -Depth 10
    }

    function Build-SlackPayload_Test {
        param(
            [string]$MachineName  = "TEST-PC",
            [string]$GrantedBy    = "DOMAIN\jsmith",
            [string]$ExpiryTime   = "14:00 on 2026-01-01",
            [int]$ExpiryHours     = 8,
            [string]$EventType    = "granted"
        )

        $emoji = if ($EventType -eq "granted") { ":warning:" } else { ":rotating_light:" }
        $title = if ($EventType -eq "granted") { "USB Exception Granted" } else { "USB Exception Expiring" }

        $payload = @{
            blocks = @(
                @{ type = "header"; text = @{ type = "plain_text"; text = "$emoji $title" } },
                @{
                    type   = "section"
                    fields = @(
                        @{ type = "mrkdwn"; text = "*Machine:*`n$MachineName"    }
                        @{ type = "mrkdwn"; text = "*Granted By:*`n$GrantedBy"   }
                        @{ type = "mrkdwn"; text = "*Expires At:*`n$ExpiryTime"  }
                        @{ type = "mrkdwn"; text = "*Window:*`n$ExpiryHours hours" }
                    )
                },
                @{ type = "divider" },
                @{
                    type     = "context"
                    elements = @( @{ type = "mrkdwn"; text = "USBGuard | Re-apply Fixlets 1+2+3 after the exception window." } )
                }
            )
        }

        return $payload | ConvertTo-Json -Depth 10
    }
}

Describe "Build-TeamsPayload_Test" {

    It "Should return valid JSON" {
        $raw = Build-TeamsPayload_Test
        { $raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It "Should have type = message at root" {
        $obj = Build-TeamsPayload_Test | ConvertFrom-Json
        $obj.type | Should -Be "message"
    }

    It "Should have exactly one attachment" {
        $obj = Build-TeamsPayload_Test | ConvertFrom-Json
        @($obj.attachments).Count | Should -Be 1
    }

    It "Should use AdaptiveCard content type" {
        $obj = Build-TeamsPayload_Test | ConvertFrom-Json
        $obj.attachments[0].contentType | Should -Be "application/vnd.microsoft.card.adaptive"
    }

    It "Should contain the machine name in the facts" {
        $raw = Build-TeamsPayload_Test -MachineName "WORKSTATION-01"
        $raw | Should -Match "WORKSTATION-01"
    }

    It "Should contain the granted-by user in the facts" {
        $raw = Build-TeamsPayload_Test -GrantedBy "CORP\alice"
        $raw | Should -Match "CORP\\\\alice"
    }

    It "Should contain the expiry time in the facts" {
        $raw = Build-TeamsPayload_Test -ExpiryTime "09:00 on 2026-06-15"
        $raw | Should -Match "09:00 on 2026-06-15"
    }

    It "Should use warning color for granted event" {
        $raw = Build-TeamsPayload_Test -EventType "granted"
        $raw | Should -Match "warning"
    }

    It "Should use attention color for expiring event" {
        $raw = Build-TeamsPayload_Test -EventType "expiring"
        $raw | Should -Match "attention"
    }

    It "Should use title 'USB Exception Granted' for granted event" {
        $raw = Build-TeamsPayload_Test -EventType "granted"
        $raw | Should -Match "USB Exception Granted"
    }

    It "Should use title 'USB Exception Expiring' for expiring event" {
        $raw = Build-TeamsPayload_Test -EventType "expiring"
        $raw | Should -Match "USB Exception Expiring"
    }

    It "Should include expiry hours in window fact" {
        $raw = Build-TeamsPayload_Test -ExpiryHours 4
        $raw | Should -Match "4 hours"
    }
}

Describe "Build-SlackPayload_Test" {

    It "Should return valid JSON" {
        $raw = Build-SlackPayload_Test
        { $raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It "Should have a blocks array at root" {
        $obj = Build-SlackPayload_Test | ConvertFrom-Json
        $obj.blocks | Should -Not -BeNullOrEmpty
    }

    It "Should have a header block as first element" {
        $obj = Build-SlackPayload_Test | ConvertFrom-Json
        $obj.blocks[0].type | Should -Be "header"
    }

    It "Should contain the machine name" {
        $raw = Build-SlackPayload_Test -MachineName "LAPTOP-42"
        $raw | Should -Match "LAPTOP-42"
    }

    It "Should contain the expiry time" {
        $raw = Build-SlackPayload_Test -ExpiryTime "18:00 on 2026-12-31"
        $raw | Should -Match "18:00 on 2026-12-31"
    }

    It "Should use :warning: emoji for granted event" {
        $raw = Build-SlackPayload_Test -EventType "granted"
        $raw | Should -Match ":warning:"
    }

    It "Should use :rotating_light: emoji for expiring event" {
        $raw = Build-SlackPayload_Test -EventType "expiring"
        $raw | Should -Match ":rotating_light:"
    }

    It "Should include a divider block" {
        $obj = Build-SlackPayload_Test | ConvertFrom-Json
        $dividers = $obj.blocks | Where-Object { $_.type -eq "divider" }
        @($dividers).Count | Should -BeGreaterThan 0
    }

    It "Should include USBGuard context footer" {
        $raw = Build-SlackPayload_Test
        $raw | Should -Match "USBGuard"
    }
}
