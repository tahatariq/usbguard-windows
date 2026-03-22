# Testing & Automation Guide

## Overview

USBGuard now includes a complete testing and automation framework with:
- ✅ Unit tests for registry operations
- ✅ Integration tests for block/unblock roundtrips
- ✅ GitHub Actions CI/CD pipeline
- ✅ Local test runner
- ✅ Mock registry helper for safe testing

---

## Running Tests Locally

### Prerequisites

```powershell
# Ensure Pester is installed (v5+)
Install-Module -Name Pester -Force -SkipPublisherCheck
```

### Run All Tests

```powershell
cd /path/to/usbguard-windows
.\Run-Tests.ps1
```

### Run Specific Test Suites

```powershell
# Unit tests only
.\Run-Tests.ps1 -Unit

# Integration tests only
.\Run-Tests.ps1 -Integration

# All tests
.\Run-Tests.ps1 -All

# With code coverage
.\Run-Tests.ps1 -Coverage

# Filter by test name
.\Run-Tests.ps1 -Filter "Registry"
```

### Expected Output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Running Unit Tests
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describing Registry Helper Functions
  Context Ensure-RegPath
    ✓ Should create a registry path that does not exist (52ms)
    ✓ Should not fail if path already exists (31ms)
  Context Set-RegDWord
    ✓ Should set a DWord value and create path if needed (48ms)
    ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Test Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Unit Tests: 41 passed, 0 failed
Integration Tests: 15 passed, 0 failed
```

---

## Test Structure

### Unit Tests (`tests/unit/`)

#### Registry.Tests.ps1
Tests core registry helper functions in isolation:
- `Ensure-RegPath` - Path creation
- `Set-RegDWord` - DWord value setting
- `Remove-RegValue` - Safe value removal
- `Save-OriginalStart` / `Get-SavedStart` - Original value preservation
- `Add-GuidToDenyList` - GUID addition (duplicate prevention)
- `Remove-GuidFromDenyList` - GUID removal

**Key Tests:**
- Idempotent operations (safe to run twice)
- Null value handling
- Non-existent path handling

#### StatusDetection.Tests.ps1
Tests status check and reporting logic:
- USB storage detection (blocked/allowed)
- WriteProtect state detection
- AutoPlay status checks
- Thunderbolt detection
- JSON parsing and serialization

**Key Tests:**
- Correct interpretation of registry values (4=blocked, 3=allowed, etc.)
- Graceful degradation when keys missing
- JSON output validation

#### WpdMtp.Tests.ps1
Tests Layer 7 (WPD/MTP/PTP) status, block, and unblock logic:
- `Get-WpdStatus` — blocked / partial / allowed detection
- `Block-WpdMtp` — GUID deny list population, service disable, flags set, idempotency
- `Unblock-WpdMtp` — GUID removal, service restore from saved value, fallback to Start=3, deny flags cleared
- Full block→unblock roundtrip

**Key Tests:**
- "partial" state when only GUID or only service is blocked (not both)
- Original Start value preserved; not overwritten on second block
- Services that were already disabled (Start=4) stay disabled after unblock

### Integration Tests (`tests/integration/`)

#### BlockUnblock.Tests.ps1
Tests complete workflows and state transitions:
- Block-then-unblock roundtrips
- Idempotency (block twice safely)
- Original value preservation across block/unblock
- Multi-layer operations
- GUID list integrity
- Notification configuration save/load

**Key Tests:**
- Original state restored after unblock
- Services that were already disabled remain disabled
- Complex multi-layer blocking doesn't interfere
- Special characters in messages handled correctly

---

## GitHub Actions CI/CD Pipeline

Automatic validation runs on:
- Push to `main` or `develop` branches
- Pull requests
- Manual trigger via `workflow_dispatch`

### Pipeline Stages

#### 1. Syntax Check
```yaml
- Tokenizes PowerShell files
- Detects parse errors
- Fails fast on syntax issues
```

#### 2. Pester Tests
```yaml
- Runs unit tests (tests/unit/*.Tests.ps1)
- Runs integration tests (tests/integration/*.Tests.ps1)
- Publishes results to GitHub PR checks
- Generates XML test reports
```

#### 3. Code Analysis (PSScriptAnalyzer)
```yaml
- Scans for code quality issues
- Checks naming conventions
- Detects security vulnerabilities
- Reports warnings and errors
```

#### 4. Registry Path Validation
```yaml
- Verifies critical registry paths are present
- Validates GUID format
- Checks for common typos
```

#### 5. Documentation Check
```yaml
- Ensures README files exist
- Validates markdown syntax
- Reports missing documentation
```

#### 6. Summary & Gate
```yaml
- Aggregates results from all stages
- Blocks merge if tests fail
- Generates summary report
```

#### 7. WebView2 Tests (`webview2-tests` job)
```yaml
- C# xUnit: builds USBGuard-Standalone/USBGuard-WebView2/tests/USBGuard.Tests.csproj
- JS Jest:  runs USBGuard-Standalone/USBGuard-WebView2/tests/app.test.js
- Publishes test-results-webview2-xunit.xml and test-results-webview2-jest.xml
```

### Viewing Results

**In GitHub UI:**
1. Go to Pull Request → Checks tab
2. Click "Test Results" to see Pester output
3. Click "PSScriptAnalyzer" for code analysis

**Download Artifacts:**
```bash
# Test result XML files
test-results-unit.xml
test-results-integration.xml
```

---

## Test Scenarios

### Scenario 1: Block USB Storage

```powershell
# Initial state: USBSTOR Start=3 (enabled)
# Action: Block storage
# Expected: USBSTOR Start=4 (disabled)
# Tests cover:
# - Original value saved to SavedStart registry
# - All 7 layers applied
# - WriteProtect=1
# - AutoPlay disabled
# - VolumeWatcher installed
```

### Scenario 2: Roundtrip (Block → Unblock)

```powershell
# Initial: USBSTOR=3, WriteProtect=0, AutoPlay enabled
# Block:   USBSTOR→4, WriteProtect→1, AutoPlay→disabled
# Unblock: USBSTOR→3, WriteProtect→0, AutoPlay→enabled
# Tests verify state is completely restored
```

### Scenario 3: Idempotency

```powershell
# State 1: Run block
# State 2: Run block again (should be safe)
# Result: State 1 == State 2 (no double-locking)
```

### Scenario 4: Service Already Disabled

```powershell
# Service initially had Start=4 (disabled)
# Block applied (sets Start=4 again)
# Unblock restores to Start=4 (not re-enabled)
# Tests verify don't accidentally enable disabled services
```

---

## Mock Registry Helper

For testing without touching real system registry:

```powershell
Import-Module ./test-helpers/MockRegistry.psm1

# Create mock registry
$mock = New-MockRegistry

# Set values
$mock.SetDWord("HKLM:\Test", "Start", 4)
$mock.SetString("HKLM:\Test", "Name", "Value")

# Query values
$value = $mock.GetValue("HKLM:\Test", "Start")  # Returns 4

# Check existence
if ($mock.PathExists("HKLM:\Test")) { ... }
if ($mock.ValueExists("HKLM:\Test", "Start")) { ... }

# Remove values
$mock.RemoveValue("HKLM:\Test", "Start")
$mock.RemovePath("HKLM:\Test")

# Export for inspection
$exported = $mock.Export()
```

---

## Known Test Limitations

| Aspect | Coverage | Notes |
|--------|----------|-------|
| Registry operations | ✅ Full | Tested with temp registry paths |
| Status detection | ✅ Full | All state transitions covered |
| Block/Unblock logic | ✅ Full | Roundtrip scenarios covered |
| WMI event registration | ⚠️ Partial | WMI events hard to mock in tests |
| Service operations | ⚠️ Partial | Service existence varies by system |
| HTA GUI interactions | ❌ None | Requires manual browser testing |
| Notification toasts | ❌ None | Platform-specific, manual testing |
| WebView2 C# xUnit | ✅ Input validation | `USBGuard-WebView2/tests/InputValidatorTests.cs` |
| WebView2 JS Jest | ✅ `extractStatusJson` regex | `USBGuard-WebView2/tests/app.test.js` |

---

## Extending Tests

### Add New Unit Test

1. Create test file in `tests/unit/`
2. Use Pester `Describe`/`Context`/`It` structure:

```powershell
Describe "New Feature" {
    Context "Specific scenario" {
        It "Should do something" {
            # Arrange
            $setup = ...
            
            # Act
            $result = ...
            
            # Assert
            $result | Should -Be $expected
        }
    }
}
```

### Add Integration Test

1. Create test in `tests/integration/`
2. Follow workflow sequence:

```powershell
Context "Feature Workflow" {
    It "Should complete end-to-end" {
        # Setup initial state
        # Execute block operation
        # Verify intermediate state
        # Execute unblock operation
        # Verify final state
        # Cleanup
    }
}
```

---

## Troubleshooting

### Tests Fail on macOS/Linux

**Issue:** PowerShell for Linux doesn't have `HKLM:\` registry

**Solution:** Tests are Windows-only. Skip on non-Windows:

```powershell
BeforeAll {
    if ($PSVersionTable.Platform -ne "Win32NT") {
        Write-Host "Skipping Windows-only tests"
        return
    }
}
```

### Pester Module Not Found

```powershell
# Install latest Pester
Install-Module -Name Pester -Force -SkipPublisherCheck -Scope CurrentUser

# Import explicitly
Import-Module Pester -Force
```

### Registry Access Denied

Tests must run with administrator privileges:

```powershell
# Check if admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Tests require administrator privileges"
    exit 1
}
```

### GitHub Actions Failures

Check action logs:
1. Go to repository → Actions tab
2. Click workflow run
3. Expand failed job
4. Review detailed output

#### WebView2 Tests (`webview2-tests` job)
- Use `npm install`, not `npm ci` — no `package-lock.json` is committed
- Do NOT pipe jest through `2>&1 | Tee-Object` in PowerShell — it masks jest's real exit code; run jest directly
- If `dotnet test` fails with RID mismatch: `RuntimeIdentifier` must be publish-only in `USBGuard.csproj` (conditional `PropertyGroup`); setting it unconditionally breaks the test project's `ProjectReference`
- If C# build fails with `CS0246 Xunit not found`: check that `<Compile Remove="tests\**" />` entries are present in `USBGuard.csproj` — SDK-style projects auto-include all `**/*.cs` under the project dir

---

## CI/CD Workflow Files

- `.github/workflows/pester-tests.yml` - Main test pipeline
- Additional workflows can be added for:
  - Schedule nightly builds
  - Code coverage reports
  - Automated release builds

---

## Best Practices

✅ **DO:**
- Run tests before committing
- Test both block and unblock paths
- Use meaningful test descriptions
- Clean up test registry entries
- Use mock registry when possible

❌ **DON'T:**
- Modify real HKLM registry in tests
- Leave test registry entries behind
- Skip error handling in tests
- Test GUI interactions in automated tests
- Hard-code registry paths (use variables)

---

## Next Steps

After tests pass locally:
1. Commit changes
2. Push to feature branch
3. Create Pull Request
4. GitHub Actions automatically validates
5. Review CI/CD results in PR checks
6. Merge when all checks pass

For deployment, see `USBGuard-Standalone/README.md` and `USBGuard-BigFix/README.md`.
