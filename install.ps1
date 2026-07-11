#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'IndependentMonitorWorkspaces'),
    [string]$SourceUrl = 'https://raw.githubusercontent.com/Allaa-boutaleb/windows-per-monitor-workspaces/main/IndependentMonitorWorkspaces.ahk',
    [string]$SourceScriptPath,
    [string]$AutoHotkeyPath,
    [switch]$NoStartup,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptName = 'IndependentMonitorWorkspaces.ahk'
$installedScript = Join-Path $InstallRoot $scriptName
$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'Independent Monitor Workspaces.lnk'

function Find-AutoHotkeyV2 {
    $knownPaths = @(
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey32.exe'),
        (Join-Path $env:ProgramFiles 'AutoHotkey\UX\AutoHotkeyUX.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'AutoHotkey\v2\AutoHotkey32.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe')
    )
    return $knownPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Stop-RunningWorkspaceScript {
    param([string]$ScriptPath)

    $running = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$ScriptPath*" })
    if (-not $running) { return }

    if (-not ('PerMonitorWorkspaces.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace PerMonitorWorkspaces {
    public static class NativeMethods {
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
        public static void CloseProcessWindows(uint targetPid) {
            EnumWindows((hwnd, lParam) => {
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (pid == targetPid) PostMessage(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero);
                return true;
            }, IntPtr.Zero);
        }
    }
}
"@
    }

    foreach ($process in $running) {
        [PerMonitorWorkspaces.NativeMethods]::CloseProcessWindows([uint32]$process.ProcessId)
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        Start-Sleep -Milliseconds 100
        $stillRunning = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$ScriptPath*" })
    } while ($stillRunning -and [DateTime]::UtcNow -lt $deadline)

    if ($stillRunning) {
        throw 'The existing workspace process did not close cleanly. Exit it from its tray icon, then rerun the installer.'
    }
}

if (-not $AutoHotkeyPath) {
    $AutoHotkeyPath = Find-AutoHotkeyV2
}

if (-not $AutoHotkeyPath) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'AutoHotkey v2 is required and winget is unavailable. Install AutoHotkey v2 from https://www.autohotkey.com/ and rerun this command.'
    }

    Write-Host 'Installing AutoHotkey v2...' -ForegroundColor Cyan
    & $winget.Source install --id AutoHotkey.AutoHotkey --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget could not install AutoHotkey v2 (exit code $LASTEXITCODE)."
    }
    $AutoHotkeyPath = Find-AutoHotkeyV2
}

if (-not $AutoHotkeyPath -or -not (Test-Path -LiteralPath $AutoHotkeyPath)) {
    throw 'AutoHotkey v2 was not found after installation.'
}

$tempScript = Join-Path $env:TEMP ("IndependentMonitorWorkspaces-{0}.ahk" -f $PID)
try {
    if ($SourceScriptPath) {
        Copy-Item -LiteralPath $SourceScriptPath -Destination $tempScript -Force
    } else {
        Write-Host 'Downloading Independent Monitor Workspaces...' -ForegroundColor Cyan
        Invoke-WebRequest -UseBasicParsing -Uri $SourceUrl -OutFile $tempScript
    }

    $header = Get-Content -LiteralPath $tempScript -TotalCount 1
    if ($header -notmatch '^#Requires AutoHotkey v2') {
        throw 'The downloaded file is not a valid Independent Monitor Workspaces script.'
    }

    Stop-RunningWorkspaceScript -ScriptPath $installedScript
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Move-Item -LiteralPath $tempScript -Destination $installedScript -Force
} finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}

if (-not $NoStartup) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $AutoHotkeyPath
    $shortcut.Arguments = '"' + $installedScript + '"'
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.Description = 'Independent per-monitor workspaces for Windows 11'
    $shortcut.Save()
}

if (-not $NoLaunch) {
    Start-Process -FilePath $AutoHotkeyPath -ArgumentList ('"' + $installedScript + '"') -WindowStyle Hidden
}

Write-Host ''
Write-Host 'Independent Monitor Workspaces is installed.' -ForegroundColor Green
Write-Host 'Point at a monitor and press Win+Ctrl+Left or Win+Ctrl+Right.'
Write-Host 'Emergency reset: Win+Ctrl+Shift+Esc.'
Write-Host "Installed script: $installedScript"