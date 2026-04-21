# ============================================================================
#  Install-PaperCutClient.ps1
# ----------------------------------------------------------------------------
#  Standalone PaperCut Print Deploy Client installer/updater.
#
#  Reads the MSI in .\Resources\ next to this script (or ..\Resources\ relative
#  to Tools\), detects the installed version on the machine, and uninstalls/
#  installs as needed. Retries on 1618 (Windows Installer busy) with backoff.
#
#  Launched from SystemRepairTool.ps1's Additional Tools section, or run directly
#  from an elevated PowerShell prompt. Does not touch session state.
#
#  To ship a new PaperCut version: drop the new MSI into Resources\ and replace
#  or leave the old one (newest by LastWriteTime is picked). No code changes.
# ============================================================================

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# Force UTF-8 so any native process output renders cleanly (same pattern as the
# main tool's runspace).
try {
    [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# ----------------------------------------------------------------------------
#  CONSOLE HELPERS
# ----------------------------------------------------------------------------
function Write-Status { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-Info   { param([string]$Msg) Write-Host "    $Msg" -ForegroundColor Gray }
function Write-OK     { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Warn   { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Err    { param([string]$Msg) Write-Host "[x] $Msg" -ForegroundColor Red }

function Write-Banner {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "  PaperCut Print Deploy Client - Install / Update" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host ""
}

# ----------------------------------------------------------------------------
#  MSI METADATA
# ----------------------------------------------------------------------------
# Reads ProductCode, ProductName, ProductVersion from an MSI's database using
# the Windows Installer COM object (WindowsInstaller.Installer). Same technique
# as the original phase implementation.
function Get-MsiMetadata {
    param([string]$MsiPath)
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))
        $props = @{}
        foreach ($prop in @('ProductCode','ProductName','ProductVersion','Manufacturer')) {
            $query = "SELECT Value FROM Property WHERE Property = '$prop'"
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($query))
            $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($record) {
                $props[$prop] = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1)
            }
            $null = $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        }
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($db) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) | Out-Null
        [System.GC]::Collect()
        return $props
    } catch {
        return $null
    }
}

# ----------------------------------------------------------------------------
#  INSTALLED CLIENT DETECTION
# ----------------------------------------------------------------------------
# Scans both 32-bit and 64-bit uninstall hives for entries matching PaperCut
# Print Deploy. Returns all matches so multi-install messes can be cleaned up.
function Get-InstalledPaperCutClient {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $found = @()
    foreach ($hive in $hives) {
        if (-not (Test-Path $hive)) { continue }
        try {
            $entries = Get-ChildItem -Path $hive -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } |
                Where-Object { $_.DisplayName -and ($_.DisplayName -match 'PaperCut.*Print Deploy|Print Deploy Client') }
            foreach ($e in $entries) { $found += $e }
        } catch { }
    }
    return $found
}

# ----------------------------------------------------------------------------
#  MSIEXEC INVOCATION WITH 1618 RETRY
# ----------------------------------------------------------------------------
# Windows Installer is single-threaded - if any other MSI is in progress we get
# 1618 back immediately. Retry with backoff so a transient blip doesn't abort.
function Invoke-MsiExec {
    param(
        [string[]]$ArgList,
        [string]$OperationLabel = 'msiexec'
    )
    $ec = $null
    $attempt = 0
    $max = 4
    while ($attempt -lt $max) {
        $attempt++
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $ArgList -Wait -PassThru -WindowStyle Hidden
        $ec = $p.ExitCode
        if ($ec -eq 1618) {
            $waitSec = 15 * $attempt
            Write-Warn "$OperationLabel exit code 1618 (Windows Installer busy). Waiting ${waitSec}s before retry $attempt/$max..."
            Start-Sleep -Seconds $waitSec
            continue
        }
        break
    }
    return $ec
}

# ============================================================================
#  MAIN
# ============================================================================
Write-Banner

# Locate Resources folder. This script lives in Tools\, Resources\ is a sibling.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$resourcesRoot = Join-Path $scriptDir 'Resources'

Write-Status "Locating bundled MSI..."
Write-Info "Script dir:     $scriptDir"
Write-Info "Resources dir:  $resourcesRoot"

if (-not (Test-Path $resourcesRoot)) {
    Write-Err "Resources folder not found at: $resourcesRoot"
    Write-Err "Create the folder and drop the PaperCut MSI inside, then rerun."
    Write-Host ""
    Write-Host "Press any key to close..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

# Prefer files matching pc-print-deploy-client*.msi, fall back to any .msi
$msiCandidates = @(Get-ChildItem -Path $resourcesRoot -Filter 'pc-print-deploy-client*.msi' -ErrorAction SilentlyContinue)
if (-not $msiCandidates -or $msiCandidates.Count -eq 0) {
    $msiCandidates = @(Get-ChildItem -Path $resourcesRoot -Filter '*.msi' -ErrorAction SilentlyContinue)
}
if (-not $msiCandidates -or $msiCandidates.Count -eq 0) {
    Write-Err "No MSI found in $resourcesRoot"
    Write-Err "Drop a PaperCut MSI (e.g. pc-print-deploy-client_10_0_0_100_.msi) into that folder."
    Write-Host ""
    Write-Host "Press any key to close..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

# If multiple MSIs exist, pick the newest by LastWriteTime
$msiPath = ($msiCandidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
Write-Info "Using MSI:      $(Split-Path -Leaf $msiPath)"
Write-Host ""

# Read bundled MSI metadata
Write-Status "Reading MSI metadata..."
$bundled = Get-MsiMetadata -MsiPath $msiPath
if (-not $bundled -or -not $bundled.ProductVersion) {
    Write-Err "Could not read metadata from $msiPath"
    Write-Err "MSI may be corrupted, blocked by Mark-of-the-Web, or in use. Try right-click > Properties > Unblock."
    Write-Host ""
    Write-Host "Press any key to close..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}
$bundledVer  = $bundled.ProductVersion
$bundledName = if ($bundled.ProductName) { $bundled.ProductName } else { 'PaperCut Print Deploy Client' }
$bundledCode = $bundled.ProductCode
Write-Info "Bundled:        $bundledName v$bundledVer"
Write-Info "ProductCode:    $bundledCode"
Write-Host ""

# Check installed state
Write-Status "Checking installed version..."
$installed = Get-InstalledPaperCutClient
$needInstall = $false
$needUninstall = $false
if (-not $installed -or $installed.Count -eq 0) {
    Write-Info "Not currently installed."
    $needInstall = $true
} else {
    foreach ($e in $installed) {
        Write-Info "Installed:      $($e.DisplayName) v$($e.DisplayVersion)"
    }
    $versionMatch = $installed | Where-Object { $_.DisplayVersion -eq $bundledVer }
    if ($versionMatch) {
        Write-Host ""
        Write-OK "Already at v$bundledVer. Nothing to do."
        Write-Host ""
        Write-Host "Press any key to close..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 0
    }
    $needInstall = $true
    $needUninstall = $true
}
Write-Host ""

# Wait for Windows Installer to be idle before we start (avoids immediate 1618)
Write-Status "Waiting for Windows Installer service to be idle..."
$waitAttempts = 0
while ($waitAttempts -lt 6) {
    $msiProcs = @(Get-Process -Name msiexec -ErrorAction SilentlyContinue)
    if ($msiProcs.Count -le 1) { break }
    $waitAttempts++
    Write-Info "$($msiProcs.Count) msiexec processes running. Waiting 10s (attempt $waitAttempts/6)..."
    Start-Sleep -Seconds 10
}
Write-Host ""

# Uninstall old version(s) if needed
if ($needUninstall) {
    Write-Status "Uninstalling existing version(s)..."
    foreach ($entry in $installed) {
        $productCode = $entry.PSChildName
        $displayName = $entry.DisplayName
        $displayVer  = $entry.DisplayVersion
        Write-Info "Removing: $displayName v$displayVer ($productCode)"

        $uninstallLog = Join-Path $env:TEMP "papercut-uninstall-$([Guid]::NewGuid().ToString('N')).log"
        $ec = Invoke-MsiExec -ArgList @('/x', $productCode, '/qn', '/norestart', '/L*v', "`"$uninstallLog`"") -OperationLabel 'uninstall'

        # 0 = success, 1605 = not installed (fine), 3010 = reboot required (fine, we'll reboot at end)
        if ($ec -in 0, 1605, 3010) {
            Write-Info "  msiexec exit code: $ec (OK)"
            Remove-Item $uninstallLog -Force -ErrorAction SilentlyContinue
        } else {
            Write-Warn "  msiexec returned unexpected code $ec. Log preserved: $uninstallLog"
            Write-Warn "  Continuing with install anyway - install-over-top often works."
        }
    }
    Write-Host ""
}

# Install bundled version
Write-Status "Installing $bundledName v$bundledVer..."
$installLog = Join-Path $env:TEMP "papercut-install-$([Guid]::NewGuid().ToString('N')).log"
$ec = Invoke-MsiExec -ArgList @('/i', "`"$msiPath`"", '/qn', '/norestart', '/L*v', "`"$installLog`"") -OperationLabel 'install'

Write-Host ""
switch ($ec) {
    0 {
        Write-OK "Install successful (exit 0)."
        Remove-Item $installLog -Force -ErrorAction SilentlyContinue
        $exitCode = 0
    }
    3010 {
        Write-OK "Install successful - reboot required to finalize (exit 3010)."
        Write-Warn "Please restart the machine when convenient."
        Remove-Item $installLog -Force -ErrorAction SilentlyContinue
        $exitCode = 0
    }
    1618 {
        Write-Err "Windows Installer stayed busy after 4 retries (exit 1618)."
        Write-Err "Another install is in progress. Try again in a few minutes."
        Write-Info "Install log: $installLog"
        $exitCode = 1618
    }
    1603 {
        Write-Err "Fatal install error (exit 1603)."
        Write-Err "Common causes: running as non-admin, disk full, AV interference, corrupted MSI."
        Write-Info "Install log: $installLog"
        $exitCode = 1603
    }
    default {
        Write-Err "Install failed with exit code $ec."
        Write-Info "Install log: $installLog"
        $exitCode = $ec
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Press any key to close..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
exit $exitCode
