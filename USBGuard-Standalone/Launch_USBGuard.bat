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
:: Set execution policy for this session and launch HTA
cd /d "%~dp0"
mshta.exe "%~dp0USBGuard.hta"
