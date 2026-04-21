# System Repair and Update Tool

A PowerShell + WPF desktop tool for automated Windows workstation maintenance. Runs DISM health repair, SFC, OEM driver updates (Dell Command Update / Lenovo System Update), and Windows Update through a single GUI with session-resume support across reboots. Ships with bundled field utilities (stale printer cleanup, network diagnostics, and a PaperCut Print Deploy Client installer).

Built for Windows 10 and 11 Pro/Enterprise on Dell and Lenovo hardware.

## Requirements

- Windows 10 1809+ or Windows 11 (Pro/Enterprise recommended)
- PowerShell 5.1 or newer
- Administrator privileges (the launcher handles UAC elevation automatically)
- Internet access for Windows Update and OEM tool installation via winget
- winget (present by default on Windows 10 1809+ and Windows 11)

## Folder Structure

```
SystemRepairTool/
|-- Launch-SystemRepairTool.bat         Double-click to launch (handles UAC)
|-- README.md                           Project readme
|-- CHANGELOG.md                        Release notes
|-- Tools/
    |-- SystemRepairTool.ps1            Main WPF GUI application
    |-- Remove-StalePrinters.ps1        Interactive stale printer removal
    |-- network-diag.bat                Network diagnostics with log output
    |-- Install-PaperCutClient.ps1      Standalone PaperCut installer/updater
    |-- Resources/
        |-- <vendor>.msi                Bundled installers (see PaperCut section)
```

> **Note**: `Tools\Resources\*.msi` files are NOT included in this repository. You must supply them yourself. See the PaperCut section below for details. The `Resources\` folder is also ignored by Git via `.gitignore`.

## Usage

Double-click `Launch-SystemRepairTool.bat`. Accept the UAC prompt. The GUI opens with two primary modes, phase cards, and an Additional Tools section.

No command-line parameters are needed. Everything is interactive.

## Header Status Indicators

The GUI header displays:

- System manufacturer, model, and OS version
- System uptime (formatted as days/hours/minutes)
- Pending reboot status with reasons (Component servicing, Windows Update, Pending file renames, ConfigMgr, Domain join, Computer rename)

If a pending reboot is detected, the status badge turns amber. Running a repair on a machine with a pending reboot often wastes time and can leave the system in a mixed state - reboot first, then run the tool.

## Repair Modes

### Full Repair

Runs all four phases sequentially. Takes 30-60 minutes depending on system state and available updates.

| Phase | Tool | What it does |
|-------|------|--------------|
| 1 - DISM Health Repair | `Dism.exe` | Runs CheckHealth, ScanHealth, and RestoreHealth against the online Windows image |
| 2 - System File Checker | `sfc.exe /scannow` | Scans protected system files and repairs corrupted ones from the component store |
| 3 - OEM Driver Updates | Dell Command Update or Lenovo System Update | Auto-detects manufacturer via WMI, installs the OEM CLI tool via winget if missing, runs driver and firmware updates with reboot suppressed |
| 4 - Windows Update | PSWindowsUpdate module | Installs the module if missing, searches for and installs all available Windows updates non-interactively with reboot deferred |

### Updates Only

Skips phases 1 and 2. Runs OEM Driver Updates and Windows Update. Useful for routine patching on machines that don't need system file repair.

When running in Updates Only mode, the DISM and SFC phase cards are grayed out with a "Skipped" label.

## OEM Detection

The tool reads `Win32_ComputerSystem.Manufacturer` via WMI at launch and configures phase 3 accordingly.

| Manufacturer | Tool | CLI path | Auto-install |
|--------------|------|----------|--------------|
| Dell | Dell Command Update | `C:\Program Files\Dell\CommandUpdate\dcu-cli.exe` or (x86) variant | `winget install Dell.CommandUpdate` |
| Lenovo | Lenovo System Update | `C:\Program Files (x86)\Lenovo\System Update\tvsu.exe` or non-x86 variant | `winget install Lenovo.SystemUpdate` |
| Other | Skipped | N/A | N/A |

Dell Command Update runs with `/applyUpdates -reboot=disable -autoSuspendBitLocker=enable`.
Lenovo System Update runs with `/CM -search A -action INSTALL -includerebootpackages 1,3,4,5 -noicon -noreboot -nolicense`.

### DCU Exit Code Handling

| Code | Meaning | Tool behavior |
|------|---------|---------------|
| 0 | Success, updates applied | Marks phase Done |
| 1 | Updates applied, reboot required | Marks phase Done, queues reboot |
| 2 | DUP returned REBOOT_REQUIRED (BIOS/driver installer) | Marks phase Done, queues reboot |
| 500 | No applicable updates | Marks phase Done |
| 3003 | Service busy | Retries with 15/30/45/60s backoff (up to 4 attempts) |
| 3004 | DCU self-updating | Retries with backoff |
| 3005 | Service installing pending updates | Retries with backoff |

> **Note**: DCU 3000-series codes are transient. The tool retries automatically. If DCU was freshly installed in the same run, the tool limits retries and recommends a reboot before the next attempt.

### Lenovo LSU Behavior and Type 5 Limitation

Lenovo updates are classified by reboot type. The tool handles Types 0, 1, 3, and 4 silently. **Type 5 updates (BIOS, Intel ME firmware, and certain docking firmware) cannot be installed silently** - Lenovo's own documentation is explicit that these updates always prompt the user, and this is a deliberate safety design that cannot be bypassed by any command-line flag.

Per-package install results are parsed from Lenovo's SQLite database at `C:\ProgramData\Lenovo\SystemUpdate\sessionSE\update_history.db` using the `PSSQLite` module (auto-installed from PSGallery on first run). The tool takes a snapshot of the database before running LSU, takes another after, and reports only packages that changed status during this run.

**What this means in practice:**

- The repair tool cannot install BIOS or critical firmware updates silently on Lenovo hardware
- Type 5 updates will appear in the LSU candidate list on every tool run until a tech manually installs them
- The tool detects this and reports it honestly in the phase detail: `"N updates require Lenovo Vantage"`
- When Type 5 updates are pending, the phase is marked Warning (amber) rather than Done (green)

**To install Type 5 updates:**

1. Log into the Lenovo machine with local admin rights
2. Open **Lenovo Vantage** (preferred) or launch **Lenovo System Update** from the Start menu
3. Let it scan, accept the license prompts, and install
4. Reboot when prompted. Type 5 forces a reboot within 5 minutes of install and cannot be deferred

**Why the tool can't automate this:** Lenovo's LSU kernel enforces the user-prompt requirement for Type 5 updates regardless of command-line flags. This is documented in Lenovo's System Update FAQ as a deliberate design choice that will not be changed. A future version could theoretically switch to **Lenovo Thin Installer** with a curated repository, which bypasses the prompt requirement for content pre-approved in the repository - but that requires maintaining repository infrastructure (Update Retriever + file share + monthly catalog refresh) that is not in scope for this tool.

## PaperCut Print Deploy Client Management

The PaperCut client installer is a standalone tool launched from the Additional Tools section of the GUI. It is intentionally separate from the main repair/update flow because:

- PaperCut client changes are deployment decisions, not repair actions
- The Windows Installer service can race with DCU / Windows Update, causing transient 1618 errors
- Running it on-demand means failures don't block OS maintenance

### How it works

1. Locates the most recently modified `.msi` in `Tools\Resources\` (prefers filenames matching `pc-print-deploy-client*.msi`)
2. Reads `ProductCode`, `ProductName`, and `ProductVersion` from the MSI database using the Windows Installer COM object
3. Scans `HKLM\...\Uninstall` (both 32-bit and 64-bit hives) for installed PaperCut Print Deploy entries
4. If installed version matches bundled version exactly - exits with "Already at vX.Y.Z. Nothing to do."
5. Otherwise uninstalls mismatched version(s) via `msiexec /x <ProductCode> /qn /norestart`, then installs bundled version via `msiexec /i <path> /qn /norestart`
6. Retries on exit code 1618 (another install in progress) with backoff: 15/30/45/60 seconds

### Deploying a new PaperCut version

1. Obtain the MSI from your PaperCut server (Print Deploy admin page)
2. Place it in `Tools\Resources\` (the tool picks the newest by LastWriteTime, so leaving the old MSI there as backup is fine)
3. Run the PaperCut button from the Additional Tools section on each machine that needs updating

No code changes required. The tool reads the MSI's embedded version string at runtime.

> **Note on redistribution**: PaperCut MSIs, Dell drivers, and Lenovo firmware are subject to each vendor's redistribution terms. This repository does not include any vendor binaries. Obtain them from the respective vendors and place them locally; they are excluded via `.gitignore`.

### msiexec exit codes handled by the standalone tool

| Code | Meaning | Tool behavior |
|------|---------|---------------|
| 0 | Success | Green "Install successful" |
| 1603 | Fatal install error | Red error with common-cause hints |
| 1605 | Product not installed | Treated as success during uninstall |
| 1618 | Another MSI install in progress | Retries 4 times with backoff before giving up |
| 3010 | Success, reboot required | Green "Install successful - reboot required" |
| other | Install failed | Red error, preserves install log in `%TEMP%` |

## Windows Update Phase

Runs in the background runspace (no interactive console), so PSWindowsUpdate must be called with flags that suppress all prompts:

- `-AcceptAll` - auto-accept EULAs
- `-IgnoreUserInput` - suppress reboot-category and other `PromptForChoice` calls
- `-IgnoreReboot` - do not let PSWindowsUpdate trigger a reboot directly (the tool handles reboots)
- `-MicrosoftUpdate` - include drivers, .NET, Office alongside Windows Update

The service is pre-accepted via `Add-WUServiceManager -MicrosoftUpdate -Confirm:$false` before scanning, so the "Accept Microsoft Update service?" prompt doesn't fire mid-install.

Before calling `Install-WindowsUpdate`, the tool checks `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired` and `Get-WURebootStatus`. If either indicates "updates already installed, waiting for reboot", the tool short-circuits to a reboot-required result instead of hanging on a reinstall attempt of already-staged updates.

A 45-minute hard timeout wraps `Install-WindowsUpdate` as a safety net. If it times out but updates staged during the attempt, reports reboot-required. Otherwise reports Warning.

## Session Resume

If a phase requires a reboot (typically OEM driver phase), the tool saves its progress and registers itself to relaunch after restart.

State is persisted to `%LOCALAPPDATA%\SystemRepairTool\session.json` and contains the run mode, the phase to resume from, and a timestamp. A Run registry key is written to `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` under the name `SystemRepairToolResume`.

### Resume logic

The tool tracks which phase triggered the reboot and resumes at the next active phase:

- If DISM triggered reboot -> resume at SFC
- If SFC triggered reboot -> resume at OEM
- If OEM triggered reboot -> resume at WU
- If WU triggered reboot -> no resume needed, session state cleared, user just needs to restart

Phases completed in the prior session show as "Done" with full progress bars. After all phases finish, the session file and registry key are cleaned up automatically.

### Start Over

When a resume session is detected at launch, a "Start Over" button appears in the footer. Clicking it discards `session.json` and the Run registry key, resets all phase cards to Pending, and returns the mode buttons to their fresh-start state. Use this when a saved session is no longer relevant (e.g., you want to run Full Repair from scratch instead of resuming from phase 4).

## Cancel Behavior

The Cancel button appears once a run starts. Cancellation signals the worker thread to stop after the current operation finishes (DISM, SFC, msiexec, and other system tools can't be interrupted mid-execution). Remaining phases are marked as "Skipped" and session state is cleared.

## Additional Tools

The Additional Tools side panel provides three standalone field utilities. These launch in their own console windows and are completely independent of the main repair session.

### Remove Stale Printers

Launches `Remove-StalePrinters.ps1` in a new elevated PowerShell console. Interactive: discovers printers from three sources (Get-Printer live queries, registry ghost scan, orphaned driver cross-reference), presents a numbered selection menu, and walks each selected entry through a five-step removal chain.

### Network Diagnostics

Launches `network-diag.bat` in a new elevated cmd window. Runs nine diagnostic stages and writes a timestamped log to `%USERPROFILE%\Desktop\network-diag-%COMPUTERNAME%.txt` with a plain-English diagnosis summary appended at the end.

The "Open Latest Network Log" button opens the most recent network diagnostics log from the Desktop in Notepad.

### Install / Update PaperCut Print Deploy Client

Launches `Install-PaperCutClient.ps1` in a new elevated PowerShell console. Reads the MSI from `Tools\Resources\`, detects the installed version, and uninstalls/installs as needed. See the PaperCut section above for the detailed flow and deployment instructions.

## Logs

Each run of the main tool writes a timestamped log to `%LOCALAPPDATA%\SystemRepairTool\repair-log_YYYYMMDD_HHmmss.txt`. The GUI includes an inline log console (green monospace text) that mirrors what's being written to the file. Click "Open Log" in the footer to open the current log in Notepad.

PaperCut install/uninstall logs are kept in `%TEMP%` only on failure (path shown in console output for diagnosis). Successful runs delete them.

Network diagnostics logs are separate and written to the Desktop.

## Versioning

The script version is declared at the top of `SystemRepairTool.ps1` as `$Script:Version`. It's displayed in the bottom-left footer of the GUI so outdated deployed copies can be identified at a glance.

**Version increment rule (for future maintainers, including AI agents):**

- Every modification to the script increments the version by 0.1
- After 1.9 comes 2.0. After 2.9 comes 3.0. And so on
- Single decimal only - do not use patch-level versions like 1.0.1
- Correct progression: 1.0 -> 1.1 -> 1.2 -> ... -> 1.9 -> 2.0 -> 2.1

The version number is cosmetic/informational. It does not gate any behavior.

## Architecture

```
Launch-SystemRepairTool.bat
|
|-- UAC elevation check (net session)
|-- Self-elevates via Start-Process -Verb RunAs if needed
|-- Launches PowerShell -> Tools\SystemRepairTool.ps1
  |
  |-- Admin check
  |-- Load WPF assemblies (PresentationFramework, PresentationCore, WindowsBase)
  |-- Initialize constants, state dir, log file
  |-- Check ResourcesRoot (Tools\Resources\)
  |-- Build XAML window (dark theme)
  |-- Wire UI controls to $Script:UI hashtable
  |-- Detect system manufacturer via WMI
  |-- Check pending reboot status (5 canonical indicators)
  |-- Check system uptime (Win32_OperatingSystem.LastBootUpTime)
  |-- Populate header status badge (color-coded if reboot pending)
  |-- Check for existing session (resume logic)
  |
  |-- [Full Repair] or [Updates Only] button click
  | |-- Start-RepairRun
  |   |-- Creates background runspace (STA, ReuseThread)
  |     |-- Invoke-PhaseDism         (DISM CheckHealth -> ScanHealth -> RestoreHealth)
  |     |-- Invoke-PhaseSfc          (sfc /scannow with Unicode output capture)
  |     |-- Invoke-PhaseOem          (Dell DCU or Lenovo LSU, auto-detect)
  |     |-- Invoke-PhaseWindowsUpdate (PSWindowsUpdate with non-interactive flags, 45-min timeout)
  |     |-- Completion handler (session cleanup or reboot prompt)
  |
  |-- [Remove Stale Printers] button
  | |-- Start-Process powershell.exe -> Tools\Remove-StalePrinters.ps1
  |
  |-- [Network Diagnostics] button
  | |-- Start-Process cmd.exe -> Tools\network-diag.bat
  |
  |-- [Install / Update PaperCut] button
  | |-- Start-Process powershell.exe -> Tools\Install-PaperCutClient.ps1
  |
  |-- [Open Latest Log] button
    |-- Opens Desktop\network-diag-*.txt in Notepad
```

The main repair phases run in a background PowerShell runspace to keep the WPF UI responsive. The runspace communicates with the UI via `Dispatcher.Invoke` calls. Session state, log file path, script path, and cancel flag are passed into the runspace via `SessionStateProxy.SetVariable`.

The Additional Tools section uses `Start-Process` with `-Verb RunAs` to launch child processes. Since the parent is already elevated, this typically does not trigger a second UAC prompt on domain-joined machines.

## Encoding Notes

The runspace forces UTF-8 output encoding at startup to prevent native tools (particularly winget) from emitting progress-bar glyphs that render as garbage in the log. SFC output is captured via temp file with explicit Unicode encoding because SFC emits UTF-16LE that PowerShell's default native-output capture sometimes mangles.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| GUI doesn't appear | PowerShell execution policy blocking the script | The launcher uses `-ExecutionPolicy Bypass`. Check that the .bat is launching the correct path (`Tools\SystemRepairTool.ps1`) |
| "This script must be run as Administrator" | UAC denied or the .bat wasn't used | Double-click the .bat launcher; it handles elevation |
| DCU/LSU won't install via winget | winget not available or no internet | Install Dell Command Update from dell.com/support or Lenovo System Update from support.lenovo.com manually, then re-run |
| PSWindowsUpdate module fails to install | No internet or NuGet provider missing | Run `Install-Module PSWindowsUpdate -Force` manually in an admin PowerShell |
| PSSQLite module fails to install | No internet or NuGet provider missing | Run `Install-Module PSSQLite -Force` manually in an admin PowerShell |
| Tool doesn't resume after reboot | Run registry key removed or session.json deleted | Check `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` for `SystemRepairToolResume` and `%LOCALAPPDATA%\SystemRepairTool\session.json` |
| Phase stuck on "Running" | Long-running DISM RestoreHealth or large Windows Update download | Check the log file for progress. RestoreHealth alone can take 15-20 minutes |
| PaperCut tool says "Resources folder not found" | `Tools\Resources\` folder not created | Create `Tools\Resources\` and place the PaperCut MSI inside |
| PaperCut tool says "No MSI found" | No .msi file in Resources folder | Copy `pc-print-deploy-client_*.msi` into `Tools\Resources\` |
| PaperCut "Could not read MSI metadata" | MSI is corrupted or blocked by Mark-of-the-Web | Unblock the MSI via `Unblock-File` or right-click Properties > Unblock, then rerun |
| PaperCut install fails with exit 1603 | Fatal install error (often AV interference, disk full, or corrupt MSI) | Check the install log path shown in the console output, typically in `%TEMP%` |
| PaperCut install stays on 1618 after retries | Another Windows Installer operation genuinely in progress | Close any open installers or Windows Update processes and rerun |
| Remove Stale Printers button says "not found" | `Remove-StalePrinters.ps1` not in Tools folder | Confirm folder structure is correct |
| Network Diagnostics button says "not found" | `network-diag.bat` not in Tools folder | Same as above |
| Second UAC prompt on tool launch buttons | Windows requiring re-elevation for child process | Expected behavior on non-domain or high-UAC-policy machines; does not affect functionality |
| SFC reports "could not perform the requested operation" | CBS store corruption beyond DISM repair capability | Run from a Windows installer USB: `sfc /scannow /offbootdir=C:\ /offwindir=C:\Windows` |
| Header shows "Reboot Pending" | One of the 5 reboot indicators is set | Reboot the machine before running a repair - mixing pending changes with new updates often causes problems |

## File Inventory

| File | Purpose |
|------|---------|
| `Launch-SystemRepairTool.bat` | UAC-elevating launcher, double-click entry point |
| `Tools\SystemRepairTool.ps1` | Main WPF GUI application with all repair phases and session management |
| `Tools\Remove-StalePrinters.ps1` | Interactive stale printer discovery and removal (console-based) |
| `Tools\network-diag.bat` | Nine-stage network diagnostic with Desktop log output |
| `Tools\Install-PaperCutClient.ps1` | Standalone PaperCut client installer/updater (console-based) |
| `Tools\Resources\*.msi` | Bundled vendor installers (not included in repo - see PaperCut section) |
| `README.md` | This documentation |
| `CHANGELOG.md` | Release notes |

## License

Licensed under the MIT License. See `LICENSE` for details.

## Disclaimer

This tool is provided as-is with no warranty. It invokes vendor-provided maintenance tools (Dell Command Update, Lenovo System Update, PSWindowsUpdate) and is subject to the behavior and limitations of those tools. Always test on non-critical hardware before deploying widely. The author is not responsible for data loss, bricked firmware, or other issues arising from use of this tool.
