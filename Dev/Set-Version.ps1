#requires -Version 5.1
<#
.SYNOPSIS
    Updates all version-bearing files in the System Repair & Update Tool repo.

.DESCRIPTION
    The tool has three separate places that must be kept in sync whenever a new
    version ships:

      1. $Script:Version in Tools\SystemRepairTool.ps1
      2. The default Text="vX.Y" in the XAML footer (same file)
      3. VERSION.txt at the repo root

    This script updates all three to the version you specify. It does NOT commit,
    push, tag, or touch CHANGELOG.md - those stay deliberate human actions.

    This script lives in Dev\ and navigates up to the repo root at runtime.

.PARAMETER NewVersion
    The new version string in X.Y format (e.g. "2.5", "10.0"). Must match the
    regex ^\d+\.\d+$. Decimal-digit-only enforced to match the project's
    single-decimal versioning convention.

.PARAMETER Force
    Skip the "is this version higher than current?" safety check. Use this
    only if you deliberately need to set a lower version (e.g. correcting a
    mistake). Normal upgrades should never need -Force.

.EXAMPLE
    cd C:\SystemRepairTool\Dev
    .\Set-Version.ps1 -NewVersion 2.5

    Bumps the tool from whatever it currently is to v2.5 across all three files.

.EXAMPLE
    .\Set-Version.ps1 -NewVersion 2.5 -Force

    Same, but skip the "new version should be higher than current" check.

.NOTES
    Can be run from anywhere - resolves paths relative to its own location
    (the Dev folder). The repo root is expected to be the parent directory.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^\d+\.\d+$')]
    [string]$NewVersion,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve paths. The script sits in Dev\ so the repo root is one level up.
# Using Resolve-Path normalizes any ..\ segments to clean absolute paths.
# ---------------------------------------------------------------------------
$repoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$versionFile = Join-Path $repoRoot 'VERSION.txt'
$scriptFile  = Join-Path $repoRoot 'Tools\SystemRepairTool.ps1'

if (-not (Test-Path $versionFile)) {
    Write-Host "ERROR: VERSION.txt not found at $versionFile" -ForegroundColor Red
    Write-Host "Expected repo root: $repoRoot" -ForegroundColor Red
    Write-Host "This script should live in <repo root>\Dev\" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $scriptFile)) {
    Write-Host "ERROR: Tools\SystemRepairTool.ps1 not found at $scriptFile" -ForegroundColor Red
    Write-Host "Expected repo root: $repoRoot" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Repo root resolved to: $repoRoot" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Read current version from all three sources, verify they agree.
# ---------------------------------------------------------------------------
function Get-CurrentVersions {
    param([string]$ScriptPath, [string]$VersionPath)

    $scriptText = Get-Content -Raw -Path $ScriptPath
    $versionText = (Get-Content -Raw -Path $VersionPath).Trim()

    # Pattern 1: $Script:Version = "2.4"
    $m1 = [regex]::Match($scriptText, '\$Script:Version\s*=\s*"(\d+\.\d+)"')
    $scriptVersion = if ($m1.Success) { $m1.Groups[1].Value } else { $null }

    # Pattern 2: Text="v2.4" inside the XAML txtVersion element
    $m2 = [regex]::Match($scriptText, 'Name="txtVersion"[^>]*Text="v(\d+\.\d+)"')
    $xamlVersion = if ($m2.Success) { $m2.Groups[1].Value } else { $null }

    [pscustomobject]@{
        Script   = $scriptVersion
        Xaml     = $xamlVersion
        TextFile = $versionText
    }
}

$current = Get-CurrentVersions -ScriptPath $scriptFile -VersionPath $versionFile

Write-Host ""
Write-Host "Current versions:" -ForegroundColor Cyan
Write-Host "  `$Script:Version  : v$($current.Script)"
Write-Host "  XAML txtVersion  : v$($current.Xaml)"
Write-Host "  VERSION.txt      : v$($current.TextFile)"
Write-Host ""

# If any of the three couldn't be read, bail - don't silently half-update
if (-not $current.Script -or -not $current.Xaml -or -not $current.TextFile) {
    Write-Host "ERROR: Could not read one or more current version values." -ForegroundColor Red
    Write-Host "Check that the files haven't been structurally changed." -ForegroundColor Red
    exit 1
}

# Warn if they're not all in sync - means something got missed last time
$unique = @($current.Script, $current.Xaml, $current.TextFile) | Select-Object -Unique
if ($unique.Count -gt 1) {
    Write-Host "WARNING: Current versions disagree. This run will force them all to v$NewVersion." -ForegroundColor Yellow
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Safety check: new version should be higher than current (unless -Force).
# Uses [version] comparison by appending .0 so "2.10" sorts after "2.9"
# correctly instead of alphabetically.
# ---------------------------------------------------------------------------
$currentMax = ($unique | ForEach-Object { [version]("$_" + ".0") } | Sort-Object -Descending | Select-Object -First 1)
$newVer     = [version]("$NewVersion" + ".0")

if (-not $Force -and $newVer -le $currentMax) {
    Write-Host "ERROR: New version v$NewVersion is not higher than current v$($currentMax.ToString(2))." -ForegroundColor Red
    Write-Host "Use -Force if this is intentional (e.g. correcting a mistaken bump)." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Confirm.
# ---------------------------------------------------------------------------
Write-Host "About to update all three version references to: v$NewVersion" -ForegroundColor Green
$confirm = Read-Host "Continue? (y/N)"
if ($confirm -notmatch '^[yY]') {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Apply the changes.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Updating files..." -ForegroundColor Cyan

# 1. VERSION.txt - just overwrite with the new version + trailing newline
Set-Content -Path $versionFile -Value "$NewVersion`n" -NoNewline -Encoding UTF8
Write-Host "  [OK] VERSION.txt -> $NewVersion"

# 2+3. SystemRepairTool.ps1 - replace both $Script:Version and XAML Text
$scriptText = Get-Content -Raw -Path $scriptFile

# Replace $Script:Version line
$scriptText = [regex]::Replace(
    $scriptText,
    '(\$Script:Version\s*=\s*)"\d+\.\d+"',
    "`$1`"$NewVersion`""
)

# Replace XAML txtVersion Text attribute
$scriptText = [regex]::Replace(
    $scriptText,
    '(Name="txtVersion"[^>]*Text=")v\d+\.\d+(")',
    "`${1}v$NewVersion`$2"
)

# Write back. Preserve original encoding (UTF-8 without BOM is standard for PS1)
[System.IO.File]::WriteAllText($scriptFile, $scriptText, [System.Text.UTF8Encoding]::new($false))
Write-Host "  [OK] Tools\SystemRepairTool.ps1 -> `$Script:Version and XAML both set to v$NewVersion"

# ---------------------------------------------------------------------------
# Verify by re-reading.
# ---------------------------------------------------------------------------
$after = Get-CurrentVersions -ScriptPath $scriptFile -VersionPath $versionFile

Write-Host ""
Write-Host "Verification (all three should now match):" -ForegroundColor Cyan
Write-Host "  `$Script:Version  : v$($after.Script)"
Write-Host "  XAML txtVersion  : v$($after.Xaml)"
Write-Host "  VERSION.txt      : v$($after.TextFile)"

if ($after.Script -eq $NewVersion -and $after.Xaml -eq $NewVersion -and $after.TextFile -eq $NewVersion) {
    Write-Host ""
    Write-Host "All three files updated to v$NewVersion." -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps (manual):" -ForegroundColor Cyan
    Write-Host "  1. Update CHANGELOG.md with the v$NewVersion entry describing what changed"
    Write-Host "  2. git add ."
    Write-Host "  3. git commit -m `"v$NewVersion`: <summary of changes>`""
    Write-Host "  4. git tag -a v$NewVersion -m `"Version $NewVersion`""
    Write-Host "  5. git push"
    Write-Host "  6. git push origin v$NewVersion"
    Write-Host ""
    Write-Host "(Optional) Create a GitHub release from the tag if this is a notable version." -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "ERROR: Verification failed - files may be in an inconsistent state." -ForegroundColor Red
    Write-Host "Inspect the files manually and fix as needed." -ForegroundColor Red
    exit 1
}
