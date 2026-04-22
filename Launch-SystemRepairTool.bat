@echo off
setlocal
:: ============================================================
::  System Repair & Update Tool - Launcher
:: ============================================================
::
::  Launches the PowerShell GUI and exits immediately. The cmd
::  window should not linger after launch.
::
::  Flow:
::    1. Check for admin. If not elevated, relaunch self via
::       PowerShell with -Verb RunAs (UAC prompt), then exit.
::    2. Once elevated, Start-Process the PowerShell GUI with
::       hidden window style, then exit immediately.
::
::  The GUI itself is WPF (draws its own window), so hiding the
::  host powershell.exe console window does not affect the GUI's
::  visibility.
:: ============================================================

:: ---- Step 1: Admin check ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    :: Not elevated. Relaunch self with UAC, then exit silently.
    powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: ---- Step 2: Launch GUI detached, then exit ----
:: Use PowerShell's Start-Process with -WindowStyle Hidden so the
:: host console never flashes visible. The bat returns immediately
:: without waiting for the GUI to close.
cd /d "%~dp0"
powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-ExecutionPolicy','Bypass','-NoProfile','-WindowStyle','Hidden','-File','%~dp0Tools\SystemRepairTool.ps1' -WindowStyle Hidden"

endlocal
exit /b
