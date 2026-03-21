@echo off
rem USBGuard API startup script — invoked by IIS HttpPlatformHandler via web.config.
rem
rem Resolution order:
rem   1. .venv\Scripts\python.exe  (virtual environment in the project root)
rem   2. python.exe on the system PATH (global Python installation)
rem
rem This script avoids hardcoding any Python installation path or version number.
rem Python only needs to be installed; the exact location does not matter.

setlocal

rem Change to the directory containing this script (the project root).
cd /d "%~dp0"

if exist ".venv\Scripts\python.exe" (
    ".venv\Scripts\python.exe" -m uvicorn app.main:app --host 127.0.0.1 --port %HTTP_PLATFORM_PORT%
) else (
    python -m uvicorn app.main:app --host 127.0.0.1 --port %HTTP_PLATFORM_PORT%
)
