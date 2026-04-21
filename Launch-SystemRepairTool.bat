@echo off
setlocal
:: ============================================================
::  System Repair & Update Tool - Launcher
:: ============================================================
:: Check for admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
:: We are admin. cd into the script's folder so relative paths work.
cd /d "%~dp0"
echo.
echo ============================================================
echo   System Repair and Update Tool
echo   Launching GUI...
echo ============================================================
echo.
:: Run the PowerShell GUI from the Tools subfolder.
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Tools\SystemRepairTool.ps1"
set "PSEXIT=%errorlevel%"
echo.
echo ============================================================
echo   PowerShell exited with code: %PSEXIT%
echo ============================================================
echo.
echo If the GUI did not appear, scroll up to see any error messages.
echo Press any key to close this window...
pause >nul
endlocal
