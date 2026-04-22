# Remove-StalePrinters.ps1
# Interactive tool for removing stuck/cached printers from all Windows layers
# Includes registry scan for ghost printers not visible to Get-Printer
# Run as Administrator
#
# Usage: Right-click > Run with PowerShell (as Admin)
#    or: powershell -ExecutionPolicy Bypass -File .\Remove-StalePrinters.ps1

#Requires -RunAsAdministrator

# ============================================================
#  Helpers
# ============================================================

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ====================================================" -ForegroundColor Cyan
    Write-Host "   Stale Printer Removal Tool" -ForegroundColor Cyan
    Write-Host "   System Repair & Update Tool" -ForegroundColor DarkGray
    Write-Host "  ====================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    param(
        [string]$Title,
        [array]$Options,
        [switch]$MultiSelect
    )

    Write-Host "`n$Title" -ForegroundColor Cyan
    Write-Host ("-" * $Title.Length) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Options[$i])"
    }

    if ($MultiSelect) {
        Write-Host "`n  Enter numbers separated by commas (e.g. 1,3,5)" -ForegroundColor Yellow
        Write-Host "  'A' = select all  |  'Q' = quit" -ForegroundColor Yellow
    } else {
        Write-Host "`n  Enter a number or 'Q' to quit:" -ForegroundColor Yellow
    }

    $response = Read-Host "  >"

    if ($response -eq 'Q' -or $response -eq 'q') { return $null }

    if ($MultiSelect -and ($response -eq 'A' -or $response -eq 'a')) {
        return @(0..($Options.Count - 1))
    }

    $indices = @()
    $response -split ',' | ForEach-Object {
        $num = $_.Trim() -as [int]
        if ($num -ge 1 -and $num -le $Options.Count) {
            $indices += ($num - 1)
        }
    }

    if ($indices.Count -eq 0) { return $null }
    return $indices
}

# ============================================================
#  Discovery -- merge Get-Printer + Registry scan
# ============================================================

function Get-AllPrinterEntries {
    # Built-in printers to always exclude
    $excludePattern = "Microsoft|OneNote|PDF|XPS|Fax|Send To|nul|FILE:"

    # --- Source 1: Get-Printer (live printer subsystem) ---
    $livePrinters = @()
    $gpResults = Get-Printer -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notmatch $excludePattern
    }
    foreach ($p in $gpResults) {
        $status = if ($p.PrinterStatus -eq 'Normal') { 'OK' } else { "$($p.PrinterStatus)" }
        $livePrinters += [PSCustomObject]@{
            Name       = $p.Name
            Driver     = $p.DriverName
            Source     = "PrintSubsystem"
            Status     = $status
            PortName   = $p.PortName
        }
    }

    # --- Source 2: Registry scan (catches ghosts) ---
    $regPrinters = @()
    $regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers"
    if (Test-Path $regBase) {
        $regKeys = Get-ChildItem -Path $regBase -ErrorAction SilentlyContinue
        foreach ($key in $regKeys) {
            $name = $key.PSChildName
            if ($name -match $excludePattern) { continue }

            # Skip if already discovered via Get-Printer
            if ($livePrinters.Name -contains $name) { continue }

            # Pull driver name from registry values
            $driver = (Get-ItemProperty -Path $key.PSPath -Name "Printer Driver" -ErrorAction SilentlyContinue).'Printer Driver'
            if (-not $driver) { $driver = "(unknown)" }

            $regPrinters += [PSCustomObject]@{
                Name       = $name
                Driver     = $driver
                Source     = "RegistryGhost"
                Status     = "GHOST"
                PortName   = $null
            }
        }
    }

    # --- Source 3: Driver-only orphans (no printer object, but driver lingers) ---
    $driverOrphans = @()
    $installedDrivers = Get-PrinterDriver -ErrorAction SilentlyContinue
    $knownDriverNames = ($livePrinters.Driver + $regPrinters.Driver) | Sort-Object -Unique

    foreach ($drv in $installedDrivers) {
        if ($drv.Name -match $excludePattern) { continue }
        if ($drv.Name -in $knownDriverNames) { continue }

        # Check if any live printer actually uses this driver
        $inUse = $gpResults | Where-Object { $_.DriverName -eq $drv.Name }
        if (-not $inUse) {
            $driverOrphans += [PSCustomObject]@{
                Name       = "[Driver Only] $($drv.Name)"
                Driver     = $drv.Name
                Source     = "OrphanDriver"
                Status     = "ORPHAN"
                PortName   = $null
            }
        }
    }

    return @($livePrinters + $regPrinters + $driverOrphans)
}

# ============================================================
#  Removal -- walks every layer for a single printer entry
# ============================================================

function Remove-PrinterFully {
    param([PSCustomObject]$Entry)

    $name = $Entry.Name
    $driverName = $Entry.Driver
    $source = $Entry.Source

    Write-Host ""
    Write-Host "  -------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Processing: $name" -ForegroundColor Cyan
    Write-Host "  Source: $source  |  Driver: $driverName" -ForegroundColor DarkGray
    Write-Host "  -------------------------------------------" -ForegroundColor DarkGray

    # Step 1 -- Stop spooler & clear cache
    Write-Host "  [1/5] Stopping spooler and clearing cache..." -ForegroundColor Yellow
    Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"
    if (Test-Path $spoolPath) {
        Remove-Item "$spoolPath\*" -Force -ErrorAction SilentlyContinue
    }
    Start-Service -Name Spooler
    Start-Sleep -Seconds 2

    # Step 2 -- Remove printer object (if it exists in the subsystem)
    Write-Host "  [2/5] Removing printer object..." -ForegroundColor Yellow
    if ($source -ne "OrphanDriver") {
        $actualName = if ($source -eq "OrphanDriver") { $null } else { $name }
        $printer = Get-Printer -Name $actualName -ErrorAction SilentlyContinue
        if ($printer) {
            try {
                Remove-Printer -Name $actualName -Confirm:$false -ErrorAction Stop
                Write-Host "        [OK] Printer object removed." -ForegroundColor Green
            } catch {
                Write-Host "        [!!] Failed: $_" -ForegroundColor Red
            }
        } else {
            Write-Host "        [--] Not in printer subsystem (expected for ghosts)." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "        [--] Driver-only orphan, no printer object to remove." -ForegroundColor DarkGray
    }

    # Step 3 -- Remove driver
    Write-Host "  [3/5] Removing printer driver..." -ForegroundColor Yellow
    if ($driverName -and $driverName -ne "(unknown)") {
        $drvObj = Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue
        if ($drvObj) {
            try {
                Remove-PrinterDriver -Name $driverName -Confirm:$false -ErrorAction Stop
                Write-Host "        [OK] Driver '$driverName' removed." -ForegroundColor Green
            } catch {
                Write-Host "        [!!] Could not remove driver: $_" -ForegroundColor Red
                Write-Host "        Try rebooting, or manually: printui /s /t2 > Drivers tab" -ForegroundColor DarkYellow
            }
        } else {
            Write-Host "        [--] Driver not found (already removed or name mismatch)." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "        [--] Unknown driver, skipping. Check printui /s /t2 manually." -ForegroundColor DarkYellow
    }

    # Step 4 -- Clean orphaned ports
    Write-Host "  [4/5] Cleaning orphaned ports..." -ForegroundColor Yellow
    $protectedPorts = @("LPT1:", "LPT2:", "LPT3:", "COM1:", "COM2:", "COM3:", "COM4:", "FILE:", "PORTPROMPT:", "nul")
    $usedPorts = (Get-Printer -ErrorAction SilentlyContinue).PortName
    $allPorts = Get-PrinterPort -ErrorAction SilentlyContinue
    $orphans = $allPorts | Where-Object {
        $_.Name -notin $usedPorts -and $_.Name -notin $protectedPorts
    }
    $removedPorts = 0
    foreach ($port in $orphans) {
        try {
            Remove-PrinterPort -Name $port.Name -Confirm:$false -ErrorAction Stop
            Write-Host "        [OK] Orphan port removed: $($port.Name)" -ForegroundColor Green
            $removedPorts++
        } catch {
            # Silently skip ports that resist removal
        }
    }
    if ($removedPorts -eq 0) {
        Write-Host "        [--] No orphaned ports found." -ForegroundColor DarkGray
    }

    # Step 5 -- Registry cleanup
    Write-Host "  [5/5] Checking registry..." -ForegroundColor Yellow

    $cleanName = if ($source -eq "OrphanDriver") { $driverName } else { $name }

    # Printer key
    $regPrinterPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\$cleanName"
    if (Test-Path $regPrinterPath) {
        Write-Host "        [!!] Registry ghost: $regPrinterPath" -ForegroundColor Yellow
        try {
            Remove-Item -Path $regPrinterPath -Recurse -Force -ErrorAction Stop
            Write-Host "        [OK] Registry printer key removed." -ForegroundColor Green
        } catch {
            Write-Host "        [!!] Failed: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "        [--] No printer registry ghost." -ForegroundColor DarkGray
    }

    # Driver environment keys (Version-3 and Version-4)
    $driverEnvBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64\Drivers"
    foreach ($version in @("Version-3", "Version-4")) {
        $driverRegPath = "$driverEnvBase\$version\$driverName"
        if (Test-Path $driverRegPath) {
            Write-Host "        [!!] Driver registry ghost: $driverRegPath" -ForegroundColor Yellow
            try {
                Remove-Item -Path $driverRegPath -Recurse -Force -ErrorAction Stop
                Write-Host "        [OK] Driver registry key removed." -ForegroundColor Green
            } catch {
                Write-Host "        [!!] Failed: $_" -ForegroundColor Red
            }
        }
    }

    Write-Host "  --- Done: $name ---" -ForegroundColor Cyan
}

# ============================================================
#  Main
# ============================================================

Show-Banner

Write-Host "  Scanning for printers across all layers..." -ForegroundColor Yellow
Write-Host "  (Print subsystem + Registry + Orphan drivers)" -ForegroundColor DarkGray

$allEntries = Get-AllPrinterEntries

if (-not $allEntries -or $allEntries.Count -eq 0) {
    Write-Host ""
    Write-Host "  No printers found (clean system)." -ForegroundColor Green
    Write-Host "  If something is still stuck, check manually:" -ForegroundColor DarkYellow
    Write-Host "    regedit > HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers\" -ForegroundColor DarkYellow
    Write-Host ""
    exit
}

# Build display list with source tags
$displayList = $allEntries | ForEach-Object {
    $tag = switch ($_.Source) {
        "PrintSubsystem" { $_.Status }
        "RegistryGhost"  { "REG GHOST" }
        "OrphanDriver"   { "ORPHAN DRV" }
    }
    "$($_.Name)  [$($_.Driver)]  ($tag)"
}

# Interactive selection
$selectedIndices = Show-Menu -Title "Discovered Printers & Ghosts" -Options $displayList -MultiSelect

if ($null -eq $selectedIndices) {
    Write-Host "`n  Aborted. No changes made.`n" -ForegroundColor Yellow
    exit
}

$selectedEntries = $allEntries[$selectedIndices]

# Confirm
Write-Host "`n  Selected for removal ($($selectedEntries.Count) item(s)):" -ForegroundColor Yellow
foreach ($entry in $selectedEntries) {
    $icon = switch ($entry.Source) {
        "RegistryGhost" { "[GHOST]" }
        "OrphanDriver"  { "[ORPHAN]" }
        default         { "[LIVE]" }
    }
    Write-Host "    $icon $($entry.Name)" -ForegroundColor White
}

Write-Host "`n  All selected items will be removed along with their drivers," -ForegroundColor DarkGray
Write-Host "  ports, and registry keys. No further prompts after this." -ForegroundColor DarkGray

$go = Read-Host "`n  Proceed with removal? (Y/N)"
if ($go -ne 'Y' -and $go -ne 'y') {
    Write-Host "  Aborted.`n" -ForegroundColor Yellow
    exit
}

# Process
foreach ($entry in $selectedEntries) {
    Remove-PrinterFully -Entry $entry
}

# Final restart
Write-Host ""
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "   Complete. Restarting Print Spooler..." -ForegroundColor Green
Restart-Service -Name Spooler -Force -ErrorAction SilentlyContinue
Write-Host "   Spooler restarted." -ForegroundColor Green
Write-Host ""
Write-Host "   If anything persists after a reboot, run again --" -ForegroundColor DarkGray
Write-Host "   some drivers only fully release after restart." -ForegroundColor DarkGray
Write-Host "  ====================================================`n" -ForegroundColor Cyan
