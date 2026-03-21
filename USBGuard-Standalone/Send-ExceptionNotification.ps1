<#
.SYNOPSIS
    USBGuard - Exception Expiry Webhook Notification

.DESCRIPTION
    Posts a notification to a Microsoft Teams or Slack webhook when a USB
    exception is granted (or is about to expire). Designed to be called
    from BigFix Fixlet 4 or the standalone unblock workflow.

    Teams format  : Adaptive Card (v1.4)
    Slack format  : Block Kit message

.PARAMETER WebhookUrl
    The incoming webhook URL for Teams or Slack.

.PARAMETER MachineName
    The machine name the exception was granted to. Defaults to $env:COMPUTERNAME.

.PARAMETER GrantedBy
    The user/admin who granted the exception. Defaults to current user.

.PARAMETER ExpiryHours
    How many hours the exception window is. Defaults to 8.

.PARAMETER ExpiryTime
    The exact expiry datetime as a string (e.g. "14:30 on 2026-03-22").
    If omitted, calculated from ExpiryHours.

.PARAMETER Platform
    "Teams" or "Slack". Defaults to "Teams".

.PARAMETER EventType
    "granted" or "expiring". Changes the card title/colour. Defaults to "granted".

.EXAMPLE
    .\Send-ExceptionNotification.ps1 -WebhookUrl "https://..." -Platform Slack

.EXAMPLE
    .\Send-ExceptionNotification.ps1 -WebhookUrl "https://..." -MachineName "DESKTOP-ABC" `
        -GrantedBy "jsmith" -ExpiryHours 4 -Platform Teams

.NOTES
    No admin required. Does not touch the registry.
    Works on Windows 10/11 and Windows Server 2019+.
#>

param(
    [Parameter(Mandatory)]
    [string]$WebhookUrl,

    [string]$MachineName = $env:COMPUTERNAME,

    [string]$GrantedBy   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,

    [int]$ExpiryHours    = 8,

    [string]$ExpiryTime  = "",

    [ValidateSet("Teams","Slack")]
    [string]$Platform    = "Teams",

    [ValidateSet("granted","expiring")]
    [string]$EventType   = "granted"
)

if (-not $ExpiryTime) {
    $ExpiryTime = (Get-Date).AddHours($ExpiryHours).ToString("HH:mm 'on' yyyy-MM-dd")
}

# ── Payload builders ──────────────────────────────────────────────────────────
function Build-TeamsPayload {
    param(
        [string]$MachineName,
        [string]$GrantedBy,
        [string]$ExpiryTime,
        [int]$ExpiryHours,
        [string]$EventType
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
                        @{
                            type   = "TextBlock"
                            size   = "Large"
                            weight = "Bolder"
                            text   = $title
                            color  = $color
                        },
                        @{
                            type = "FactSet"
                            facts = @(
                                @{ title = "Machine";    value = $MachineName }
                                @{ title = "Granted By"; value = $GrantedBy   }
                                @{ title = "Expires At"; value = $ExpiryTime  }
                                @{ title = "Window";     value = "$ExpiryHours hours" }
                            )
                        },
                        @{
                            type = "TextBlock"
                            wrap = $true
                            text = $body
                        }
                    )
                }
            }
        )
    }

    return $payload | ConvertTo-Json -Depth 10
}

function Build-SlackPayload {
    param(
        [string]$MachineName,
        [string]$GrantedBy,
        [string]$ExpiryTime,
        [int]$ExpiryHours,
        [string]$EventType
    )

    $emoji = if ($EventType -eq "granted") { ":warning:" } else { ":rotating_light:" }
    $title = if ($EventType -eq "granted") { "USB Exception Granted" } else { "USB Exception Expiring" }

    $payload = @{
        blocks = @(
            @{
                type = "header"
                text = @{ type = "plain_text"; text = "$emoji $title" }
            },
            @{
                type   = "section"
                fields = @(
                    @{ type = "mrkdwn"; text = "*Machine:*`n$MachineName"   }
                    @{ type = "mrkdwn"; text = "*Granted By:*`n$GrantedBy"  }
                    @{ type = "mrkdwn"; text = "*Expires At:*`n$ExpiryTime" }
                    @{ type = "mrkdwn"; text = "*Window:*`n$ExpiryHours hours" }
                )
            },
            @{
                type = "divider"
            },
            @{
                type = "context"
                elements = @(
                    @{ type = "mrkdwn"; text = "USBGuard | Re-apply Fixlets 1+2+3 after the exception window." }
                )
            }
        )
    }

    return $payload | ConvertTo-Json -Depth 10
}

# ── Send ──────────────────────────────────────────────────────────────────────
function Send-WebhookNotification {
    param([string]$WebhookUrl, [string]$Payload)

    $response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $Payload `
        -ContentType "application/json" -ErrorAction Stop
    return $response
}

# ── Main ──────────────────────────────────────────────────────────────────────
$payload = switch ($Platform) {
    "Teams" { Build-TeamsPayload -MachineName $MachineName -GrantedBy $GrantedBy -ExpiryTime $ExpiryTime -ExpiryHours $ExpiryHours -EventType $EventType }
    "Slack" { Build-SlackPayload -MachineName $MachineName -GrantedBy $GrantedBy -ExpiryTime $ExpiryTime -ExpiryHours $ExpiryHours -EventType $EventType }
}

Write-Host "Sending $EventType notification to $Platform for machine: $MachineName"

try {
    Send-WebhookNotification -WebhookUrl $WebhookUrl -Payload $payload
    Write-Host "Notification sent successfully." -ForegroundColor Green
    exit 0
} catch {
    Write-Host "Failed to send notification: $_" -ForegroundColor Red
    exit 1
}
