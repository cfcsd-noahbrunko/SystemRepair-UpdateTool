# Changelog

All notable changes to this project will be documented in this file.

## v2.5

- Removed the `PendingFileRenameOperations` check from the pending-reboot detector. That registry value is set by nearly any MSI uninstall, Windows Update cleanup, or routine file replacement, and almost never corresponds to a reboot that actually matters. Including it caused "Reboot Pending" badges to appear on a large fraction of perfectly healthy machines and desensitized techs to the real indicators.
- Remaining pending-reboot signals: Component Based Servicing, Windows Update, ConfigMgr client, Domain join, Computer rename. These are all cases where ignoring the pending state can actually cause problems during a repair run.

## v2.4

- Added staleness check on launch. The tool fetches `VERSION.txt` from the GitHub repo's raw URL and compares against the running version. If a newer version is available, an amber "Update available: vX.Y (click to view)" badge appears next to the version number in the footer. Clicking the badge opens the repo's releases page.
- Check runs in a background runspace with a 3-second timeout. Failure to reach GitHub (offline, blocked, timeout) results in a silent skip - the badge simply doesn't appear.
- No auto-update, no self-modification. The badge is advisory only. Humans decide when to update.
- Added sanity check on the remote response (must match version regex `\d+\.\d+`) to prevent arbitrary text from being injected into the UI if the URL is redirected.
- Improved footer version text readability: bumped from 10pt dark-gray (`#484f58`) to 13pt SemiBold light-gray (`#c9d1d9`). Much easier to read at a glance during field work.

## v2.3

- Fixed Lenovo result parsing. LSU writes per-package install results to a SQLite database at `C:\ProgramData\Lenovo\SystemUpdate\sessionSE\update_history.db`, not a text file as previously assumed.
- Added `PSSQLite` module dependency (auto-installs from PSGallery on first run, same pattern as `PSWindowsUpdate`). Pure-managed wrapper, no native dependencies.
- Query strategy: snapshot the DB before running LSU, run LSU, re-query after, and compare `installdate`/`status` per package to determine what LSU actually touched during this run vs. what was already there.
- Status classification: `AlreadyInstalled`, `NotApplicable`, `Success`, `Failed`, `Cancelled`, `UserActionRequired`. Each maps to a distinct bucket in the GUI.
- Log output now clearly separates "installed this run" from "already installed (no action needed)" from "not applicable to this hardware".

## v2.2

- Switched Lenovo result parsing from session folder XML scanning to reading the update history file directly. Fixes misidentification of the `sessionSE\Repository` cache folder as a session folder.

## v2.1

- Fixed major Lenovo reporting bug. Previous versions called `tvsu` with `-includerebootpackages 3`, which only installed Reboot Type 3 updates silently and misleadingly reported all candidate packages as "processed" even when they were not installed.
- New command line: `/CM -search A -action INSTALL -includerebootpackages 1,3,4,5 -noicon -noreboot -nolicense` - covers all reboot types and suppresses license/notification prompts.
- Added detection and honest reporting of Reboot Type 5 updates (BIOS, Intel ME firmware) that Lenovo designs to always prompt the user and cannot be installed silently.
- GUI phase detail now reads honestly: e.g. "38 installed; 4 require manual install via Lenovo Vantage" instead of the misleading "42 updates processed".

## v2.0

- Full UI redesign for full-screen usage with no vertical scrolling.
- Window resized from 880x820 fixed to 1280x820 resizable (min 1180x740).
- Header restructured: app title on left, system info card on right with color-coded status badge (Healthy green / Reboot Pending amber / Long Uptime neutral).
- Action buttons moved from bottom to top of the main workspace.
- Phase cards now displayed in a 2x2 grid instead of stacking vertically in a ScrollViewer.
- Additional Tools moved to a dedicated right side panel with taller two-line buttons (title + subtitle).
- Overall Progress card gets larger 18pt percentage display and a live "Running: <phase name>" label that updates as each phase runs.
- Log panel moved to the bottom full-width, labeled "Live Log".
- All backend logic (phases, session resume, retry loops) is unchanged from v1.4.

## v1.4

- Moved PaperCut Print Deploy Client from Phase 4 of the main repair flow to a standalone Additional Tools button. PaperCut client deployment is a separate concern from OS maintenance, and decoupling it prevents transient Windows Installer races (1618 conflicts with DCU/WU) from blocking a repair run.
- New file: `Tools\Install-PaperCutClient.ps1` - self-contained console tool with colored status output. Same MSI metadata parsing, version comparison, uninstall/install logic, and 1618 retry loop as the previous phase implementation.
- Windows Update is now Phase 4 (previously Phase 5). Main repair flow is back to 4 phases: DISM, SFC, OEM, WU.

## v1.3

- Added "Start Over" button that appears in the footer when a resume session is detected. Clicking it clears `session.json` and the `SystemRepairToolResume` registry key, resets all phase cards to Pending, and returns the mode buttons to their fresh-start state. Previously the only way to discard a stuck resume session was to manually delete the session file and registry key.

## v1.2

- DCU exit codes 1 and 2 now show Done green instead of Warning amber (both mean "updates applied, reboot required" - treating them as warnings was visually misleading).
- Added explicit handling for DCU exit code 2 (DUP REBOOT_REQUIRED code, passed up from BIOS/driver installers).
- PaperCut phase now waits for Windows Installer to be idle before starting, and retries on msiexec 1618 (another install in progress) with backoff.
- Windows Update phase now detects "updates installed, waiting for reboot" state pre-flight via `HKLM:\...\WindowsUpdate\Auto Update\RebootRequired` and short-circuits instead of hanging on `Install-WindowsUpdate` trying to reinstall already-staged updates.
- Added 45-minute hard timeout on `Install-WindowsUpdate` as a safety net.

## v1.1

- Better winget output filtering (previous version still let through `N MB / N MB` and `N%` download progress lines).
- When DCU is freshly installed during a run, tool now waits 45s for `DellClientManagementService` to initialize, explicitly starts the service if stopped, and limits 3005 retries to 2 attempts since a wedged service on a fresh install typically requires a reboot to recover.
- Retry backoff increased from 15s to 20s per attempt.

## v1.0

- Initial release.
- Fixed Windows Update phase hard-throwing on reboot-category prompts in non-interactive runspace (switched to `Install-WindowsUpdate` with `-IgnoreUserInput`).
- Fixed DCU 3005 transient failures with automatic retry loop on 3000-series exit codes.
- Fixed winget progress-bar glyphs appearing as garbage in log (forced UTF-8 output encoding, added `--disable-interactivity`, filtered output).
- Fixed SFC output capture using UTF-16LE temp file approach instead of `Out-String`.
- Fixed DISM RestoreHealth silently eating output - now surfaces relevant diagnostic lines.
- Fixed hardcoded resume-phase assumption after reboot - now dynamically determines resume point based on which phase triggered the reboot.
- Added version number display in footer.
- Added header status line with system uptime and pending-reboot indicator (checks all 5 canonical indicators).
- Added PaperCut Print Deploy Client management phase with drop-in MSI versioning.
