#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'IndependentMonitorWorkspaces'),
    [string]$SourceUrl = 'https://raw.githubusercontent.com/Allaa-boutaleb/windows-per-monitor-workspaces/main/IndependentMonitorWorkspaces.ahk',
    [string]$SourceScriptPath,
    [string]$SourceScriptSha256,
    [string]$AutoHotkeyPath,
    [string]$RuntimeArchiveUrl = 'https://github.com/AutoHotkey/AutoHotkey/releases/download/v2.0.26/AutoHotkey_2.0.26.zip',
    [string]$RuntimeArchivePath,
    [string]$RuntimeArchiveSha256 = '43522AA3122A57784AC5DB30ABF85C2244475C36ACD7796E2C993355F9E926AE',
    [string]$StartupDirectory = ([Environment]::GetFolderPath('Startup')),
    [ValidateRange(1, 10)]
    [int]$DownloadRetryCount = 3,
    [switch]$ForceStartupFallback,
    [switch]$NoStartup,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptName = 'IndependentMonitorWorkspaces.ahk'
$shortcutName = 'Independent Monitor Workspaces.lnk'
$fallbackName = 'Independent Monitor Workspaces.cmd'
$parentDirectory = Split-Path -Parent $InstallRoot
if (-not $parentDirectory) {
    throw 'InstallRoot must include a parent directory.'
}

$transactionId = '{0}-{1}' -f $PID, ([Guid]::NewGuid().ToString('N'))
$stagingRoot = Join-Path $parentDirectory ('.imw-staging-' + $transactionId)
$backupRoot = Join-Path $parentDirectory ('.imw-backup-' + $transactionId)
$startupBackupRoot = Join-Path $parentDirectory ('.imw-startup-' + $transactionId)
$stagedScript = Join-Path $stagingRoot $scriptName
$installedScript = Join-Path $InstallRoot $scriptName
$shortcutPath = Join-Path $StartupDirectory $shortcutName
$fallbackStartupPath = Join-Path $StartupDirectory $fallbackName
$runtimeWasBundled = -not [bool]$AutoHotkeyPath
$installedRuntime = Join-Path $InstallRoot 'runtime\AutoHotkey.exe'
$runtimeForValidation = $null
$runtimeForInstall = $null
$oldInstallMoved = $false
$newInstallMoved = $false
$startupBackedUp = $false
$oldWasRunning = $false
$oldRuntimePath = $null
$launchedProcess = $null

function Write-Step {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $DownloadRetryCount; $attempt++) {
        try {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
            if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
                throw 'The downloaded file was empty.'
            }
            return
        } catch {
            $lastError = $_
            if ($attempt -lt $DownloadRetryCount) {
                Start-Sleep -Seconds $attempt
            }
        }
    }
    throw "Download failed after $DownloadRetryCount attempts: $($lastError.Exception.Message)"
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "$Description SHA-256 must contain exactly 64 hexadecimal characters."
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if (-not $actual.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description failed SHA-256 verification. Expected $ExpectedSha256 but received $actual."
    }
}

function Assert-AutoHotkeyV2 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "AutoHotkey executable was not found: $Path"
    }
    $version = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
    if (-not $version -or $version -notmatch '^2\.') {
        throw "AutoHotkey v2 is required. '$Path' reports version '$version'."
    }
}

function Test-WorkspaceScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$RuntimePath
    )

    $header = Get-Content -LiteralPath $ScriptPath -TotalCount 1
    if ($header -notmatch '^#Requires\s+AutoHotkey\s+v2') {
        throw 'The workspace script is invalid: its first line must require AutoHotkey v2.'
    }
    if ($SourceScriptSha256) {
        Assert-FileHash -Path $ScriptPath -ExpectedSha256 $SourceScriptSha256 -Description 'Workspace script'
    }

    $libraryOutput = Join-Path $stagingRoot 'syntax-libraries.txt'
    $standardOutput = Join-Path $stagingRoot 'syntax-output.txt'
    $standardError = Join-Path $stagingRoot 'syntax-error.txt'
    $arguments = @(
        '/ErrorStdOut',
        '/iLib',
        ('"' + $libraryOutput + '"'),
        ('"' + $ScriptPath + '"')
    )
    $syntaxProcess = Start-Process -FilePath $RuntimePath -ArgumentList $arguments -Wait -PassThru `
        -RedirectStandardOutput $standardOutput -RedirectStandardError $standardError
    if ($syntaxProcess.ExitCode -ne 0) {
        $syntaxOutput = @(
            Get-Content -LiteralPath $standardOutput -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $standardError -ErrorAction SilentlyContinue
        )
        $details = ($syntaxOutput | Out-String).Trim()
        if (-not $details) { $details = "AutoHotkey exited with code $($syntaxProcess.ExitCode)." }
        throw "The workspace script failed AutoHotkey syntax validation: $details"
    }
    Remove-Item -LiteralPath $libraryOutput, $standardOutput, $standardError -Force -ErrorAction SilentlyContinue
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

function Initialize-NativeClose {
    if ('IndependentMonitorWorkspaces.InstallerNativeMethods' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace IndependentMonitorWorkspaces {
    public static class InstallerNativeMethods {
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

function Stop-WorkspaceScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [int]$TimeoutSeconds = 5
    )

    $running = @(Get-WorkspaceProcesses -ScriptPath $ScriptPath)
    if (-not $running) { return }
    Initialize-NativeClose
    foreach ($process in $running) {
        [IndependentMonitorWorkspaces.InstallerNativeMethods]::CloseProcessWindows([uint32]$process.ProcessId)
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 100
        $stillRunning = @(Get-WorkspaceProcesses -ScriptPath $ScriptPath)
    } while ($stillRunning -and [DateTime]::UtcNow -lt $deadline)

    if ($stillRunning) {
        throw 'The existing workspace process did not close cleanly. Press Win+Ctrl+Shift+Esc, exit it from the tray icon, and rerun the installer.'
    }
}

function Backup-StartupEntries {
    New-Item -ItemType Directory -Path $startupBackupRoot -Force | Out-Null
    foreach ($path in @($shortcutPath, $fallbackStartupPath)) {
        if (Test-Path -LiteralPath $path) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $startupBackupRoot ([IO.Path]::GetFileName($path))) -Force
        }
    }
}

function Remove-StartupEntries {
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fallbackStartupPath -Force -ErrorAction SilentlyContinue
}

function Restore-StartupEntries {
    Remove-StartupEntries
    if (-not (Test-Path -LiteralPath $startupBackupRoot)) { return }
    foreach ($item in Get-ChildItem -LiteralPath $startupBackupRoot -File) {
        New-Item -ItemType Directory -Path $StartupDirectory -Force | Out-Null
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $StartupDirectory $item.Name) -Force
    }
}

function Initialize-NativeShortcut {
    if ('IndependentMonitorWorkspaces.ShellShortcut' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
namespace IndependentMonitorWorkspaces {
    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    internal class ShellLinkObject { }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    internal interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int maxPath, IntPtr findData, uint flags);
        void GetIDList(out IntPtr itemIdList);
        void SetIDList(IntPtr itemIdList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int maxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int maxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int maxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCommand);
        void SetShowCmd(int showCommand);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int maxPath, out int iconIndex);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    public static class ShellShortcut {
        public static void Create(string shortcutPath, string targetPath, string arguments, string workingDirectory, string description) {
            object linkObject = new ShellLinkObject();
            try {
                IShellLinkW link = (IShellLinkW)linkObject;
                link.SetPath(targetPath);
                link.SetArguments(arguments);
                link.SetWorkingDirectory(workingDirectory);
                link.SetDescription(description);
                link.SetShowCmd(1);
                ((IPersistFile)linkObject).Save(shortcutPath, true);
            } finally {
                Marshal.FinalReleaseComObject(linkObject);
            }
        }
    }
}
"@
}

function Install-StartupEntry {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimePath,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    Remove-StartupEntries
    if ($NoStartup) { return }
    New-Item -ItemType Directory -Path $StartupDirectory -Force | Out-Null

    if (-not $ForceStartupFallback) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $RuntimePath
            $shortcut.Arguments = '"' + $ScriptPath + '"'
            $shortcut.WorkingDirectory = $InstallRoot
            $shortcut.Description = 'Independent per-monitor workspaces for Windows 11'
            $shortcut.Save()
            if (Test-Path -LiteralPath $shortcutPath) { return }
        } catch {
            Write-Warning "WScript could not create the Startup shortcut; using the native Windows Shell API. $($_.Exception.Message)"
        }
    }

    Initialize-NativeShortcut
    [IndependentMonitorWorkspaces.ShellShortcut]::Create(
        $shortcutPath,
        $RuntimePath,
        ('"' + $ScriptPath + '"'),
        $InstallRoot,
        'Independent per-monitor workspaces for Windows 11'
    )
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        throw 'Windows did not create the Startup shortcut.'
    }
}
function Get-ConfiguredRuntime {
    param([string]$Root)

    $metadataPath = Join-Path $Root 'install.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) { return $null }
    try {
        return (Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json).AutoHotkeyPath
    } catch {
        return $null
    }
}

function Start-WorkspaceScript {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimePath,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    $process = Start-Process -FilePath $RuntimePath -ArgumentList ('"' + $ScriptPath + '"') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800
    $process.Refresh()
    if ($process.HasExited) {
        throw "The workspace process exited during startup with code $($process.ExitCode)."
    }
    return $process
}

try {
    Write-Step 'Preparing Independent Monitor Workspaces...'
    New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    if ($SourceScriptPath) {
        Copy-Item -LiteralPath $SourceScriptPath -Destination $stagedScript -Force
    } else {
        Write-Step 'Downloading the workspace script...'
        Invoke-Download -Uri $SourceUrl -Destination $stagedScript
    }

    if ($runtimeWasBundled) {
        $archivePath = Join-Path $stagingRoot 'AutoHotkey.zip'
        if ($RuntimeArchivePath) {
            Copy-Item -LiteralPath $RuntimeArchivePath -Destination $archivePath -Force
        } else {
            Write-Step 'Downloading the portable AutoHotkey v2 runtime...'
            Invoke-Download -Uri $RuntimeArchiveUrl -Destination $archivePath
        }
        Assert-FileHash -Path $archivePath -ExpectedSha256 $RuntimeArchiveSha256 -Description 'AutoHotkey runtime archive'

        $expandedRuntime = Join-Path $stagingRoot 'runtime-expanded'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedRuntime -Force
        $runtimeFileName = if ([Environment]::Is64BitOperatingSystem) { 'AutoHotkey64.exe' } else { 'AutoHotkey32.exe' }
        $runtimeSource = Join-Path $expandedRuntime $runtimeFileName
        Assert-AutoHotkeyV2 -Path $runtimeSource

        $stagedRuntimeDirectory = Join-Path $stagingRoot 'runtime'
        New-Item -ItemType Directory -Path $stagedRuntimeDirectory -Force | Out-Null
        $runtimeForValidation = Join-Path $stagedRuntimeDirectory 'AutoHotkey.exe'
        Copy-Item -LiteralPath $runtimeSource -Destination $runtimeForValidation -Force
        Remove-Item -LiteralPath $archivePath -Force
        Remove-Item -LiteralPath $expandedRuntime -Recurse -Force
        $runtimeForInstall = $installedRuntime
    } else {
        $AutoHotkeyPath = [IO.Path]::GetFullPath($AutoHotkeyPath)
        Assert-AutoHotkeyV2 -Path $AutoHotkeyPath
        $runtimeForValidation = $AutoHotkeyPath
        $runtimeForInstall = $AutoHotkeyPath
    }

    Test-WorkspaceScript -ScriptPath $stagedScript -RuntimePath $runtimeForValidation

    $metadata = [ordered]@{
        Product = 'Independent Monitor Workspaces'
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
        AutoHotkeyPath = $runtimeForInstall
        BundledRuntime = $runtimeWasBundled
        RuntimeVersion = (Get-Item -LiteralPath $runtimeForValidation).VersionInfo.ProductVersion
    }
    [IO.File]::WriteAllText(
        (Join-Path $stagingRoot 'install.json'),
        ($metadata | ConvertTo-Json),
        (New-Object Text.UTF8Encoding($true))
    )

    $existingProcesses = @(Get-WorkspaceProcesses -ScriptPath $installedScript)
    $oldWasRunning = $existingProcesses.Count -gt 0
    if ($oldWasRunning) {
        $oldRuntimePath = $existingProcesses[0].ExecutablePath
    }
    if (-not $oldRuntimePath -and (Test-Path -LiteralPath $InstallRoot)) {
        $oldRuntimePath = Get-ConfiguredRuntime -Root $InstallRoot
    }

    Backup-StartupEntries
    $startupBackedUp = $true
    if (Test-Path -LiteralPath $installedScript) {
        Stop-WorkspaceScript -ScriptPath $installedScript
    }

    if (Test-Path -LiteralPath $InstallRoot) {
        Move-Item -LiteralPath $InstallRoot -Destination $backupRoot
        $oldInstallMoved = $true
    }
    Move-Item -LiteralPath $stagingRoot -Destination $InstallRoot
    $newInstallMoved = $true

    Install-StartupEntry -RuntimePath $runtimeForInstall -ScriptPath $installedScript

    if (-not $NoLaunch) {
        $launchedProcess = Start-WorkspaceScript -RuntimePath $runtimeForInstall -ScriptPath $installedScript
    }

    if ($oldInstallMoved) {
        $oldInstallMoved = $false
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $startupBackedUp = $false
    Write-Host ''
    Write-Host 'Independent Monitor Workspaces is installed.' -ForegroundColor Green
    Write-Host 'Point at a monitor and press Win+Ctrl+Left or Win+Ctrl+Right.'
    Write-Host 'Emergency reset: Win+Ctrl+Shift+Esc.'
    Write-Host "Installed script: $installedScript"
    if ($runtimeWasBundled) {
        Write-Host 'Runtime: isolated portable AutoHotkey v2 (no winget or system install required).'
    }
} catch {
    $originalError = $_
    Write-Warning 'Installation failed. Restoring the previous installation...'

    if ($launchedProcess -and -not $launchedProcess.HasExited) {
        try { Stop-WorkspaceScript -ScriptPath $installedScript } catch { Stop-Process -Id $launchedProcess.Id -Force -ErrorAction SilentlyContinue }
    }
    if ($newInstallMoved -and (Test-Path -LiteralPath $InstallRoot)) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($oldInstallMoved -and (Test-Path -LiteralPath $backupRoot)) {
        try {
            Move-Item -LiteralPath $backupRoot -Destination $InstallRoot
            $oldInstallMoved = $false
        } catch {
            Write-Warning "The previous installation is safe at '$backupRoot' but could not be moved back automatically."
        }
    }
    if ($startupBackedUp) {
        try {
            Restore-StartupEntries
            $startupBackedUp = $false
        } catch {
            Write-Warning "The previous Startup entry is safe at '$startupBackupRoot' but could not be restored automatically."
        }
    }

    if ($oldWasRunning -and $oldRuntimePath -and (Test-Path -LiteralPath $oldRuntimePath) -and (Test-Path -LiteralPath $installedScript)) {
        try {
            Start-Process -FilePath $oldRuntimePath -ArgumentList ('"' + $installedScript + '"') -WindowStyle Hidden | Out-Null
        } catch {
            Write-Warning 'The previous files were restored, but the previous process could not be restarted.'
        }
    }
    throw $originalError
} finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $oldInstallMoved) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $startupBackedUp) {
        Remove-Item -LiteralPath $startupBackupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
