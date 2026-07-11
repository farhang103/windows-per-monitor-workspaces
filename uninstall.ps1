#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'IndependentMonitorWorkspaces'),
    [switch]$NoStartup
)

$ErrorActionPreference = 'Stop'
$installedScript = Join-Path $InstallRoot 'IndependentMonitorWorkspaces.ahk'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Independent Monitor Workspaces.lnk'

$running = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$installedScript*" })

if ($running) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PerMonitorWorkspaceUninstaller {
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    public static void Close(uint targetPid) {
        EnumWindows((hwnd, lParam) => { uint pid; GetWindowThreadProcessId(hwnd, out pid); if (pid == targetPid) PostMessage(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero); return true; }, IntPtr.Zero);
    }
}
"@
    foreach ($process in $running) {
        [PerMonitorWorkspaceUninstaller]::Close([uint32]$process.ProcessId)
    }
    Start-Sleep -Milliseconds 800
}

if (-not $NoStartup) {
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'Independent Monitor Workspaces was removed.' -ForegroundColor Green
Write-Host 'AutoHotkey was left installed to avoid affecting other scripts.'