#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'IndependentMonitorWorkspaces'),
    [string]$StartupDirectory = ([Environment]::GetFolderPath('Startup')),
    [switch]$NoStartup
)

$ErrorActionPreference = 'Stop'
$installedScript = Join-Path $InstallRoot 'IndependentMonitorWorkspaces.ahk'
$shortcutPath = Join-Path $StartupDirectory 'Independent Monitor Workspaces.lnk'
$fallbackStartupPath = Join-Path $StartupDirectory 'Independent Monitor Workspaces.cmd'
$bundledRuntime = Test-Path -LiteralPath (Join-Path $InstallRoot 'runtime\AutoHotkey.exe')
$metadataPath = Join-Path $InstallRoot 'install.json'
if (Test-Path -LiteralPath $metadataPath) {
    try {
        $bundledRuntime = [bool](Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json).BundledRuntime
    } catch {
        Write-Warning 'Install metadata could not be read; removal will continue.'
    }
}

function Get-WorkspaceProcesses {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $comparisonPath = [IO.Path]::GetFullPath($ScriptPath)
    return @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine.IndexOf($comparisonPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
}

function Stop-WorkspaceScript {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $running = @(Get-WorkspaceProcesses -ScriptPath $ScriptPath)
    if (-not $running) { return }

    if (-not ('IndependentMonitorWorkspaces.UninstallerNativeMethods' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace IndependentMonitorWorkspaces {
    public static class UninstallerNativeMethods {
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
        [IndependentMonitorWorkspaces.UninstallerNativeMethods]::CloseProcessWindows([uint32]$process.ProcessId)
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $stillRunning = @(Get-WorkspaceProcesses -ScriptPath $ScriptPath)
    } while ($stillRunning -and [DateTime]::UtcNow -lt $deadline)

    if ($stillRunning) {
        throw 'The workspace process did not close cleanly, so no files were removed. Press Win+Ctrl+Shift+Esc, exit it from the tray icon, and rerun the uninstaller.'
    }
}

if (Test-Path -LiteralPath $installedScript) {
    Stop-WorkspaceScript -ScriptPath $installedScript
}

if (-not $NoStartup) {
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fallbackStartupPath -Force -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $InstallRoot) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
}

Write-Host 'Independent Monitor Workspaces was removed.' -ForegroundColor Green
if ($bundledRuntime) {
    Write-Host 'Its isolated portable AutoHotkey runtime was removed too.'
} else {
    Write-Host 'The user-managed AutoHotkey runtime was left unchanged.'
}
