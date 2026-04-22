<#
.SYNOPSIS
    System Repair & Update Tool - GUI Edition
.DESCRIPTION
    WPF-based GUI that offers two modes:
      1. Full Repair:    DISM + SFC + OEM Drivers + Windows Update
      2. Updates Only:   OEM Drivers + Windows Update (skips DISM/SFC)
    Supports Dell and Lenovo OEM updates, restart prompts, and session resume.
.NOTES
    Must be Run as Administrator. Tested on Windows 10/11.
#>

# ============================================================================
#  TOP-LEVEL ERROR HANDLING
# ============================================================================
$ErrorActionPreference = "Stop"
trap {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  FATAL ERROR" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host ""
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# ============================================================================
#  ADMIN CHECK — self-elevate if not running as admin
# ============================================================================
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Re-launch this script elevated. This covers both manual launches without the
    # .bat and resume-on-reboot via the Run registry key (which can't use -Verb RunAs).
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if ($scriptPath) {
        Start-Process -FilePath 'powershell.exe' `
                      -ArgumentList @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', "`"$scriptPath`"") `
                      -Verb RunAs
    } else {
        Write-Host "This script must be run as Administrator." -ForegroundColor Red
        Read-Host "Press Enter to exit"
    }
    exit 0
}

Write-Host "Admin check passed. Loading assemblies..." -ForegroundColor Green

# ============================================================================
#  ASSEMBLIES
# ============================================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Write-Host "Assemblies loaded. Initializing..." -ForegroundColor Green

# ============================================================================
#  VERSION
# ============================================================================
# Displayed in the GUI footer. Used to identify outdated deployed copies.
#
# ### FOR FUTURE AI AGENTS / HUMAN MAINTAINERS ###
# Every time this script is modified, increment $Script:Version by 0.1.
# After 1.9 the next version is 2.0. After 2.9 the next is 3.0. And so on.
# This is a DECIMAL-SEGMENT increment, not a semver minor bump. Do not use
# patch-level versions (no 1.0.1). Single decimal only.
# Examples of correct progression: 1.0 -> 1.1 -> 1.2 -> ... -> 1.9 -> 2.0 -> 2.1
# ### END MAINTAINER NOTE ###
$Script:Version = "2.6"

# ============================================================================
#  CONSTANTS
# ============================================================================
$Script:AppName    = "System Repair & Update Tool"
$Script:StateDir   = Join-Path $env:LOCALAPPDATA "SystemRepairTool"
$Script:StateFile  = Join-Path $Script:StateDir "session.json"
$Script:LogFile    = Join-Path $Script:StateDir ("repair-log_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:RunKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$Script:RunKeyName = "SystemRepairToolResume"
$Script:ScriptPath = $PSCommandPath
if (-not $Script:ScriptPath) { $Script:ScriptPath = $MyInvocation.MyCommand.Path }

# Resources folder holds bundled installers (e.g. PaperCut MSI) used by the
# standalone tools (Install-PaperCutClient.ps1). Path: <Tools>\Resources\
$Script:ResourcesRoot = Join-Path (Split-Path -Parent $Script:ScriptPath) 'Resources'

if (-not (Test-Path $Script:StateDir)) {
    New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
}

# ============================================================================
#  LOGGING + SESSION HELPERS (main thread)
# ============================================================================
function Write-LogFile {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$ts] [$Level] $Message" | Add-Content -Path $Script:LogFile -ErrorAction SilentlyContinue
}

Write-LogFile "=== System Repair Tool started ==="

function Get-SessionState {
    if (Test-Path $Script:StateFile) {
        try { return (Get-Content $Script:StateFile -Raw | ConvertFrom-Json) }
        catch { return $null }
    }
    return $null
}

function Remove-SessionStateMain {
    if (Test-Path $Script:StateFile) { Remove-Item $Script:StateFile -Force }
    Remove-ItemProperty -Path $Script:RunKeyPath -Name $Script:RunKeyName -ErrorAction SilentlyContinue
}

function Register-ResumeOnRebootMain {
    if ($Script:ScriptPath -and (Test-Path $Script:ScriptPath)) {
        $cmd = "powershell.exe -ExecutionPolicy Bypass -File `"$Script:ScriptPath`""
        Set-ItemProperty -Path $Script:RunKeyPath -Name $Script:RunKeyName -Value $cmd
    }
}

# ============================================================================
#  SYSTEM DETECTION
# ============================================================================
function Get-SystemManufacturerMain {
    try { (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer }
    catch { "Unknown" }
}
function Get-SystemModelMain {
    try { (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Model }
    catch { "Unknown" }
}

# Check for a pending reboot using the canonical Windows indicators.
# Returns a hashtable: @{ Pending=$bool; Reasons=@(...) } so the GUI can tell
# the tech WHY a reboot is pending, not just that one is.
function Get-PendingRebootStatus {
    $reasons = @()
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
            $reasons += 'Component servicing'
        }
    } catch { }
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            $reasons += 'Windows Update'
        }
    } catch { }
    # Note: PendingFileRenameOperations is deliberately NOT checked. It's set by
    # almost any MSI uninstall, Windows Update cleanup, or similar routine file
    # replacement, and almost never actually requires a reboot in practice.
    # Leaving it in produced false-positive "Reboot Pending" badges on a large
    # fraction of healthy machines and desensitized techs to the genuine signals.
    try {
        $ccm = [wmiclass]'\\.\root\ccm\ClientSDK:CCM_ClientUtilities'
        if ($ccm) {
            $ccmResult = $ccm.DetermineIfRebootPending()
            if ($ccmResult -and ($ccmResult.RebootPending -or $ccmResult.IsHardRebootPending)) {
                $reasons += 'ConfigMgr client'
            }
        }
    } catch { }
    try {
        $netlogon = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name 'JoinDomain' -ErrorAction SilentlyContinue
        if ($netlogon -and $netlogon.JoinDomain) { $reasons += 'Domain join' }
        $avoid = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name 'AvoidSpnSet' -ErrorAction SilentlyContinue
        if ($avoid) { $reasons += 'Computer rename' }
    } catch { }

    return @{
        Pending = ($reasons.Count -gt 0)
        Reasons = $reasons
    }
}

# Get system uptime. Returns a hashtable with a formatted string and the TimeSpan
# itself, so the caller can both display it and make decisions based on duration.
function Get-SystemUptime {
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $span = (Get-Date) - $boot
        $text = if ($span.TotalDays -ge 1) {
            "{0}d {1}h {2}m" -f [int]$span.TotalDays, $span.Hours, $span.Minutes
        } elseif ($span.TotalHours -ge 1) {
            "{0}h {1}m" -f [int]$span.TotalHours, $span.Minutes
        } else {
            "{0}m" -f [int]$span.TotalMinutes
        }
        return @{ Text = $text; Span = $span; BootTime = $boot }
    } catch {
        return @{ Text = "unknown"; Span = $null; BootTime = $null }
    }
}

# ============================================================================
#  XAML
# ============================================================================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="System Repair and Update Tool"
        Width="1280" Height="820"
        MinWidth="1180" MinHeight="740"
        WindowStartupLocation="CenterScreen"
        Background="#0d1117">
    <Window.Resources>
        <Style x:Key="PhaseProgress" TargetType="ProgressBar">
            <Setter Property="Height" Value="6"/>
            <Setter Property="Margin" Value="0,8,0,0"/>
            <Setter Property="Background" Value="#21262d"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Foreground" Value="#2ea043"/>
        </Style>
        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Height" Value="42"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="16,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToolButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Height" Value="58"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Background" Value="#1f6feb"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="14,10">
                            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="#161b22"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="BorderBrush" Value="#30363d"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
    </Window.Resources>

    <!-- Outer grid: Header | Actions | Main workspace | Log -->
    <Grid Margin="24,18,24,18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>  <!-- 0: Header row -->
            <RowDefinition Height="Auto"/>  <!-- 1: Action buttons -->
            <RowDefinition Height="*"/>     <!-- 2: Main workspace (progress + phases + tools) -->
            <RowDefinition Height="Auto"/>  <!-- 3: Log panel (fixed height) -->
            <RowDefinition Height="Auto"/>  <!-- 4: Footer (version + open log) -->
        </Grid.RowDefinitions>

        <!-- ============================================================
             ROW 0: HEADER
             Left: title + subtitle
             Right: system info card with status badge
             ============================================================ -->
        <Grid Grid.Row="0" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" VerticalAlignment="Center">
                <TextBlock Text="System Repair and Update" FontSize="26" FontWeight="Bold" Foreground="#e6edf3"/>
                <TextBlock Name="txtSubtitle" Text="Pick a mode to begin" FontSize="12" Margin="0,4,0,0" Foreground="#8b949e"/>
            </StackPanel>

            <!-- System info card, right-aligned -->
            <Border Grid.Column="1" Style="{StaticResource Card}" Padding="18,12" MinWidth="420">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" VerticalAlignment="Center">
                        <TextBlock Name="txtSystemInfo" FontSize="13" FontWeight="SemiBold" Foreground="#e6edf3" Text="Loading system info..."/>
                        <TextBlock Name="txtSystemStatus" FontSize="11" Margin="0,3,0,0" Foreground="#8b949e" Text=""/>
                    </StackPanel>
                    <Border Grid.Column="1" Name="badgeStatus" Background="#1a4528" CornerRadius="12" Padding="12,5" Margin="16,0,0,0" VerticalAlignment="Center">
                        <TextBlock Name="txtStatusBadge" Text="Healthy" FontSize="11" FontWeight="SemiBold" Foreground="#2ea043"/>
                    </Border>
                </Grid>
            </Border>
        </Grid>

        <!-- ============================================================
             ROW 1: ACTION BUTTONS (top, not bottom)
             ============================================================ -->
        <DockPanel Grid.Row="1" Margin="0,0,0,14" LastChildFill="False">
            <Button Name="btnStartFull" DockPanel.Dock="Left" Content="Full Repair (DISM + SFC + Updates)" Background="#2ea043" Style="{StaticResource ActionButton}" Width="300" ToolTip="Runs DISM health repair, SFC, OEM driver updates, and Windows Update. Takes 30-60 minutes."/>
            <Button Name="btnStartUpdatesOnly" DockPanel.Dock="Left" Content="Updates Only (Drivers + Windows)" Background="#58a6ff" Style="{StaticResource ActionButton}" Width="260" Margin="10,0,0,0" ToolTip="Skips DISM and SFC. Runs only driver updates and Windows Update. Faster."/>
            <Button Name="btnCancel" DockPanel.Dock="Left" Content="Cancel" Visibility="Collapsed" Background="#f85149" Style="{StaticResource ActionButton}" Width="110" Margin="10,0,0,0"/>
            <Button Name="btnStartOver" DockPanel.Dock="Left" Content="Start Over" Visibility="Collapsed" Background="#6e7681" Style="{StaticResource ActionButton}" Width="110" Margin="10,0,0,0" ToolTip="Clears the saved session state so the next run starts from Phase 1 instead of resuming."/>
        </DockPanel>

        <!-- ============================================================
             ROW 2: MAIN WORKSPACE
             Left column: overall progress + phase grid
             Right column: additional tools card
             ============================================================ -->
        <Grid Grid.Row="2" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="320"/>
            </Grid.ColumnDefinitions>

            <!-- LEFT: progress + phase grid -->
            <Grid Grid.Column="0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <!-- Overall progress card -->
                <Border Grid.Row="0" Style="{StaticResource Card}" Padding="20,14" Margin="0,0,0,12">
                    <StackPanel>
                        <DockPanel LastChildFill="True">
                            <TextBlock DockPanel.Dock="Left" Text="Overall Progress" FontSize="13" FontWeight="SemiBold" Foreground="#e6edf3" VerticalAlignment="Center"/>
                            <TextBlock DockPanel.Dock="Right" Name="txtOverallPct" Text="0%" FontSize="18" FontWeight="Bold" Foreground="#2ea043"/>
                            <TextBlock Name="txtOverallPhase" Text="" FontSize="11" Margin="14,0,14,0" Foreground="#8b949e" VerticalAlignment="Center"/>
                        </DockPanel>
                        <ProgressBar Name="progressOverall" Value="0" Maximum="100" Height="14" Margin="0,10,0,0" Background="#21262d" BorderThickness="0" Foreground="#2ea043"/>
                    </StackPanel>
                </Border>

                <!-- Phase cards 2x2 grid -->
                <Grid Grid.Row="1">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="12"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="12"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Phase 1: DISM -->
                    <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource Card}" Padding="18,14">
                        <StackPanel VerticalAlignment="Center">
                            <DockPanel>
                                <TextBlock Name="iconDism" Text="o" FontSize="16" FontWeight="Bold" Foreground="#8b949e" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <TextBlock Text="Phase 1 - DISM Health Repair" FontSize="13" FontWeight="SemiBold" Foreground="#e6edf3"/>
                                <TextBlock Name="txtDismStatus" Text="Pending" FontSize="11" Foreground="#8b949e" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                            </DockPanel>
                            <ProgressBar Name="progDism" Value="0" Maximum="100" Style="{StaticResource PhaseProgress}"/>
                            <TextBlock Name="txtDismDetail" Text="Checks and repairs the Windows component store" FontSize="10" Foreground="#8b949e" Margin="0,8,0,0" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>

                    <!-- Phase 2: SFC -->
                    <Border Grid.Row="0" Grid.Column="2" Style="{StaticResource Card}" Padding="18,14">
                        <StackPanel VerticalAlignment="Center">
                            <DockPanel>
                                <TextBlock Name="iconSfc" Text="o" FontSize="16" FontWeight="Bold" Foreground="#8b949e" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <TextBlock Text="Phase 2 - System File Checker" FontSize="13" FontWeight="SemiBold" Foreground="#e6edf3"/>
                                <TextBlock Name="txtSfcStatus" Text="Pending" FontSize="11" Foreground="#8b949e" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                            </DockPanel>
                            <ProgressBar Name="progSfc" Value="0" Maximum="100" Style="{StaticResource PhaseProgress}"/>
                            <TextBlock Name="txtSfcDetail" Text="Scans and repairs protected system files" FontSize="10" Foreground="#8b949e" Margin="0,8,0,0" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>

                    <!-- Phase 3: OEM -->
                    <Border Grid.Row="2" Grid.Column="0" Style="{StaticResource Card}" Padding="18,14">
                        <StackPanel VerticalAlignment="Center">
                            <DockPanel>
                                <TextBlock Name="iconOem" Text="o" FontSize="16" FontWeight="Bold" Foreground="#8b949e" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <TextBlock Name="txtOemTitle" Text="Phase 3 - OEM Driver Updates" FontSize="13" FontWeight="SemiBold" Foreground="#e6edf3"/>
                                <TextBlock Name="txtOemStatus" Text="Pending" FontSize="11" Foreground="#8b949e" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                            </DockPanel>
                            <ProgressBar Name="progOem" Value="0" Maximum="100" Style="{StaticResource PhaseProgress}"/>
                            <TextBlock Name="txtOemDetail" Text="Dell Command Update or Lenovo System Update" FontSize="10" Foreground="#8b949e" Margin="0,8,0,0" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>

                    <!-- Phase 4: Windows Update -->
                    <Border Grid.Row="2" Grid.Column="2" Style="{StaticResource Card}" Padding="18,14">
                        <StackPanel VerticalAlignment="Center">
                            <DockPanel>
                                <TextBlock Name="iconWU" Text="o" FontSize="16" FontWeight="Bold" Foreground="#8b949e" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <TextBlock Text="Phase 4 - Windows Update" FontSize="13" FontWeight="SemiBold" Foreground="#e6edf3"/>
                                <TextBlock Name="txtWUStatus" Text="Pending" FontSize="11" Foreground="#8b949e" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                            </DockPanel>
                            <ProgressBar Name="progWU" Value="0" Maximum="100" Style="{StaticResource PhaseProgress}"/>
                            <TextBlock Name="txtWUDetail" Text="Installs available Windows and driver updates" FontSize="10" Foreground="#8b949e" Margin="0,8,0,0" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>
                </Grid>
            </Grid>

            <!-- RIGHT: additional tools side panel -->
            <Border Grid.Column="2" Style="{StaticResource Card}" Padding="18,14">
                <StackPanel>
                    <DockPanel Margin="0,0,0,4">
                        <TextBlock Text="Additional Tools" FontSize="13" FontWeight="SemiBold" Foreground="#e6edf3"/>
                    </DockPanel>
                    <TextBlock Text="Independent field utilities. Safe to use during a repair run." FontSize="10" Foreground="#8b949e" Margin="0,0,0,12" TextWrapping="Wrap"/>
                    <Button Name="btnRemovePrinters" Style="{StaticResource ToolButton}" Margin="0,0,0,8" ToolTip="Launches the interactive stale printer removal tool in a new console window.">
                        <StackPanel>
                            <TextBlock Text="Remove Stale Printers" FontWeight="SemiBold" Foreground="White"/>
                            <TextBlock Text="Ghost printer and driver cleanup" FontSize="10" Foreground="#c6e3ff" Margin="0,2,0,0"/>
                        </StackPanel>
                    </Button>
                    <Button Name="btnNetDiag" Style="{StaticResource ToolButton}" Margin="0,0,0,8" ToolTip="Runs network diagnostics and writes a log to the Desktop.">
                        <StackPanel>
                            <TextBlock Text="Network Diagnostics" FontWeight="SemiBold" Foreground="White"/>
                            <TextBlock Text="9-stage connectivity check, log to Desktop" FontSize="10" Foreground="#c6e3ff" Margin="0,2,0,0"/>
                        </StackPanel>
                    </Button>
                    <Button Name="btnPaperCut" Style="{StaticResource ToolButton}" Margin="0,0,0,8" ToolTip="Checks installed PaperCut client against the bundled MSI and installs or updates as needed.">
                        <StackPanel>
                            <TextBlock Text="PaperCut Print Deploy" FontWeight="SemiBold" Foreground="White"/>
                            <TextBlock Text="Install or update the print client" FontSize="10" Foreground="#c6e3ff" Margin="0,2,0,0"/>
                        </StackPanel>
                    </Button>
                    <Button Name="btnOpenNetDiagLog" Background="#30363d" Style="{StaticResource ToolButton}" ToolTip="Opens the most recent network-diag log from the Desktop.">
                        <StackPanel>
                            <TextBlock Text="Open Latest Network Log" FontWeight="SemiBold" Foreground="White"/>
                            <TextBlock Text="View the most recent netdiag output" FontSize="10" Foreground="#8b949e" Margin="0,2,0,0"/>
                        </StackPanel>
                    </Button>
                    <TextBlock Name="txtToolsStatus" Text="" FontSize="10" Foreground="#8b949e" Margin="0,12,0,0" TextWrapping="Wrap"/>
                </StackPanel>
            </Border>
        </Grid>

        <!-- ============================================================
             ROW 3: LOG PANEL
             Only scrollable section of the UI. Fills remaining vertical space.
             ============================================================ -->
        <Border Grid.Row="3" Background="#010409" CornerRadius="6" Padding="14,10" BorderBrush="#30363d" BorderThickness="1" Height="160">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <DockPanel Grid.Row="0" Margin="0,0,0,6">
                    <TextBlock Text="Live Log" FontSize="10" FontWeight="SemiBold" Foreground="#8b949e" VerticalAlignment="Center"/>
                    <TextBlock Text="(writes to disk; click 'Open Log' to open the file)" FontSize="9" Foreground="#484f58" Margin="8,1,0,0" VerticalAlignment="Center"/>
                </DockPanel>
                <ScrollViewer Grid.Row="1" Name="scrollLog" VerticalScrollBarVisibility="Auto">
                    <TextBlock Name="txtLog" FontFamily="Cascadia Mono,Consolas,Courier New" FontSize="11" Foreground="#7ee787" TextWrapping="Wrap"/>
                </ScrollViewer>
            </Grid>
        </Border>

        <!-- ============================================================
             ROW 4: FOOTER - version + update badge + Open Log button
             ============================================================ -->
        <DockPanel Grid.Row="4" Margin="0,10,0,0">
            <TextBlock Name="txtVersion" Text="v2.6" DockPanel.Dock="Left" FontSize="13" FontWeight="SemiBold" Foreground="#c9d1d9" VerticalAlignment="Center"/>
            <TextBlock Name="txtUpdateBadge" Text="" DockPanel.Dock="Left" FontSize="12" FontWeight="SemiBold" Foreground="#d29922" VerticalAlignment="Center" Margin="12,0,0,0" Cursor="Hand"/>
            <Button Name="btnOpenLog" Content="Open Log" Background="#30363d" Style="{StaticResource ActionButton}" DockPanel.Dock="Right" Width="110" Height="32"/>
        </DockPanel>
    </Grid>
</Window>
'@

# ============================================================================
#  BUILD WINDOW
# ============================================================================
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$Script:Window = [Windows.Markup.XamlReader]::Load($reader)

$Script:UI = @{}
$names = @(
    'txtSubtitle','txtSystemInfo','txtSystemStatus','txtStatusBadge','badgeStatus',
    'txtOverallPhase','txtOverallPct','progressOverall',
    'iconDism','txtDismStatus','progDism','txtDismDetail',
    'iconSfc','txtSfcStatus','progSfc','txtSfcDetail',
    'iconOem','txtOemTitle','txtOemStatus','progOem','txtOemDetail',
    'iconWU','txtWUStatus','progWU','txtWUDetail',
    'txtLog','scrollLog',
    'btnStartFull','btnStartUpdatesOnly','btnCancel','btnStartOver','btnOpenLog','txtVersion','txtUpdateBadge',
    'btnRemovePrinters','btnNetDiag','btnOpenNetDiagLog','btnPaperCut','txtToolsStatus'
)
foreach ($n in $names) {
    $Script:UI[$n] = $Script:Window.FindName($n)
}

# Reflect the script-level version constant into the footer so there's a single
# source of truth (update $Script:Version at the top of this file).
if ($Script:UI['txtVersion']) {
    $Script:UI['txtVersion'].Text = "v$Script:Version"
}

# ============================================================================
#  STALENESS CHECK
# ----------------------------------------------------------------------------
#  Fires a background web request to VERSION.txt on the GitHub repo. If the
#  remote version is newer than $Script:Version, shows an amber "Update
#  available: vX.Y" badge next to the version number. Click the badge to open
#  the releases page in the default browser.
#
#  Failure modes (offline, DNS blocked, GitHub down, malformed response, etc.)
#  all result in a silent skip. The tool must never block or error out on
#  this check - it's advisory only.
# ============================================================================
$Script:UpdateCheck = @{
    VersionUrl  = 'https://raw.githubusercontent.com/cfcsd-noahbrunko/SystemRepair-UpdateTool/main/VERSION.txt'
    ReleasesUrl = 'https://github.com/cfcsd-noahbrunko/SystemRepair-UpdateTool/releases'
    TimeoutSec  = 3
}

try {
    # Use a lightweight runspace instead of Start-Job to keep startup fast.
    # Start-Job spawns a whole separate pwsh process (~1s overhead); runspaces
    # are in-process and essentially free.
    $Script:UpdateRunspace = [runspacefactory]::CreateRunspace()
    $Script:UpdateRunspace.Open()
    $Script:UpdatePS = [powershell]::Create()
    $Script:UpdatePS.Runspace = $Script:UpdateRunspace
    $null = $Script:UpdatePS.AddScript({
        param($url, $timeoutSec)
        try {
            # Force TLS 1.2 on older Windows where .NET defaults may exclude it
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeoutSec -ErrorAction Stop
            $content = "$($resp.Content)".Trim()
            # Sanity-check the response looks like a version string ("2.4", "10.15", etc.)
            # to prevent a compromised/redirected URL from putting arbitrary text in the UI
            if ($content -match '^\d+\.\d+(\.\d+)?$') {
                return $content
            }
            return $null
        } catch {
            return $null
        }
    }).AddArgument($Script:UpdateCheck.VersionUrl).AddArgument($Script:UpdateCheck.TimeoutSec)
    $Script:UpdateAsync = $Script:UpdatePS.BeginInvoke()

    # Poll the runspace result via DispatcherTimer - the supported way to
    # marshal background results into a WPF window without blocking.
    $Script:UpdateTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:UpdateTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $Script:UpdateTimer.Add_Tick({
        if (-not $Script:UpdateAsync.IsCompleted) { return }

        $Script:UpdateTimer.Stop()
        try {
            $remoteVer = $Script:UpdatePS.EndInvoke($Script:UpdateAsync)
        } catch {
            $remoteVer = $null
        } finally {
            $Script:UpdatePS.Dispose()
            $Script:UpdateRunspace.Dispose()
        }

        if (-not $remoteVer) {
            Write-LogFile "Update check: no response or check skipped."
            return
        }

        # Compare versions numerically. Append .0 to normalize "2.3" and "2.3.0"
        try {
            $local  = [version]("$Script:Version" + ".0")
            $remote = [version]("$remoteVer" + ".0")
        } catch {
            Write-LogFile "Update check: could not parse version strings local='$Script:Version' remote='$remoteVer'"
            return
        }

        if ($remote -gt $local) {
            Write-LogFile "Update check: newer version available (local=v$Script:Version, remote=v$remoteVer)"
            $Script:UI['txtUpdateBadge'].Text = "Update available: v$remoteVer (click to view)"
            $Script:UI['txtUpdateBadge'].Add_MouseLeftButtonUp({
                try { Start-Process $Script:UpdateCheck.ReleasesUrl } catch { }
            })
        } elseif ($remote -lt $local) {
            # Running a newer version than what's on the repo - usually happens
            # during dev. Quiet informational log, no UI change.
            Write-LogFile "Update check: running v$Script:Version, repo shows v$remoteVer (ahead of remote, no action needed)"
        } else {
            Write-LogFile "Update check: running latest version (v$Script:Version)"
        }
    })
    $Script:UpdateTimer.Start()
} catch {
    # Any failure setting up the check just gets logged - no UI impact
    Write-LogFile "Update check setup failed: $($_.Exception.Message)"
}

Write-Host "Window constructed." -ForegroundColor Green

# ============================================================================
#  MAIN-THREAD UI HELPERS
# ============================================================================
$Script:BrushConverter = [System.Windows.Media.BrushConverter]::new()

function Invoke-OnUIMain {
    param([scriptblock]$Action)
    $Script:Window.Dispatcher.Invoke([Action]$Action)
}

function Add-LogLineMain {
    param([string]$Text)
    Write-LogFile $Text
    Invoke-OnUIMain {
        $Script:UI['txtLog'].Inlines.Add((New-Object System.Windows.Documents.Run "$Text`n"))
        $Script:UI['scrollLog'].ScrollToEnd()
    }
}

function Set-PhaseStateMain {
    param([string]$Phase, [string]$Status, [int]$Progress = -1, [string]$Detail = "")
    $iconKey = "icon$Phase"; $statusKey = "txt${Phase}Status"
    $progKey = "prog$Phase"; $detailKey = "txt${Phase}Detail"
    $iconMap = @{ Pending="o"; Running="*"; Done="v"; Warning="!"; Skipped="-"; Error="x" }
    $colorMap = @{ Pending="#8b949e"; Running="#58a6ff"; Done="#2ea043"; Warning="#d29922"; Skipped="#8b949e"; Error="#f85149" }
    Invoke-OnUIMain {
        if ($Script:UI[$iconKey])   { $Script:UI[$iconKey].Text = $iconMap[$Status]; $Script:UI[$iconKey].Foreground = $Script:BrushConverter.ConvertFromString($colorMap[$Status]) }
        if ($Script:UI[$statusKey]) { $Script:UI[$statusKey].Text = $Status; $Script:UI[$statusKey].Foreground = $Script:BrushConverter.ConvertFromString($colorMap[$Status]) }
        if ($Progress -ge 0 -and $Script:UI[$progKey]) {
            $Script:UI[$progKey].Value = $Progress
            if ($Status -eq "Warning" -or $Status -eq "Error") {
                $Script:UI[$progKey].Foreground = $Script:BrushConverter.ConvertFromString($colorMap[$Status])
            }
        }
        if ($Detail -and $Script:UI[$detailKey]) { $Script:UI[$detailKey].Text = $Detail }
    }
}

# ============================================================================
#  POPULATE SYSTEM INFO
# ============================================================================
$mfg = Get-SystemManufacturerMain
$model = Get-SystemModelMain
$osVer = try { (Get-CimInstance Win32_OperatingSystem).Caption } catch { "Windows" }

$Script:UI['txtSystemInfo'].Text = "$mfg $model  -  $osVer"
if ($mfg -match "Dell") {
    $Script:UI['txtOemTitle'].Text = "Phase 3 - Dell Command Update"
} elseif ($mfg -match "Lenovo") {
    $Script:UI['txtOemTitle'].Text = "Phase 3 - Lenovo System Update"
} else {
    $Script:UI['txtOemTitle'].Text = "Phase 3 - OEM Driver Updates (auto-detect)"
}
Write-LogFile "System: $mfg $model / $osVer"

# Surface uptime and pending-reboot state in the header system-info card.
# Uses the status badge (top-right of the card) for the at-a-glance indicator,
# and the small text line underneath for detail.
$uptime = Get-SystemUptime
$reboot = Get-PendingRebootStatus

# Detail line under the system info: uptime + any pending-reboot reasons
if ($reboot.Pending) {
    $reasonText = $reboot.Reasons -join ', '
    $Script:UI['txtSystemStatus'].Text = "Uptime: $($uptime.Text)  -  Reasons: $reasonText"
    Write-LogFile "Pending reboot detected at startup. Reasons: $reasonText"
} else {
    $Script:UI['txtSystemStatus'].Text = "Uptime: $($uptime.Text)"
}

# Status badge: green "Healthy" (default), amber "Reboot Pending", or neutral
# "Long Uptime" when the machine has been up too long without pending changes.
# The badge colors are designed to pop against the dark card background.
if ($reboot.Pending) {
    $Script:UI['txtStatusBadge'].Text = "Reboot Pending"
    $Script:UI['txtStatusBadge'].Foreground = $Script:BrushConverter.ConvertFromString("#d29922")
    $Script:UI['badgeStatus'].Background  = $Script:BrushConverter.ConvertFromString("#3d2e0a")
} elseif ($uptime.Span -and $uptime.Span.TotalDays -gt 14) {
    $Script:UI['txtStatusBadge'].Text = "Long Uptime"
    $Script:UI['txtStatusBadge'].Foreground = $Script:BrushConverter.ConvertFromString("#8b949e")
    $Script:UI['badgeStatus'].Background  = $Script:BrushConverter.ConvertFromString("#21262d")
} else {
    $Script:UI['txtStatusBadge'].Text = "Healthy"
    $Script:UI['txtStatusBadge'].Foreground = $Script:BrushConverter.ConvertFromString("#2ea043")
    $Script:UI['badgeStatus'].Background  = $Script:BrushConverter.ConvertFromString("#1a4528")
}
Write-LogFile "Uptime: $($uptime.Text)"

# ============================================================================
#  WORKER SCRIPT BLOCK (runs in background runspace)
# ============================================================================
# Variables injected via SessionStateProxy: Window, UI, StateFile, LogFile,
# RunKeyPath, RunKeyName, ScriptPath, BrushConverter, CancelRequested,
# ResumeFrom, RunMode, ActivePhases
$Script:WorkerScriptBlock = {
    # Force UTF-8 for all native-process output. Without this, winget and other
    # tools emit their progress-bar glyphs as garbage (the "G G G G G" blocks
    # that showed up in logs were U+2588 FULL BLOCK characters from winget's
    # progress bar, re-encoded through cp437).
    try {
        [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
    } catch { }

    function Write-LogFile {
        param([string]$Message, [string]$Level = "INFO")
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$ts] [$Level] $Message" | Add-Content -Path $LogFile -ErrorAction SilentlyContinue
    }
    function Invoke-OnUI { param([scriptblock]$Action) $Window.Dispatcher.Invoke([Action]$Action) }
    function Add-LogLine {
        param([string]$Text)
        Write-LogFile $Text
        Invoke-OnUI {
            $UI['txtLog'].Inlines.Add((New-Object System.Windows.Documents.Run "$Text`n"))
            $UI['scrollLog'].ScrollToEnd()
        }
    }
    function Set-PhaseState {
        param([string]$Phase, [string]$Status, [int]$Progress = -1, [string]$Detail = "")
        $iconKey = "icon$Phase"; $statusKey = "txt${Phase}Status"
        $progKey = "prog$Phase"; $detailKey = "txt${Phase}Detail"
        $iconMap = @{ Pending="o"; Running="*"; Done="v"; Warning="!"; Skipped="-"; Error="x" }
        $colorMap = @{ Pending="#8b949e"; Running="#58a6ff"; Done="#2ea043"; Warning="#d29922"; Skipped="#8b949e"; Error="#f85149" }
        Invoke-OnUI {
            if ($UI[$iconKey])   { $UI[$iconKey].Text = $iconMap[$Status]; $UI[$iconKey].Foreground = $BrushConverter.ConvertFromString($colorMap[$Status]) }
            if ($UI[$statusKey]) { $UI[$statusKey].Text = $Status; $UI[$statusKey].Foreground = $BrushConverter.ConvertFromString($colorMap[$Status]) }
            if ($Progress -ge 0 -and $UI[$progKey]) {
                $UI[$progKey].Value = $Progress
                if ($Status -eq "Warning" -or $Status -eq "Error") {
                    $UI[$progKey].Foreground = $BrushConverter.ConvertFromString($colorMap[$Status])
                }
            }
            if ($Detail -and $UI[$detailKey]) { $UI[$detailKey].Text = $Detail }
        }
    }
    function Set-OverallProgress {
        param([int]$Pct, [string]$PhaseLabel = $null)
        Invoke-OnUI {
            $UI['progressOverall'].Value = $Pct
            $UI['txtOverallPct'].Text = "$Pct%"
            if ($null -ne $PhaseLabel) {
                $UI['txtOverallPhase'].Text = $PhaseLabel
            }
        }
    }
    function Save-SessionState {
        param([hashtable]$State)
        $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Force
    }
    function Remove-SessionStateRunspace {
        if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
        Remove-ItemProperty -Path $RunKeyPath -Name $RunKeyName -ErrorAction SilentlyContinue
    }
    function Register-ResumeOnReboot {
        if ($ScriptPath -and (Test-Path $ScriptPath)) {
            $cmd = "powershell.exe -ExecutionPolicy Bypass -File `"$ScriptPath`""
            Set-ItemProperty -Path $RunKeyPath -Name $RunKeyName -Value $cmd
        }
    }
    function Get-SystemManufacturer {
        try { (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer } catch { "Unknown" }
    }
    function Find-DellCommandUpdate {
        $paths = @("C:\Program Files\Dell\CommandUpdate\dcu-cli.exe","C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe")
        foreach ($p in $paths) { if (Test-Path $p) { return $p } }
        return $null
    }
    function Find-LenovoSystemUpdate {
        $paths = @("C:\Program Files (x86)\Lenovo\System Update\tvsu.exe","C:\Program Files\Lenovo\System Update\tvsu.exe")
        foreach ($p in $paths) { if (Test-Path $p) { return $p } }
        return $null
    }

    # -------- Phase implementations --------
    function Invoke-PhaseDism {
        Set-PhaseState -Phase "Dism" -Status "Running" -Progress 0
        Add-LogLine "Phase 1: Starting DISM health repair..."
        Set-PhaseState -Phase "Dism" -Status "Running" -Progress 10 -Detail "Running CheckHealth..."
        Add-LogLine "  DISM /CheckHealth"
        $null = & Dism.exe /Online /Cleanup-Image /CheckHealth 2>&1
        Add-LogLine "  CheckHealth complete."
        if ($CancelRequested) { return "Cancelled" }

        Set-PhaseState -Phase "Dism" -Status "Running" -Progress 40 -Detail "Running ScanHealth..."
        Add-LogLine "  DISM /ScanHealth"
        $null = & Dism.exe /Online /Cleanup-Image /ScanHealth 2>&1
        Add-LogLine "  ScanHealth complete."
        if ($CancelRequested) { return "Cancelled" }

        Set-PhaseState -Phase "Dism" -Status "Running" -Progress 65 -Detail "Running RestoreHealth (can take several minutes)..."
        Add-LogLine "  DISM /RestoreHealth"
        $dismOut = (& Dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String)
        $ec = $LASTEXITCODE
        Add-LogLine "  RestoreHealth exit code: $ec"

        # Surface the most useful diagnostic lines from DISM output. The full output is
        # noisy (progress bar updates, timestamps) so we filter to the meaningful ones.
        if ($dismOut) {
            $relevantLines = $dismOut -split "`r?`n" |
                Where-Object {
                    $_ -match 'source files could not be (found|downloaded)|component store is repairable|corruption|unable to|failed|Error:|error code|repair operation completed' -and
                    $_ -notmatch '^\[=+'
                } | Select-Object -Unique -First 8
            foreach ($l in $relevantLines) {
                $trimmed = $l.Trim()
                if ($trimmed) { Add-LogLine "    DISM: $trimmed" }
            }
        }

        if ($ec -ne 0) {
            $detail = "RestoreHealth reported issues (exit $ec)."
            if ($dismOut -match "source files could not be found|source files could not be downloaded") {
                $detail = "RestoreHealth: source files unavailable. Needs a known-good install.wim as source."
            }
            Set-PhaseState -Phase "Dism" -Status "Warning" -Progress 100 -Detail $detail
            return "Warning"
        }
        Set-PhaseState -Phase "Dism" -Status "Done" -Progress 100 -Detail "All DISM checks passed."
        return "Done"
    }

    function Invoke-PhaseSfc {
        Set-PhaseState -Phase "Sfc" -Status "Running" -Progress 0
        Add-LogLine "Phase 2: Running SFC /SCANNOW..."
        Set-PhaseState -Phase "Sfc" -Status "Running" -Progress 20 -Detail "Scanning system files..."

        # SFC outputs UTF-16LE on Windows, and PowerShell's default native-output capture
        # sometimes truncates or garbles it. Redirect to a temp file and read it explicitly.
        $sfcLog = Join-Path $env:TEMP "sfc-out_$([Guid]::NewGuid().ToString('N')).txt"
        try {
            & sfc.exe /scannow 2>&1 | Out-File -FilePath $sfcLog -Encoding Unicode
            $ec = $LASTEXITCODE
        } catch {
            Add-LogLine "  SFC invocation failed: $_"
            Set-PhaseState -Phase "Sfc" -Status "Error" -Progress 100 -Detail "SFC failed to run."
            return "Error"
        }

        $out = ""
        if (Test-Path $sfcLog) {
            # Try Unicode first, fall back to default if that yields nothing readable
            try { $out = Get-Content $sfcLog -Raw -Encoding Unicode } catch { }
            if (-not $out -or $out.Length -lt 20) {
                try { $out = Get-Content $sfcLog -Raw -Encoding Default } catch { }
            }
            Remove-Item $sfcLog -Force -ErrorAction SilentlyContinue
        }
        # Strip nulls that leak through when encoding detection is wrong
        if ($out) { $out = $out -replace "`0", "" }

        Add-LogLine "  SFC exit code: $ec (output length: $($out.Length) chars)"
        if ($CancelRequested) { return "Cancelled" }

        if ($out -match "did not find any integrity violations") {
            Set-PhaseState -Phase "Sfc" -Status "Done" -Progress 100 -Detail "No integrity violations found."
            return "Done"
        } elseif ($out -match "successfully repaired") {
            Set-PhaseState -Phase "Sfc" -Status "Done" -Progress 100 -Detail "Integrity violations found and repaired."
            return "Done"
        } elseif ($out -match "found corrupt files but was unable to fix") {
            # Surface the real story: SFC found problems but couldn't fix them.
            Set-PhaseState -Phase "Sfc" -Status "Warning" -Progress 100 -Detail "SFC found unfixable corruption. Review CBS.log."
            Add-LogLine "  SFC found corrupt files but could not repair all of them."
            return "Warning"
        } elseif ($ec -eq 0 -and $out.Length -gt 0) {
            # Exit code 0 but no matching phrase - usually means it ran fine but our
            # output capture was imperfect. Treat as success.
            Set-PhaseState -Phase "Sfc" -Status "Done" -Progress 100 -Detail "SFC completed (exit 0)."
            return "Done"
        } else {
            Set-PhaseState -Phase "Sfc" -Status "Warning" -Progress 100 -Detail "SFC reported issues (exit $ec). Review CBS.log."
            return "Warning"
        }
    }

    # ========================================================================
    # Invoke-LsuHistoryQuery
    # ------------------------------------------------------------------------
    # Queries Lenovo System Update's update_history.db SQLite file. Returns a
    # hashtable mapping package id -> object{Id, Title, Status, Version, Severity, InstallDate}.
    #
    # Why this is non-trivial: Windows doesn't ship sqlite3.exe on PATH, and
    # System.Data.SQLite isn't in the GAC. Windows 10 1803+ ships winsqlite3.dll
    # but it has no managed wrapper. We take two paths:
    #   1. If PSSQLite module is installed, use it (fast, clean).
    #   2. Otherwise install PSSQLite on-demand from PSGallery (same pattern as
    #      PSWindowsUpdate). It's a pure-managed SQLite wrapper - small, no native deps.
    # ========================================================================
    function Invoke-LsuHistoryQuery {
        param([string]$DbPath)
        if (-not (Test-Path $DbPath)) { return @{} }

        if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
            try {
                $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue
                Install-Module -Name PSSQLite -Force -Confirm:$false -Scope CurrentUser -ErrorAction Stop
                # Refresh module path so the freshly-installed module is visible
                $env:PSModulePath = @(
                    $env:PSModulePath,
                    [Environment]::GetEnvironmentVariable('PSModulePath','Machine'),
                    [Environment]::GetEnvironmentVariable('PSModulePath','User')
                ) -join ';'
            } catch {
                throw "PSSQLite module install failed: $($_.Exception.Message)"
            }
        }
        Import-Module PSSQLite -Force -ErrorAction Stop

        $rows = Invoke-SqliteQuery -DataSource $DbPath `
            -Query 'SELECT id, title, status, version, severity, installdate, additionalinfo FROM updatehistory' `
            -ErrorAction Stop

        $result = @{}
        foreach ($r in $rows) {
            $result[$r.id] = [pscustomobject]@{
                Id          = $r.id
                Title       = $r.title
                Status      = $r.status
                Version     = $r.version
                Severity    = $r.severity
                InstallDate = $r.installdate
                Info        = $r.additionalinfo
            }
        }
        return $result
    }

    function Invoke-PhaseOem {
        $m = Get-SystemManufacturer
        if ($m -match "Dell") {
            Set-PhaseState -Phase "Oem" -Status "Running" -Progress 0 -Detail "Detecting Dell Command Update..."
            Add-LogLine "Phase 3: Dell system detected."
            $dcu = Find-DellCommandUpdate
            $dcuFreshlyInstalled = $false
            if (-not $dcu) {
                Set-PhaseState -Phase "Oem" -Status "Running" -Progress 10 -Detail "DCU not found. Installing via winget..."
                Add-LogLine "  Dell Command Update not found. Trying winget..."
                try {
                    # --disable-interactivity is supposed to suppress the progress bar, but some
                    # winget versions honor it only for prompts and still emit download-percentage
                    # and byte-count lines. We filter those out post-facto.
                    $wingetOut = & winget install --id Dell.CommandUpdate --silent `
                        --accept-source-agreements --accept-package-agreements `
                        --disable-interactivity 2>&1 | Out-String
                    $wingetEc = $LASTEXITCODE
                    Add-LogLine "  winget exit code: $wingetEc"
                    if ($wingetOut) {
                        # Filter aggressively: drop anything that's just whitespace/glyphs, a
                        # percentage, a "N MB / N MB" progress line, or a spinner animation frame.
                        $cleanLines = $wingetOut -split "`r?`n" | ForEach-Object { $_.Trim() } |
                            Where-Object {
                                $_ -and
                                $_ -notmatch '^\d+%$' -and
                                $_ -notmatch '^[\-\\/|]$' -and
                                $_ -notmatch '^[\u2588\u2591\u2593\s]+$' -and
                                $_ -notmatch '^\d+(\.\d+)?\s*[KMGT]?B\s*/\s*\d+(\.\d+)?\s*[KMGT]?B$' -and
                                $_ -notmatch '^\d+(\.\d+)?\s*[KMGT]?B\s*/\s*\d+(\.\d+)?\s*[KMGT]?B\s*$'
                            } | Select-Object -Unique -First 8
                        foreach ($l in $cleanLines) { Add-LogLine "    winget: $l" }
                    }
                } catch {
                    Add-LogLine "  winget error: $_"
                }
                Start-Sleep -Seconds 8
                $dcu = Find-DellCommandUpdate
                if (-not $dcu) {
                    Add-LogLine "  DCU still not found after winget install attempt."
                    Set-PhaseState -Phase "Oem" -Status "Warning" -Progress 100 -Detail "Could not install DCU. Install manually from dell.com/support."
                    return "Warning"
                }
                Add-LogLine "  DCU found at: $dcu"
                $dcuFreshlyInstalled = $true

                # When DCU is freshly installed, the Dell Client Management Service is often
                # not fully initialized yet, and running /scan or /applyUpdates immediately
                # after install commonly hangs in 3005 forever. Give it a longer grace period
                # and try a targeted service restart to shake it loose.
                Add-LogLine "  Waiting 45s for DellClientManagementService to initialize..."
                Set-PhaseState -Phase "Oem" -Status "Running" -Progress 20 -Detail "Waiting for Dell service to initialize..."
                Start-Sleep -Seconds 45
                try {
                    $svc = Get-Service -Name 'DellClientManagementService' -ErrorAction SilentlyContinue
                    if ($svc) {
                        Add-LogLine "  DellClientManagementService status: $($svc.Status)"
                        if ($svc.Status -ne 'Running') {
                            Add-LogLine "  Starting DellClientManagementService..."
                            Start-Service -Name 'DellClientManagementService' -ErrorAction SilentlyContinue
                            Start-Sleep -Seconds 10
                        }
                    }
                } catch {
                    Add-LogLine "  Could not query/start DellClientManagementService: $_"
                }
            }
            Set-PhaseState -Phase "Oem" -Status "Running" -Progress 30 -Detail "Scanning for available Dell updates..."
            Add-LogLine "  Scanning for Dell updates (dcu-cli /scan)..."
            try {
                # DCU /scan outputs an XML report listing available updates
                $scanReportDir = Join-Path $env:TEMP "DCUScanReport"
                if (Test-Path $scanReportDir) { Remove-Item $scanReportDir -Recurse -Force }
                New-Item -ItemType Directory -Path $scanReportDir -Force | Out-Null
                $null = & $dcu /scan -outputLog="$scanReportDir" 2>&1
                # Look for the XML report file
                $reportXml = Get-ChildItem -Path $scanReportDir -Filter '*.xml' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($reportXml) {
                    [xml]$scanReport = Get-Content $reportXml.FullName -ErrorAction Stop
                    $availableUpdates = $scanReport.SelectNodes('//UpdateInfo') | Where-Object { $_ }
                    if (-not $availableUpdates) {
                        $availableUpdates = $scanReport.SelectNodes('//*[local-name()="Update"]') | Where-Object { $_ }
                    }
                    if ($availableUpdates -and $availableUpdates.Count -gt 0) {
                        Add-LogLine "  Found $($availableUpdates.Count) Dell update(s):"
                        $updateList = @()
                        foreach ($u in $availableUpdates) {
                            $uName = if ($u.name) { $u.name } elseif ($u.Name) { $u.Name } else { "Unknown update" }
                            $uType = if ($u.type) { $u.type } elseif ($u.category) { $u.category } else { "" }
                            $uVer  = if ($u.version) { $u.version } else { "" }
                            $label = "    - $uName"
                            if ($uType) { $label += " [$uType]" }
                            if ($uVer)  { $label += " v$uVer" }
                            Add-LogLine $label
                            $updateList += $uName
                        }
                        $shortList = if ($updateList.Count -le 4) { $updateList -join ', ' } else { ($updateList[0..3] -join ', ') + " +$($updateList.Count - 4) more" }
                        Set-PhaseState -Phase "Oem" -Status "Running" -Progress 40 -Detail "Installing $($updateList.Count) updates: $shortList"
                    } else {
                        Add-LogLine "  DCU scan completed but no individual updates parsed from report."
                        Set-PhaseState -Phase "Oem" -Status "Running" -Progress 40 -Detail "Applying Dell updates..."
                    }
                } else {
                    Add-LogLine "  DCU scan completed but no XML report found. Proceeding with apply."
                    Set-PhaseState -Phase "Oem" -Status "Running" -Progress 40 -Detail "Applying Dell updates..."
                }
            } catch {
                Add-LogLine "  DCU scan parse warning: $($_.Exception.Message). Proceeding with apply."
                Set-PhaseState -Phase "Oem" -Status "Running" -Progress 40 -Detail "Applying Dell updates..."
            }

            # Give the Dell Client Management Service a moment to settle after the scan
            # before firing /applyUpdates. Without this, we commonly get exit code 3005
            # (service is installing pending updates) on the first apply attempt.
            Start-Sleep -Seconds 5

            Add-LogLine "  Running dcu-cli /applyUpdates..."
            # DCU 3000-series codes mean the Dell Client Management Service is transiently busy
            # (3003 busy, 3004 DCU self-update, 3005 installing pending updates). After a /scan we
            # commonly race into 3005 because the service hasn't finished settling. Retry with
            # backoff on those codes before giving up.
            #
            # BUT: if DCU was freshly installed in this run, the service may be genuinely wedged
            # and retrying is futile - this is a well-documented Dell issue where the service
            # requires a full system reboot to recover. We try fewer retries in that case and
            # return a clearer error telling the tech to reboot and rerun.
            $ec = $null
            $dcuAttempt = 0
            $maxDcuAttempts = if ($dcuFreshlyInstalled) { 2 } else { 4 }
            while ($dcuAttempt -lt $maxDcuAttempts) {
                $dcuAttempt++
                $null = & $dcu /applyUpdates -reboot=disable -autoSuspendBitLocker=enable 2>&1
                $ec = $LASTEXITCODE
                if ($ec -in 3003, 3004, 3005) {
                    $waitSec = 20 * $dcuAttempt
                    Add-LogLine "  DCU exit code $ec (service busy). Waiting ${waitSec}s before retry $dcuAttempt/$maxDcuAttempts..."
                    Set-PhaseState -Phase "Oem" -Status "Running" -Progress (40 + ($dcuAttempt * 10)) -Detail "Dell service busy (code $ec). Retry $dcuAttempt/$maxDcuAttempts..."
                    Start-Sleep -Seconds $waitSec
                    if ($CancelRequested) { return "Cancelled" }
                    continue
                }
                break
            }
            Add-LogLine "  DCU exit code: $ec"
            if ($ec -eq 0)   { Set-PhaseState -Phase "Oem" -Status "Done" -Progress 100 -Detail "Dell updates applied."; return "Done" }
            elseif ($ec -eq 500) { Set-PhaseState -Phase "Oem" -Status "Done" -Progress 100 -Detail "No applicable Dell updates."; return "Done" }
            elseif ($ec -eq 1)   { Set-PhaseState -Phase "Oem" -Status "Done" -Progress 100 -Detail "Dell updates applied - reboot required to finalize."; return "RebootNeeded" }
            elseif ($ec -eq 2)   {
                # Exit code 2 isn't in DCU's official CLI error-code table, but it's a Dell
                # Update Package (DUP) code meaning REBOOT_REQUIRED. DCU passes this up from
                # individual BIOS/driver DUPs rather than translating to its own code 1.
                # Treat it as success-with-reboot, same as code 1.
                Set-PhaseState -Phase "Oem" -Status "Done" -Progress 100 -Detail "Dell updates applied - reboot required to finalize."
                return "RebootNeeded"
            }
            elseif ($ec -in 3003, 3004, 3005) {
                if ($dcuFreshlyInstalled) {
                    Add-LogLine "  DCU was freshly installed this run and the service is still busy."
                    Add-LogLine "  This is a known Dell issue where the DellClientManagementService needs a reboot to recover."
                    Add-LogLine "  RECOMMENDED: Let remaining phases finish, then reboot and rerun. DCU will work after reboot."
                    Set-PhaseState -Phase "Oem" -Status "Warning" -Progress 100 -Detail "DCU freshly installed; service needs reboot. Rerun after restart."
                } else {
                    Set-PhaseState -Phase "Oem" -Status "Warning" -Progress 100 -Detail "Dell Client Management Service stayed busy (code $ec) after $maxDcuAttempts retries. Try again later."
                }
                return "Warning"
            }
            else { Set-PhaseState -Phase "Oem" -Status "Warning" -Progress 100 -Detail "DCU exited with code $ec."; return "Warning" }
        }
        elseif ($m -match "Lenovo") {
            Set-PhaseState -Phase "Oem" -Status "Running" -Progress 0 -Detail "Detecting Lenovo System Update..."
            Add-LogLine "Phase 3: Lenovo system detected."
            $lsu = Find-LenovoSystemUpdate
            if (-not $lsu) {
                Set-PhaseState -Phase "Oem" -Status "Running" -Progress 10 -Detail "LSU not found. Installing via winget..."
                Add-LogLine "  Lenovo System Update not found. Trying winget..."
                try {
                    $wingetOut = & winget install --id Lenovo.SystemUpdate --silent `
                        --accept-source-agreements --accept-package-agreements `
                        --disable-interactivity 2>&1 | Out-String
                    Add-LogLine "  winget exit code: $LASTEXITCODE"
                    if ($wingetOut) {
                        $cleanLines = $wingetOut -split "`r?`n" |
                            Where-Object {
                                $line = $_.Trim()
                                $line -and
                                $line -notmatch '^[\p{So}\p{Cf}\s\u2588\u2591\u2593\-\\\|/]*$' -and
                                $line -notmatch '^\s*\d+(\.\d+)?\s*[KMGT]?B\s*/\s*\d+(\.\d+)?\s*[KMGT]?B\s*$'
                            } | Select-Object -First 10
                        foreach ($l in $cleanLines) { Add-LogLine "    winget: $($l.Trim())" }
                    }
                } catch { Add-LogLine "  winget error: $_" }
                Start-Sleep -Seconds 5
                $lsu = Find-LenovoSystemUpdate
                if (-not $lsu) {
                    Set-PhaseState -Phase "Oem" -Status "Warning" -Progress 100 -Detail "Could not install Lenovo System Update. Install manually from support.lenovo.com."
                    return "Warning"
                }
            }
            Set-PhaseState -Phase "Oem" -Status "Running" -Progress 30 -Detail "Scanning for Lenovo updates..."
            # Command-line flags explained:
            #   -search A                  : all updates (critical, recommended, optional)
            #   -action INSTALL            : download and install
            #   -includerebootpackages 1,3,4,5  : all reboot types. Without this, Lenovo defaults
            #                                 to only reboot type 0 (never-requires-reboot).
            #   -noicon                    : suppress the system tray notification icon
            #   -noreboot                  : suppress LSU's auto-reboot after type-3 installs (we handle)
            #   -nolicense                 : suppress the license-acceptance dialog for unattended runs
            #
            # IMPORTANT LIMITATION: Lenovo explicitly documents that Reboot Type 5 updates
            # (BIOS, Intel ME firmware, and some mandatory-reboot firmware) ALWAYS prompt
            # the user before installing. There is no silent-install path for Type 5 through
            # LSU - this is a deliberate Lenovo safety design.
            Add-LogLine "  Running tvsu /CM -search A -action INSTALL -includerebootpackages 1,3,4,5 -noicon -noreboot -nolicense"

            # RESULT PARSING STRATEGY:
            # LSU writes per-package results to a SQLite database at:
            #   C:\ProgramData\Lenovo\SystemUpdate\sessionSE\update_history.db
            # Schema (confirmed on LSU 5.x):
            #   updatehistory(id, title, status, version, additionalinfo, severity, installdate)
            # Status values include: AlreadyInstalled, NotApplicable, Success, Failed,
            #                        Cancelled, UserActionRequired (and possibly others).
            #
            # We capture "last install timestamp per package" BEFORE running LSU, then after
            # the run we query for packages whose installdate changed - those are ones LSU
            # touched this run. Packages that LSU still reports as NotApplicable or
            # AlreadyInstalled with the old timestamp get excluded from "this run" results.
            $historyDb = Join-Path $env:ProgramData 'Lenovo\SystemUpdate\sessionSE\update_history.db'
            $preRunSnapshot = @{}
            if (Test-Path $historyDb) {
                try {
                    $preRunSnapshot = Invoke-LsuHistoryQuery -DbPath $historyDb
                    Add-LogLine "  Pre-run history snapshot: $($preRunSnapshot.Count) package(s) in DB."
                } catch {
                    Add-LogLine "  Could not read pre-run history: $($_.Exception.Message)"
                }
            }

            $null = & $lsu /CM -search A -action INSTALL -includerebootpackages 1,3,4,5 -noicon -noreboot -nolicense 2>&1
            $ec = $LASTEXITCODE
            Add-LogLine "  LSU exit code: $ec"

            # Classification buckets
            $installed = @()      # actually installed this run (Success + new timestamp)
            $failed = @()         # install attempted, failed
            $type5Skipped = @()   # UserActionRequired or similar - needs manual install
            $alreadyInstalled = @() # LSU thinks these were already installed (no action needed)
            $notApplicable = @()  # Not applicable to this hardware config
            $cancelled = @()      # Install was cancelled

            if (Test-Path $historyDb) {
                try {
                    $postRun = Invoke-LsuHistoryQuery -DbPath $historyDb
                    Add-LogLine "  Post-run history snapshot: $($postRun.Count) package(s) in DB."
                    foreach ($id in $postRun.Keys) {
                        $row = $postRun[$id]
                        $status = "$($row.Status)"
                        $title  = "$($row.Title)"
                        $displayName = if ($title) { "$id - $title" } else { $id }

                        # Did this row change since before the run? If installdate is new/changed,
                        # LSU touched it this run.
                        $pre = $preRunSnapshot[$id]
                        $isNewOrChanged = (-not $pre) -or ("$($pre.InstallDate)" -ne "$($row.InstallDate)") -or ("$($pre.Status)" -ne "$($row.Status)")

                        switch -Regex ($status) {
                            '^Success'          { if ($isNewOrChanged) { $installed += $displayName } else { $alreadyInstalled += $displayName }; break }
                            '^Fail'             { $failed += $displayName; break }
                            '^UserAction'       { $type5Skipped += $displayName; break }
                            '^Cancel'           { $cancelled += $displayName; break }
                            '^AlreadyInstalled' { $alreadyInstalled += $displayName; break }
                            '^NotApplicable'    { $notApplicable += $displayName; break }
                            default             {
                                # Unknown status - if it changed this run, log it as a warning
                                if ($isNewOrChanged) {
                                    Add-LogLine "  Unknown status for $id : '$status'"
                                    $type5Skipped += $displayName  # conservative: treat as needing attention
                                } else {
                                    $alreadyInstalled += $displayName
                                }
                            }
                        }
                    }
                } catch {
                    Add-LogLine "  ERROR reading post-run history: $($_.Exception.Message)"
                }
            } else {
                Add-LogLine "  WARNING: $historyDb not found after LSU run. LSU may not have executed properly."
            }

            # Emit per-category log lines
            if ($installed.Count -gt 0) {
                Add-LogLine "  Installed this run ($($installed.Count)):"
                foreach ($u in $installed) { Add-LogLine "    + $u" }
            }
            if ($failed.Count -gt 0) {
                Add-LogLine "  Failed ($($failed.Count)):"
                foreach ($u in $failed) { Add-LogLine "    x $u" }
            }
            if ($type5Skipped.Count -gt 0) {
                Add-LogLine ""
                Add-LogLine "  *** $($type5Skipped.Count) update(s) require manual install via Lenovo Vantage ***"
                foreach ($u in $type5Skipped) { Add-LogLine "    ! $u" }
                Add-LogLine "  *** These are Type-5 packages (BIOS/firmware) that Lenovo designs to always ***"
                Add-LogLine "  *** prompt the user. They cannot be installed silently via LSU CLI. Install ***"
                Add-LogLine "  *** them manually through Lenovo Vantage or the Lenovo System Update GUI.   ***"
                Add-LogLine ""
            }
            if ($cancelled.Count -gt 0) {
                Add-LogLine "  Cancelled ($($cancelled.Count)):"
                foreach ($u in $cancelled) { Add-LogLine "    - $u" }
            }
            if ($alreadyInstalled.Count -gt 0) {
                Add-LogLine "  Already installed - no action needed ($($alreadyInstalled.Count))."
            }
            if ($notApplicable.Count -gt 0) {
                Add-LogLine "  Not applicable to this hardware ($($notApplicable.Count))."
            }

            # Build GUI detail
            $parts = @()
            if ($installed.Count -gt 0)    { $parts += "$($installed.Count) installed" }
            if ($type5Skipped.Count -gt 0) { $parts += "$($type5Skipped.Count) require Lenovo Vantage" }
            if ($failed.Count -gt 0)       { $parts += "$($failed.Count) failed" }
            if ($cancelled.Count -gt 0)    { $parts += "$($cancelled.Count) cancelled" }
            if ($parts.Count -eq 0) {
                if (($alreadyInstalled.Count + $notApplicable.Count) -gt 0) {
                    $parts += "System is up to date ($($alreadyInstalled.Count) already installed, $($notApplicable.Count) N/A)"
                } else {
                    $parts += "No applicable Lenovo updates."
                }
            }
            $detail = $parts -join '; '

            # Outcome
            if ($failed.Count -gt 0 -or $type5Skipped.Count -gt 0) {
                Set-PhaseState -Phase "Oem" -Status "Warning" -Progress 100 -Detail $detail
                if ($installed.Count -gt 0) { return "RebootNeeded" }
                return "Warning"
            } elseif ($installed.Count -gt 0) {
                Set-PhaseState -Phase "Oem" -Status "Done" -Progress 100 -Detail "$detail - reboot recommended."
                return "RebootNeeded"
            } elseif ($ec -eq 0 -or $null -eq $ec) {
                Set-PhaseState -Phase "Oem" -Status "Done" -Progress 100 -Detail $detail
                return "Done"
            } else {
                Set-PhaseState -Phase "Oem" -Status "Warning" -Progress 100 -Detail "$detail (LSU exit $ec)"
                return "Warning"
            }
        }
        else {
            Set-PhaseState -Phase "Oem" -Status "Skipped" -Progress 100 -Detail "Manufacturer '$m' - no supported OEM updater."
            Add-LogLine "Phase 3: Skipped (unsupported manufacturer: $m)"
            return "Skipped"
        }
    }

    function Invoke-PhaseWindowsUpdate {
        Set-PhaseState -Phase "WU" -Status "Running" -Progress 0
        Add-LogLine "Phase 4: Windows Update..."
        Set-PhaseState -Phase "WU" -Status "Running" -Progress 10 -Detail "Checking PSWindowsUpdate module..."
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Add-LogLine "  Installing PSWindowsUpdate module..."
            Set-PhaseState -Phase "WU" -Status "Running" -Progress 15 -Detail "Installing PSWindowsUpdate module..."
            try {
                $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop
                Install-Module -Name PSWindowsUpdate -Force -Confirm:$false -ErrorAction Stop
                Add-LogLine "  PSWindowsUpdate installed."
                # Refresh the module path so this runspace can find the freshly installed module.
                # Install-Module drops it into a path that the background runspace doesn't know about
                # until we manually rebuild PSModulePath from the registry + user paths.
                $machinePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
                $userPath    = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
                $currentPath = $env:PSModulePath
                $allPaths    = @($currentPath, $machinePath, $userPath) | ForEach-Object { $_ -split ';' } |
                               Where-Object { $_ -and (Test-Path $_ -ErrorAction SilentlyContinue) } |
                               Select-Object -Unique
                $env:PSModulePath = $allPaths -join ';'
                Add-LogLine "  Refreshed PSModulePath for runspace."
            } catch {
                Add-LogLine "  ERROR installing PSWindowsUpdate: $_"
                Set-PhaseState -Phase "WU" -Status "Error" -Progress 100 -Detail "Failed to install PSWindowsUpdate."
                return "Error"
            }
        }
        try {
            Import-Module PSWindowsUpdate -Force -ErrorAction Stop
            Add-LogLine "  PSWindowsUpdate module loaded."
        } catch {
            Add-LogLine "  ERROR loading PSWindowsUpdate: $_"
            Set-PhaseState -Phase "WU" -Status "Error" -Progress 100 -Detail "Failed to load PSWindowsUpdate module."
            return "Error"
        }
        if ($CancelRequested) { return "Cancelled" }

        # Pre-accept the Microsoft Update service so we don't get prompted mid-install.
        # The runspace is non-interactive; any PromptForChoice call will hard-throw.
        try {
            Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } catch { }

        Set-PhaseState -Phase "WU" -Status "Running" -Progress 30 -Detail "Searching for available Windows updates..."
        Add-LogLine "  Searching for updates..."

        # PRE-FLIGHT: Check if Windows is already in "updates installed, waiting for reboot"
        # state. This happens when a prior run installed updates but the user didn't reboot.
        # PSWindowsUpdate will happily list these as "pending" and Install-WindowsUpdate will
        # HANG trying to reinstall them because the installer service is blocked by the
        # pending-reboot state. Detect and short-circuit before we get stuck.
        $wuRebootRequired = $false
        try {
            # The most reliable check: HKLM\...\WindowsUpdate\Auto Update\RebootRequired
            # is set by WU itself when updates are installed but pending reboot.
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
                $wuRebootRequired = $true
            }
        } catch { }
        # Also check PSWindowsUpdate's view - it looks at additional indicators
        try {
            if ((Get-WURebootStatus -Silent -ErrorAction SilentlyContinue) -eq $true) {
                $wuRebootRequired = $true
            }
        } catch { }

        if ($wuRebootRequired) {
            Add-LogLine "  Pre-flight: Windows Update already has installed updates awaiting reboot."
            Add-LogLine "  Skipping Install-WindowsUpdate call to avoid hanging on already-applied updates."
            Set-PhaseState -Phase "WU" -Status "Done" -Progress 100 -Detail "Updates already installed - reboot required to finalize."
            return "RebootNeeded"
        }

        try {
            # First pass: scan only (no install) to list what's available
            $pending = Get-WindowsUpdate -MicrosoftUpdate -IgnoreUserInput -Confirm:$false -ErrorAction Stop
            if ($pending -and $pending.Count -gt 0) {
                Add-LogLine "  Found $($pending.Count) available update(s):"
                $updateNames = @()
                foreach ($u in $pending) {
                    $kb = if ($u.KB) { "KB$($u.KB)" } else { "no-KB" }
                    $title = if ($u.Title) { $u.Title } else { "Untitled update" }
                    # PSWindowsUpdate is inconsistent about .Size units (bytes vs KB vs MB depending
                    # on how the update was surfaced). MaxDownloadSize on the underlying COM object
                    # is consistently bytes. Prefer .Size string property when it's already formatted.
                    $sizeStr = ""
                    if ($u.Size -is [string] -and $u.Size -match '[KMGT]B') {
                        $sizeStr = $u.Size
                    } elseif ($u.MaxDownloadSize) {
                        $mb = [math]::Round($u.MaxDownloadSize / 1MB, 1)
                        $sizeStr = if ($mb -ge 1024) { "{0:N1} GB" -f ($mb / 1024) } else { "{0:N1} MB" -f $mb }
                    } elseif ($u.Size -and [long]$u.Size -gt 0) {
                        $bytes = [long]$u.Size
                        # Heuristic: if it's unreasonably large (>50GB), it's probably already in KB
                        if ($bytes -gt 50GB) { $bytes = $bytes * 1024 -bxor 0; $mb = [math]::Round(([long]$u.Size) / 1KB, 1) }
                        else { $mb = [math]::Round($bytes / 1MB, 1) }
                        $sizeStr = if ($mb -ge 1024) { "{0:N1} GB" -f ($mb / 1024) } else { "{0:N1} MB" -f $mb }
                    }
                    $label = "    - [$kb] $title"
                    if ($sizeStr) { $label += " ($sizeStr)" }
                    Add-LogLine $label
                    $updateNames += $title
                }
                $shortList = if ($updateNames.Count -le 3) { $updateNames -join ', ' } else { ($updateNames[0..2] -join ', ') + " +$($updateNames.Count - 3) more" }
                Set-PhaseState -Phase "WU" -Status "Running" -Progress 40 -Detail "Installing $($pending.Count) updates: $shortList"

                # Second pass: actually install. Key flags:
                #   -AcceptAll       : auto-accept EULAs
                #   -IgnoreUserInput : suppress PromptForChoice calls that break non-interactive hosts
                #   -IgnoreReboot    : don't let PSWindowsUpdate trigger a reboot (we handle that)
                #   -MicrosoftUpdate : include drivers + .NET + Office updates alongside Windows Update
                Add-LogLine "  Installing updates..."

                # Run the install in a background job with a hard timeout. If PSWindowsUpdate
                # gets stuck waiting on the update installer (which happens when updates are
                # already staged and waiting for reboot, despite our pre-flight check), we
                # don't want the whole tool frozen for hours. 45 minutes is generous for 2-3
                # updates including large cumulative ones.
                $wuJob = Start-Job -ScriptBlock {
                    Import-Module PSWindowsUpdate -Force
                    try {
                        Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    } catch { }
                    Install-WindowsUpdate -AcceptAll -IgnoreUserInput -IgnoreReboot -MicrosoftUpdate -Confirm:$false -ErrorAction Stop
                }
                $timeoutMinutes = 45
                $completed = Wait-Job -Job $wuJob -Timeout ($timeoutMinutes * 60)
                if (-not $completed) {
                    # Timed out
                    Add-LogLine "  Install-WindowsUpdate timed out after $timeoutMinutes minutes. Stopping job."
                    Stop-Job -Job $wuJob -ErrorAction SilentlyContinue
                    Remove-Job -Job $wuJob -Force -ErrorAction SilentlyContinue

                    # Re-check reboot state. If updates actually staged, treat as reboot-needed.
                    $postRebootRequired = $false
                    try {
                        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
                            $postRebootRequired = $true
                        }
                    } catch { }
                    if ($postRebootRequired) {
                        Add-LogLine "  Updates staged during timeout; reboot is required to finalize."
                        Set-PhaseState -Phase "WU" -Status "Done" -Progress 100 -Detail "Install timed out but updates staged - reboot required."
                        return "RebootNeeded"
                    } else {
                        Set-PhaseState -Phase "WU" -Status "Warning" -Progress 100 -Detail "Install-WindowsUpdate timed out after $timeoutMinutes min. Check WU manually."
                        return "Warning"
                    }
                }
                $updates = Receive-Job -Job $wuJob -ErrorAction SilentlyContinue
                Remove-Job -Job $wuJob -Force -ErrorAction SilentlyContinue

                # Log individual results if available
                if ($updates) {
                    foreach ($u in $updates) {
                        $kb = if ($u.KB) { "KB$($u.KB)" } else { "no-KB" }
                        $title = if ($u.Title) { $u.Title } else { "Untitled" }
                        $result = if ($u.Result) { $u.Result } elseif ($u.Status) { $u.Status } else { "installed" }
                        Add-LogLine "    - [$kb] $title => $result"
                    }
                }

                $c = $pending.Count
                Add-LogLine "  Processed $c update(s)."
                # Check for pending reboot after install - matches the pattern used by the OEM phase
                $rebootPending = $false
                try { $rebootPending = (Get-WURebootStatus -Silent -ErrorAction SilentlyContinue) -eq $true } catch { }
                if ($rebootPending) {
                    Set-PhaseState -Phase "WU" -Status "Done" -Progress 100 -Detail "Installed $c update(s). Reboot required."
                    return "RebootNeeded"
                } else {
                    Set-PhaseState -Phase "WU" -Status "Done" -Progress 100 -Detail "Installed $c update(s)."
                    return "Done"
                }
            } else {
                Add-LogLine "  No pending updates found."
                Set-PhaseState -Phase "WU" -Status "Done" -Progress 100 -Detail "System is up to date."
                return "Done"
            }
        } catch {
            $errMsg = $_.Exception.Message
            Add-LogLine "  ERROR during Windows Update: $errMsg"
            # If it's the known non-interactive host error, give the tech a clearer message
            if ($errMsg -match "host program.*does not support user interaction|prompts the user failed") {
                Set-PhaseState -Phase "WU" -Status "Error" -Progress 100 -Detail "WU blocked by interactive prompt. An update needs EULA acceptance not auto-handled by PSWindowsUpdate."
            } else {
                Set-PhaseState -Phase "WU" -Status "Error" -Progress 100 -Detail "Windows Update failed: $errMsg"
            }
            return "Error"
        }
    }

    # -------- Main loop (mode-aware) --------
    # ActivePhases controls which phases execute in this run.
    $phaseCount = $ActivePhases.Count
    $needsReboot = $false
    $rebootTriggeredBy = $null
    $idx = [array]::IndexOf($ActivePhases, $ResumeFrom)
    if ($idx -lt 0) { $idx = 0 }

    # Mark earlier active phases as Done (resume-from-session case)
    for ($i = 0; $i -lt $idx; $i++) {
        Set-PhaseState -Phase $ActivePhases[$i] -Status "Done" -Progress 100 -Detail "Completed in prior session."
    }
    if ($idx -gt 0) {
        Set-OverallProgress ([int](($idx / $phaseCount) * 100))
    }

    # Friendly labels for the overall-progress "current phase" indicator
    $phaseLabels = @{
        'Dism' = 'DISM Health Repair'
        'Sfc'  = 'System File Checker'
        'Oem'  = 'OEM Driver Updates'
        'WU'   = 'Windows Update'
    }

    for ($i = $idx; $i -lt $phaseCount; $i++) {
        $phase = $ActivePhases[$i]
        if ($CancelRequested) {
            Set-PhaseState -Phase $phase -Status "Skipped" -Progress 0 -Detail "Cancelled by user."
            continue
        }
        Save-SessionState @{
            ResumePhase = $phase
            RunMode     = $RunMode
            StartedAt   = (Get-Date).ToString("o")
        }
        $label = if ($phaseLabels[$phase]) { "Running: $($phaseLabels[$phase])" } else { "" }
        Set-OverallProgress ([int](($i / $phaseCount) * 100)) $label
        $result = switch ($phase) {
            "Dism" { Invoke-PhaseDism }
            "Sfc"  { Invoke-PhaseSfc }
            "Oem"  { Invoke-PhaseOem }
            "WU"   { Invoke-PhaseWindowsUpdate }
        }
        Set-OverallProgress ([int]((($i + 1) / $phaseCount) * 100))
        if ($result -eq "Cancelled") { break }
        if ($result -eq "RebootNeeded") {
            $needsReboot = $true
            # Record which phase asked for the reboot so we can resume at the right place.
            $rebootTriggeredBy = $ActivePhases[$i]
        }
    }

    # After loop completes, clear the "Running:" label
    if (-not $CancelRequested) {
        Set-OverallProgress 100 ""
    }

    # -------- Completion --------
    if (-not $CancelRequested) {
        if ($needsReboot) {
            Add-LogLine "Some updates require a restart."
            # Figure out where to resume. If the reboot was triggered by any phase BEFORE WU,
            # resume at WU. If WU itself triggered the reboot (which is what our new code does
            # when Get-WURebootStatus comes back true), there's nothing meaningful to resume to -
            # just clear session state so the tool starts fresh next time.
            $resumePhase = $null
            if ($rebootTriggeredBy -and $rebootTriggeredBy -ne "WU") {
                # Find the phase after the one that triggered the reboot
                $triggerIdx = [array]::IndexOf($ActivePhases, $rebootTriggeredBy)
                if ($triggerIdx -ge 0 -and $triggerIdx -lt ($ActivePhases.Count - 1)) {
                    $resumePhase = $ActivePhases[$triggerIdx + 1]
                }
            }

            if ($resumePhase) {
                Add-LogLine "  Session will resume at: $resumePhase"
                Save-SessionState @{
                    ResumePhase = $resumePhase
                    RunMode     = $RunMode
                    NeedsReboot = $true
                    StartedAt   = (Get-Date).ToString("o")
                }
                Register-ResumeOnReboot
            } else {
                # WU triggered the reboot, or trigger unknown. No resume needed - just restart.
                Add-LogLine "  No resume needed - all phases complete, just awaiting restart."
                Remove-SessionStateRunspace
            }

            Invoke-OnUI {
                $UI['btnStartFull'].Content = "Restart Now to Continue"
                $UI['btnStartFull'].Background = $BrushConverter.ConvertFromString("#d29922")
                $UI['btnStartFull'].IsEnabled = $true
                $UI['btnStartFull'].Tag = if ($resumePhase) { "RestartMode" } else { "OfferRestart" }
                $UI['btnStartUpdatesOnly'].Content = "Restart Now to Continue"
                $UI['btnStartUpdatesOnly'].Background = $BrushConverter.ConvertFromString("#d29922")
                $UI['btnStartUpdatesOnly'].IsEnabled = $true
                $UI['btnStartUpdatesOnly'].Tag = if ($resumePhase) { "RestartMode" } else { "OfferRestart" }
                $UI['btnCancel'].Visibility = "Collapsed"
            }
        } else {
            Add-LogLine "All phases complete!"
            Remove-SessionStateRunspace
            Invoke-OnUI {
                $UI['btnStartFull'].Content = "All Done - Restart Now?"
                $UI['btnStartFull'].Background = $BrushConverter.ConvertFromString("#2ea043")
                $UI['btnStartFull'].IsEnabled = $true
                $UI['btnStartFull'].Tag = "OfferRestart"
                $UI['btnStartUpdatesOnly'].Content = "Run Updates Only Again"
                $UI['btnStartUpdatesOnly'].Background = $BrushConverter.ConvertFromString("#58a6ff")
                $UI['btnStartUpdatesOnly'].IsEnabled = $true
                $UI['btnStartUpdatesOnly'].Tag = $null
                $UI['btnCancel'].Visibility = "Collapsed"
            }
        }
    } else {
        Add-LogLine "Operation cancelled."
        Remove-SessionStateRunspace
        Invoke-OnUI {
            $UI['btnStartFull'].Content = "Full Repair (DISM + SFC + Updates)"
            $UI['btnStartFull'].Background = $BrushConverter.ConvertFromString("#2ea043")
            $UI['btnStartFull'].IsEnabled = $true
            $UI['btnStartFull'].Tag = $null
            $UI['btnStartUpdatesOnly'].Content = "Updates Only (Drivers + Windows)"
            $UI['btnStartUpdatesOnly'].Background = $BrushConverter.ConvertFromString("#58a6ff")
            $UI['btnStartUpdatesOnly'].IsEnabled = $true
            $UI['btnStartUpdatesOnly'].Tag = $null
            $UI['btnCancel'].Visibility = "Collapsed"
        }
    }
}

# ============================================================================
#  START-REPAIR-RUN helper (main thread)
# ============================================================================
$Script:WorkerRunspace   = $null
$Script:WorkerPowerShell = $null
$Script:CancelRequested  = $false

function Start-RepairRun {
    param(
        [Parameter(Mandatory)][ValidateSet("Full","UpdatesOnly")]
        [string]$RunMode,
        [string]$ResumeFrom = ""
    )

    $Script:CancelRequested = $false

    # Disable both start buttons, show cancel
    $Script:UI['btnStartFull'].IsEnabled = $false
    $Script:UI['btnStartUpdatesOnly'].IsEnabled = $false
    if ($RunMode -eq "Full") {
        $Script:UI['btnStartFull'].Content = "Running Full Repair..."
        $Script:UI['btnStartUpdatesOnly'].Content = "Updates Only (disabled)"
    } else {
        $Script:UI['btnStartUpdatesOnly'].Content = "Running Updates..."
        $Script:UI['btnStartFull'].Content = "Full Repair (disabled)"
    }
    $Script:UI['btnCancel'].Visibility = "Visible"
    $Script:UI['btnCancel'].IsEnabled = $true
    $Script:UI['btnCancel'].Content = "Cancel"

    # Active phases per mode
    $activePhases = if ($RunMode -eq "Full") {
        @("Dism","Sfc","Oem","WU")
    } else {
        @("Oem","WU")
    }

    # Visually gray out skipped phases in UpdatesOnly mode
    if ($RunMode -eq "UpdatesOnly") {
        Set-PhaseStateMain -Phase "Dism" -Status "Skipped" -Progress 0 -Detail "Skipped (Updates-Only mode)."
        Set-PhaseStateMain -Phase "Sfc"  -Status "Skipped" -Progress 0 -Detail "Skipped (Updates-Only mode)."
    }

    if (-not $ResumeFrom) { $ResumeFrom = $activePhases[0] }

    Add-LogLineMain "Starting run: Mode=$RunMode, ResumeFrom=$ResumeFrom"

    # Launch runspace
    $Script:WorkerRunspace = [runspacefactory]::CreateRunspace()
    $Script:WorkerRunspace.ApartmentState = "STA"
    $Script:WorkerRunspace.ThreadOptions  = "ReuseThread"
    $Script:WorkerRunspace.Open()

    $Script:WorkerRunspace.SessionStateProxy.SetVariable("Window", $Script:Window)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("UI", $Script:UI)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("StateFile", $Script:StateFile)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("LogFile", $Script:LogFile)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("RunKeyPath", $Script:RunKeyPath)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("RunKeyName", $Script:RunKeyName)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("ScriptPath", $Script:ScriptPath)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("BrushConverter", $Script:BrushConverter)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("CancelRequested", $false)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("ResumeFrom", $ResumeFrom)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("RunMode", $RunMode)
    $Script:WorkerRunspace.SessionStateProxy.SetVariable("ActivePhases", $activePhases)

    $Script:WorkerPowerShell = [powershell]::Create()
    $Script:WorkerPowerShell.Runspace = $Script:WorkerRunspace
    $null = $Script:WorkerPowerShell.AddScript($Script:WorkerScriptBlock)
    $null = $Script:WorkerPowerShell.BeginInvoke()
}

# ============================================================================
#  BUTTON HANDLERS
# ============================================================================
$Script:UI['btnStartFull'].Add_Click({
    $tag = $Script:UI['btnStartFull'].Tag
    if ($tag -eq "RestartMode" -or $tag -eq "OfferRestart") {
        $result = [System.Windows.MessageBox]::Show(
            "The system needs to restart to complete updates.`n`nRestart now?",
            "Restart Required",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($result -eq "Yes") {
            if ($tag -eq "RestartMode") { Register-ResumeOnRebootMain }
            else { Remove-SessionStateMain }
            & shutdown.exe /r /t 5 /c "System Repair - Restarting"
            $Script:Window.Close()
        }
        return
    }

    # Normal click - check for existing session
    $session = Get-SessionState
    $resumeFrom = ""
    $runMode = "Full"
    if ($session -and $session.ResumePhase) {
        $resumeFrom = $session.ResumePhase
        if ($session.RunMode) { $runMode = $session.RunMode }
    }
    Start-RepairRun -RunMode $runMode -ResumeFrom $resumeFrom
})

$Script:UI['btnStartUpdatesOnly'].Add_Click({
    $tag = $Script:UI['btnStartUpdatesOnly'].Tag
    if ($tag -eq "RestartMode" -or $tag -eq "OfferRestart") {
        $result = [System.Windows.MessageBox]::Show(
            "The system needs to restart to complete updates.`n`nRestart now?",
            "Restart Required",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($result -eq "Yes") {
            if ($tag -eq "RestartMode") { Register-ResumeOnRebootMain }
            else { Remove-SessionStateMain }
            & shutdown.exe /r /t 5 /c "System Repair - Restarting"
            $Script:Window.Close()
        }
        return
    }

    $session = Get-SessionState
    $resumeFrom = ""
    if ($session -and $session.ResumePhase -and $session.RunMode -eq "UpdatesOnly") {
        $resumeFrom = $session.ResumePhase
    }
    Start-RepairRun -RunMode "UpdatesOnly" -ResumeFrom $resumeFrom
})

$Script:UI['btnCancel'].Add_Click({
    $Script:CancelRequested = $true
    if ($Script:WorkerRunspace) {
        $Script:WorkerRunspace.SessionStateProxy.SetVariable("CancelRequested", $true)
    }
    Add-LogLineMain "Cancellation requested - finishing current operation..."
    $Script:UI['btnCancel'].IsEnabled = $false
    $Script:UI['btnCancel'].Content = "Cancelling..."
})

# ============================================================================
# btnStartOver
# ----------------------------------------------------------------------------
# Clears any saved session state (session.json + Run registry key) and resets
# the main buttons so the next click starts from Phase 1 instead of resuming.
# Only visible when a resume session was detected at launch.
# ============================================================================
$Script:UI['btnStartOver'].Add_Click({
    $result = [System.Windows.MessageBox]::Show(
        "This will discard the saved session state.`n`nThe next run will start from Phase 1 instead of resuming from where the previous session left off.`n`nContinue?",
        "Start Over?",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($result -ne "Yes") { return }

    # Nuke the session file and the Run registry key
    Remove-SessionStateMain
    Add-LogLineMain "Session state cleared by user. Next run will start from Phase 1."

    # Reset button state to "fresh start" appearance
    $Script:UI['btnStartFull'].IsEnabled = $true
    $Script:UI['btnStartFull'].Content = "Full Repair (DISM + SFC + Updates)"
    $Script:UI['btnStartFull'].Background = $Script:BrushConverter.ConvertFromString("#2ea043")
    $Script:UI['btnStartFull'].Tag = $null

    $Script:UI['btnStartUpdatesOnly'].IsEnabled = $true
    $Script:UI['btnStartUpdatesOnly'].Content = "Updates Only (Drivers + Windows)"
    $Script:UI['btnStartUpdatesOnly'].Background = $Script:BrushConverter.ConvertFromString("#58a6ff")
    $Script:UI['btnStartUpdatesOnly'].Tag = $null

    # Hide the Start Over button itself - there's nothing to start over now
    $Script:UI['btnStartOver'].Visibility = "Collapsed"

    # Reset each phase card to Pending appearance. Bypass Set-PhaseStateMain and
    # set fields directly because we need to (a) clear the detail text (the helper
    # skips empty detail to avoid overwriting), and (b) reset the progress bar
    # foreground (the helper only applies color for Warning/Error states).
    $pendingBrush = $Script:BrushConverter.ConvertFromString("#8b949e")
    $defaultProgBrush = $Script:BrushConverter.ConvertFromString("#2ea043")
    foreach ($phase in @('Dism','Sfc','Oem','WU')) {
        $icon   = $Script:UI["icon$phase"]
        $status = $Script:UI["txt${phase}Status"]
        $prog   = $Script:UI["prog$phase"]
        $detail = $Script:UI["txt${phase}Detail"]
        if ($icon)   { $icon.Text = "o"; $icon.Foreground = $pendingBrush }
        if ($status) { $status.Text = "Pending"; $status.Foreground = $pendingBrush }
        if ($prog)   { $prog.Value = 0; $prog.Foreground = $defaultProgBrush }
        if ($detail) { $detail.Text = "" }
    }
    # Reset overall progress
    $Script:UI['progressOverall'].Value = 0
    $Script:UI['txtOverallPct'].Text = "0%"
})

$Script:UI['btnOpenLog'].Add_Click({
    if (Test-Path $Script:LogFile) {
        Start-Process notepad.exe -ArgumentList $Script:LogFile
    } else {
        [System.Windows.MessageBox]::Show("Log file not yet created.", "Info")
    }
})

# ============================================================================
#  ADDITIONAL TOOLS - bundled utilities
# ============================================================================
# Both tools are bundled alongside SystemRepairTool.ps1 and launched in their
# own console windows. This keeps the interactive menus/prompts in
# Remove-StalePrinters.ps1 fully functional and isolates them from the main
# repair session state.

$Script:ToolsRoot       = Split-Path -Parent $Script:ScriptPath
$Script:PrinterToolPath = Join-Path $Script:ToolsRoot 'Remove-StalePrinters.ps1'
$Script:NetDiagPath     = Join-Path $Script:ToolsRoot 'network-diag.bat'
$Script:PaperCutToolPath = Join-Path $Script:ToolsRoot 'Install-PaperCutClient.ps1'

function Set-ToolsStatusMain {
    param([string]$Message, [string]$Color = '#8b949e')
    Invoke-OnUIMain {
        $Script:UI['txtToolsStatus'].Text = $Message
        $Script:UI['txtToolsStatus'].Foreground = $Script:BrushConverter.ConvertFromString($Color)
    }
}

$Script:UI['btnRemovePrinters'].Add_Click({
    if (-not (Test-Path $Script:PrinterToolPath)) {
        Set-ToolsStatusMain "Remove-StalePrinters.ps1 not found next to SystemRepairTool.ps1" '#f85149'
        Add-LogLineMain "[Tools] Printer tool missing: $Script:PrinterToolPath"
        return
    }
    try {
        # -NoExit keeps the window open after the script finishes so the tech can review output.
        # This runs as a separate elevated process - the interactive menu, prompts, and colored
        # output all work natively in the console window.
        $psArgs = @(
            '-NoExit'
            '-ExecutionPolicy', 'Bypass'
            '-File', "`"$Script:PrinterToolPath`""
        )
        Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -Verb RunAs -ErrorAction Stop | Out-Null
        Set-ToolsStatusMain "Stale printer tool launched in a new console window." '#2ea043'
        Add-LogLineMain "[Tools] Launched Remove-StalePrinters.ps1"
    } catch {
        Set-ToolsStatusMain ("Failed to launch printer tool: {0}" -f $_.Exception.Message) '#f85149'
        Add-LogLineMain "[Tools] Error launching printer tool: $($_.Exception.Message)"
    }
})

$Script:UI['btnPaperCut'].Add_Click({
    if (-not (Test-Path $Script:PaperCutToolPath)) {
        Set-ToolsStatusMain "Install-PaperCutClient.ps1 not found next to SystemRepairTool.ps1" '#f85149'
        Add-LogLineMain "[Tools] PaperCut tool missing: $Script:PaperCutToolPath"
        return
    }
    try {
        # Same pattern as the printer tool: launch in a new elevated PowerShell console
        # with -NoExit so the tech can review output. The script handles MSI uninstall/install
        # with retry logic and prints colored status.
        $psArgs = @(
            '-NoExit'
            '-ExecutionPolicy', 'Bypass'
            '-File', "`"$Script:PaperCutToolPath`""
        )
        Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -Verb RunAs -ErrorAction Stop | Out-Null
        Set-ToolsStatusMain "PaperCut installer tool launched in a new console window." '#2ea043'
        Add-LogLineMain "[Tools] Launched Install-PaperCutClient.ps1"
    } catch {
        Set-ToolsStatusMain ("Failed to launch PaperCut tool: {0}" -f $_.Exception.Message) '#f85149'
        Add-LogLineMain "[Tools] Error launching PaperCut tool: $($_.Exception.Message)"
    }
})

$Script:UI['btnNetDiag'].Add_Click({
    if (-not (Test-Path $Script:NetDiagPath)) {
        Set-ToolsStatusMain "network-diag.bat not found next to SystemRepairTool.ps1" '#f85149'
        Add-LogLineMain "[Tools] Network diag missing: $Script:NetDiagPath"
        return
    }
    try {
        # /c runs the batch and closes cmd when it finishes. The batch itself
        # auto-opens the log in Notepad before exiting, so the tech still sees
        # the results without needing the cmd window to linger.
        Start-Process -FilePath 'cmd.exe' `
                      -ArgumentList @('/c', "`"$Script:NetDiagPath`"") `
                      -Verb RunAs -ErrorAction Stop | Out-Null
        Set-ToolsStatusMain "Network diagnostics running in a new window. Log will write to Desktop." '#2ea043'
        Add-LogLineMain "[Tools] Launched network-diag.bat"
    } catch {
        Set-ToolsStatusMain ("Failed to launch network diagnostics: {0}" -f $_.Exception.Message) '#f85149'
        Add-LogLineMain "[Tools] Error launching network diag: $($_.Exception.Message)"
    }
})

$Script:UI['btnOpenNetDiagLog'].Add_Click({
    # network-diag.bat writes to: %USERPROFILE%\Desktop\network-diag-%COMPUTERNAME%.txt
    $desktop = [Environment]::GetFolderPath('Desktop')
    $logPath = Join-Path $desktop "network-diag-$env:COMPUTERNAME.txt"
    if (Test-Path $logPath) {
        Start-Process notepad.exe -ArgumentList "`"$logPath`"" | Out-Null
        Set-ToolsStatusMain "Opened: $logPath" '#8b949e'
    } else {
        # Fall back to any network-diag-*.txt on the desktop (most recent first)
        $fallback = Get-ChildItem -Path $desktop -Filter 'network-diag-*.txt' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($fallback) {
            Start-Process notepad.exe -ArgumentList "`"$($fallback.FullName)`"" | Out-Null
            Set-ToolsStatusMain "Opened: $($fallback.Name)" '#8b949e'
        } else {
            Set-ToolsStatusMain "No network diagnostics log found on the Desktop yet." '#d29922'
        }
    }
})

# ============================================================================
#  RESUME CHECK ON LAUNCH
# ============================================================================
$existingSession = Get-SessionState
if ($existingSession -and $existingSession.ResumePhase) {
    $rp = $existingSession.ResumePhase
    $rm = if ($existingSession.RunMode) { $existingSession.RunMode } else { "Full" }
    Add-LogLineMain "Previous session detected. Mode: $rm, Resume from: $rp"

    if ($rm -eq "UpdatesOnly") {
        $Script:UI['btnStartFull'].IsEnabled = $false
        $Script:UI['btnStartFull'].Content = "Full Repair (session in progress)"
        $Script:UI['btnStartUpdatesOnly'].Content = "Resume Updates from: $rp"
        $Script:UI['btnStartUpdatesOnly'].Background = $Script:BrushConverter.ConvertFromString("#d29922")
    } else {
        $Script:UI['btnStartUpdatesOnly'].IsEnabled = $false
        $Script:UI['btnStartUpdatesOnly'].Content = "Updates Only (session in progress)"
        $Script:UI['btnStartFull'].Content = "Resume Full Repair from: $rp"
        $Script:UI['btnStartFull'].Background = $Script:BrushConverter.ConvertFromString("#d29922")
    }
    Remove-ItemProperty -Path $Script:RunKeyPath -Name $Script:RunKeyName -ErrorAction SilentlyContinue

    # Reveal the Start Over button so the tech can nuke the saved session and
    # start from Phase 1 instead of resuming mid-run.
    $Script:UI['btnStartOver'].Visibility = "Visible"
}

Write-Host "Showing window..." -ForegroundColor Green

# ============================================================================
#  SHOW WINDOW
# ============================================================================
$null = $Script:Window.ShowDialog()

# Cleanup
if ($Script:WorkerPowerShell) { try { $Script:WorkerPowerShell.Dispose() } catch {} }
if ($Script:WorkerRunspace)   { try { $Script:WorkerRunspace.Close(); $Script:WorkerRunspace.Dispose() } catch {} }
