<#
.SYNOPSIS
    Mock Registry Helper Module for Testing
.DESCRIPTION
    Provides safe registry operations for unit and integration tests without
    modifying actual system registry. Uses temporary test paths.
.EXAMPLE
    Import-Module ./test-helpers/MockRegistry.psm1
    $mock = New-MockRegistry
    $mock.SetDWord("TestPath", "Value", 1)
#>

class MockRegistry {
    [hashtable]$Data
    
    MockRegistry() {
        $this.Data = @{}
    }
    
    [void] CreatePath([string]$Path) {
        if (-not $this.Data.ContainsKey($Path)) {
            $this.Data[$Path] = @{}
        }
    }
    
    [void] SetDWord([string]$Path, [string]$Name, [int]$Value) {
        $this.CreatePath($Path)
        $this.Data[$Path][$Name] = @{ Type = "DWord"; Value = $Value }
    }
    
    [void] SetString([string]$Path, [string]$Name, [string]$Value) {
        $this.CreatePath($Path)
        $this.Data[$Path][$Name] = @{ Type = "String"; Value = $Value }
    }
    
    [object] GetValue([string]$Path, [string]$Name) {
        if ($this.Data.ContainsKey($Path) -and $this.Data[$Path].ContainsKey($Name)) {
            return $this.Data[$Path][$Name].Value
        }
        return $null
    }
    
    [bool] PathExists([string]$Path) {
        return $this.Data.ContainsKey($Path)
    }
    
    [bool] ValueExists([string]$Path, [string]$Name) {
        return $this.PathExists($Path) -and $this.Data[$Path].ContainsKey($Name)
    }
    
    [void] RemoveValue([string]$Path, [string]$Name) {
        if ($this.PathExists($Path)) {
            $this.Data[$Path].Remove($Name)
        }
    }
    
    [void] RemovePath([string]$Path) {
        $this.Data.Remove($Path)
    }
    
    [string[]] GetProperties([string]$Path) {
        if ($this.PathExists($Path)) {
            return @($this.Data[$Path].Keys)
        }
        return @()
    }
    
    [void] Clear() {
        $this.Data.Clear()
    }
    
    [hashtable] Export() {
        return $this.Data.Clone()
    }
}

# Public functions
function New-MockRegistry {
    <#
    .SYNOPSIS
        Create a new mock registry instance
    #>
    [OutputType([MockRegistry])]
    param()
    return [MockRegistry]::new()
}

function Test-RegistryOperation {
    <#
    .SYNOPSIS
        Test a registry operation against mock registry
    #>
    param(
        [MockRegistry]$Registry,
        [scriptblock]$Operation,
        [string]$Description
    )
    
    Write-Host "Testing: $Description" -ForegroundColor Cyan
    try {
        & $Operation -Registry $Registry
        Write-Host "✓ Passed" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "✗ Failed: $_" -ForegroundColor Red
        return $false
    }
}

Export-ModuleMember -Function @(
    'New-MockRegistry',
    'Test-RegistryOperation'
) -Variable @()
