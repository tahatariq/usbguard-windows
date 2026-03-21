#!/usr/bin/env powershell
<#
.SYNOPSIS
    Run all tests locally with detailed reporting
.DESCRIPTION
    Executes unit tests, integration tests, and generates coverage reports
.EXAMPLE
    .\Run-Tests.ps1
    .\Run-Tests.ps1 -Unit
    .\Run-Tests.ps1 -Integration
#>
param(
    [switch]$Unit,
    [switch]$Integration,
    [switch]$All,
    [switch]$Coverage,
    [string]$Filter
)

$ErrorActionPreference = "Stop"

# Install Pester if not available
if (-not (Get-Module Pester -ListAvailable)) {
    Write-Host "Installing Pester..." -ForegroundColor Cyan
    Install-Module -Name Pester -Force -SkipPublisherCheck
}

Import-Module Pester

$testDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$unitTests = Join-Path $testDir "tests/unit"
$integrationTests = Join-Path $testDir "tests/integration"

function Invoke-TestRun {
    param(
        [string]$Path,
        [string]$Name,
        [switch]$IncludeCoverage
    )
    
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "Running $Name Tests" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
    $config = New-PesterConfiguration
    $config.Run.Path = $Path
    $config.Output.Verbosity = "Detailed"
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = "test-results-$(Get-Date -Format 'yyyyMMdd_HHmmss').xml"
    
    if ($IncludeCoverage -and $Coverage) {
        $config.CodeCoverage.Enabled = $true
        $config.CodeCoverage.Path = @(
            "$testDir/USBGuard-Standalone/USBGuard.ps1",
            "$testDir/USBGuard-Standalone/USBGuard_Advanced.ps1"
        )
    }
    
    if ($Filter) {
        $config.Filter.FullName = "*$Filter*"
    }
    
    $result = Invoke-Pester -Configuration $config
    return $result
}

# Determine which tests to run
$runUnit = $Unit -or $All -or (-not $Integration -and -not $All)
$runIntegration = $Integration -or $All

$unitResult = $null
$integrationResult = $null

if ($runUnit) {
    $unitResult = Invoke-TestRun -Path $unitTests -Name "Unit" -IncludeCoverage
}

if ($runIntegration) {
    $integrationResult = Invoke-TestRun -Path $integrationTests -Name "Integration"
}

# Summary
Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

if ($unitResult) {
    $passed = $unitResult.Containers.Tests.Where({ $_.Result -eq 'Passed' }).Count
    $failed = $unitResult.Containers.Tests.Where({ $_.Result -eq 'Failed' }).Count
    Write-Host "Unit Tests: $passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
}

if ($integrationResult) {
    $passed = $integrationResult.Containers.Tests.Where({ $_.Result -eq 'Passed' }).Count
    $failed = $integrationResult.Containers.Tests.Where({ $_.Result -eq 'Failed' }).Count
    Write-Host "Integration Tests: $passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
}

# Exit with appropriate code
$allFailed = 0
if ($unitResult -and $unitResult.FailedCount -gt 0) { $allFailed = 1 }
if ($integrationResult -and $integrationResult.FailedCount -gt 0) { $allFailed = 1 }

exit $allFailed
