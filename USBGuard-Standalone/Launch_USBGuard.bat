@echo off
:: USBGuard Launcher - Ensures Administrator privileges

:: Check if already admin
net session >nul 2>&1
if %errorlevel% == 0 goto :RUN_APP

:: Not admin - request elevation via PowerShell UAC prompt
echo Requesting Administrator privileges...
powershell -Command "Start-Process '%~f0' -Verb RunAs"
exit /b

:RUN_APP
cd /d "%~dp0"

:: Prefer WebView2 (Chromium) host if built; fall back to legacy HTA (MSHTML)
if exist "%~dp0USBGuard-WebView2\USBGuard.exe" (
    start "" "%~dp0USBGuard-WebView2\USBGuard.exe"
) else (
    mshta.exe "%~dp0USBGuard.hta"
)
