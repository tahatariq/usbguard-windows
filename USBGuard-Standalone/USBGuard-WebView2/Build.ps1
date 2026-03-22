#Requires -Version 5.1
<#
.SYNOPSIS
    Build USBGuard WebView2 host application.

.DESCRIPTION
    Compiles USBGuard.exe (WebView2 WinForms host) targeting .NET 8 x64.
    Requires .NET 8 SDK (https://dotnet.microsoft.com/download).

.EXAMPLE
    .\Build.ps1            # Debug build (fast, for development)
    .\Build.ps1 -Release   # Single-file self-contained release exe

.NOTES
    Output goes to:
      Debug:   bin\Debug\net8.0-windows\win-x64\USBGuard.exe
      Release: bin\Release\net8.0-windows\win-x64\publish\USBGuard.exe

    After a Release build, copy the publish\ folder contents alongside
    USBGuard.ps1, or update Launch_USBGuard.bat to point at the publish path.
#>
param(
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
$ProjectDir = $PSScriptRoot

# Verify dotnet SDK is available
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error ".NET SDK not found. Download from https://dotnet.microsoft.com/download"
    exit 1
}

$sdkVersion = (dotnet --version 2>&1) -as [string]
Write-Host "Using .NET SDK $sdkVersion" -ForegroundColor Cyan

Push-Location $ProjectDir
try {
    if ($Release) {
        Write-Host "`nPublishing release build (single-file, self-contained)..." -ForegroundColor Yellow
        dotnet publish USBGuard.csproj `
            -c Release `
            -r win-x64 `
            --self-contained true `
            -p:PublishSingleFile=true `
            -p:IncludeNativeLibrariesForSelfExtract=true `
            -p:EnableCompressionInSingleFile=true `
            -o "$ProjectDir\bin\Release\net8.0-windows\win-x64\publish"

        $exe = "$ProjectDir\bin\Release\net8.0-windows\win-x64\publish\USBGuard.exe"
    } else {
        Write-Host "`nBuilding debug..." -ForegroundColor Yellow
        dotnet build USBGuard.csproj -c Debug

        $exe = "$ProjectDir\bin\Debug\net8.0-windows\USBGuard.exe"
    }

    if (Test-Path $exe) {
        $size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
        Write-Host "`nBuild succeeded: $exe ($size MB)" -ForegroundColor Green
    } else {
        Write-Error "Build appeared to succeed but output exe not found at: $exe"
    }
} finally {
    Pop-Location
}
