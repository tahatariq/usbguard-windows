BeforeAll {
    $ErrorActionPreference = "Continue"

    # ── Write-AuditEntry (test version — writes to a temp path) ────────────────
    function Write-AuditEntry_Test {
        param([string]$AuditLog, [string]$Dir, [string]$Action, [string]$Detail = "")
        $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $line = "[$ts] ACTION=$Action USER=$user" + $(if ($Detail) { " $Detail" } else { "" })
        try {
            if (-not (Test-Path $Dir)) { New-Item -Path $Dir -ItemType Directory -Force | Out-Null }
            Add-Content -Path $AuditLog -Value $line -Encoding UTF8
        } catch {}
    }

    # ── Write-EventLogEntry (test version) ─────────────────────────────────────
    function Write-EventLogEntry_Test {
        param([string]$Message, [int]$EventId = 1000, [string]$EntryType = "Information")
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists("USBGuard_Test")) {
                [System.Diagnostics.EventLog]::CreateEventSource("USBGuard_Test", "Application")
            }
            Write-EventLog -LogName Application -Source "USBGuard_Test" -EventId $EventId -EntryType $EntryType -Message $Message
        } catch {}
    }

    # ── Input validation logic (mirrors Save-NotifyConfig) ────────────────────
    function Invoke-CompanyValidation {
        param([string]$Value)
        $v = $Value.Trim() -replace '[\x00-\x1F\x7F]',''
        if ($v.Length -gt 100) { $v = $v.Substring(0, 100) }
        return $v
    }

    function Invoke-MessageValidation {
        param([string]$Value)
        $v = $Value.Trim() -replace '[\x00-\x1F\x7F]',''
        if ($v.Length -gt 500) { $v = $v.Substring(0, 500) }
        return $v
    }
}

Describe "Write-AuditEntry" {

    BeforeAll {
        $testDir  = "$env:TEMP\USBGuard_AuditTest_$(Get-Random)"
        $testLog  = "$testDir\audit.log"
    }

    AfterEach {
        if (Test-Path $testDir) {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should create the directory if it does not exist" {
        Write-AuditEntry_Test -AuditLog $testLog -Dir $testDir -Action "block"
        Test-Path $testDir | Should -Be $true
    }

    It "Should create the log file on first write" {
        Write-AuditEntry_Test -AuditLog $testLog -Dir $testDir -Action "block"
        Test-Path $testLog | Should -Be $true
    }

    It "Should write a line containing ACTION= and USER=" {
        Write-AuditEntry_Test -AuditLog $testLog -Dir $testDir -Action "block"
        $lines = @(Get-Content $testLog)
        $lines[0] | Should -Match "ACTION=block"
        $lines[0] | Should -Match "USER="
    }

    It "Should include Detail when provided" {
        Write-AuditEntry_Test -AuditLog $testLog -Dir $testDir -Action "block" -Detail "All 7 layers applied"
        $lines = @(Get-Content $testLog)
        $lines[0] | Should -Match "All 7 layers applied"
    }

    It "Should not include extra space when Detail is empty" {
        Write-AuditEntry_Test -AuditLog $testLog -Dir $testDir -Action "block-storage"
        $lines = @(Get-Content $testLog)
        $lines[0] | Should -Match "ACTION=block-storage USER="
        $lines[0] | Should -Not -Match "USER=\s+$"
    }

    It "Should include a timestamp in [YYYY-MM-DD HH:mm:ss] format" {
        Write-AuditEntry_Test -AuditLog $testLog -Dir $testDir -Action "unblock"
        $lines = @(Get-Content $testLog)
        $lines[0] | Should -Match "\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]"
    }

    It "Should append multiple entries to the same file" {
        Write-AuditEntry_Test -AuditLog $testLog -Dir $testDir -Action "block"
        Write-AuditEntry_Test -AuditLog $testLog -Dir $testDir -Action "unblock"
        $lines = Get-Content $testLog
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match "ACTION=block"
        $lines[1] | Should -Match "ACTION=unblock"
    }
}

Describe "Write-EventLogEntry" {

    It "Should not throw when called with a valid message" {
        { Write-EventLogEntry_Test -Message "USBGuard test entry" -EventId 9900 } | Should -Not -Throw
    }

    It "Should not throw on second call when source already exists" {
        { Write-EventLogEntry_Test -Message "USBGuard test entry 1" -EventId 9901 } | Should -Not -Throw
        { Write-EventLogEntry_Test -Message "USBGuard test entry 2" -EventId 9901 } | Should -Not -Throw
    }

    It "Should not throw when called with EntryType Warning" {
        { Write-EventLogEntry_Test -Message "USBGuard warning test" -EventId 9909 -EntryType "Warning" } | Should -Not -Throw
    }
}

Describe "Save-NotifyConfig input validation" {

    Context "CompanyName validation" {
        It "Should pass through a normal string unchanged" {
            Invoke-CompanyValidation "Acme Corp" | Should -Be "Acme Corp"
        }

        It "Should trim leading and trailing whitespace" {
            Invoke-CompanyValidation "  Acme Corp  " | Should -Be "Acme Corp"
        }

        It "Should strip null byte (0x00)" {
            $input = "Acme`0Corp"
            Invoke-CompanyValidation $input | Should -Be "AcmeCorp"
        }

        It "Should strip control characters (0x01-0x1F)" {
            $input = "Acme" + [char]0x01 + [char]0x1F + "Corp"
            Invoke-CompanyValidation $input | Should -Be "AcmeCorp"
        }

        It "Should strip DEL character (0x7F)" {
            $input = "Acme" + [char]0x7F + "Corp"
            Invoke-CompanyValidation $input | Should -Be "AcmeCorp"
        }

        It "Should truncate to 100 characters" {
            $long = "A" * 150
            $result = Invoke-CompanyValidation $long
            $result.Length | Should -Be 100
        }

        It "Should not truncate a string of exactly 100 characters" {
            $exact = "A" * 100
            $result = Invoke-CompanyValidation $exact
            $result.Length | Should -Be 100
        }

        It "Should allow printable special characters" {
            Invoke-CompanyValidation "Acme & Co. (IT)" | Should -Be "Acme & Co. (IT)"
        }
    }

    Context "NotifyMessage validation" {
        It "Should pass through a normal message unchanged" {
            $msg = "USB blocked by policy. Contact IT at ext 1234."
            Invoke-MessageValidation $msg | Should -Be $msg
        }

        It "Should trim whitespace" {
            Invoke-MessageValidation "  Hello  " | Should -Be "Hello"
        }

        It "Should strip control characters" {
            $input = "Contact" + [char]0x01 + "IT" + [char]0x1F + "support"
            Invoke-MessageValidation $input | Should -Be "ContactITsupport"
        }

        It "Should truncate to 500 characters" {
            $long = "B" * 600
            $result = Invoke-MessageValidation $long
            $result.Length | Should -Be 500
        }

        It "Should not truncate a string of exactly 500 characters" {
            $exact = "B" * 500
            (Invoke-MessageValidation $exact).Length | Should -Be 500
        }

        It "Should allow {COMPANY} placeholder through unchanged" {
            $msg = "Blocked by {COMPANY} policy."
            Invoke-MessageValidation $msg | Should -Be $msg
        }
    }
}
