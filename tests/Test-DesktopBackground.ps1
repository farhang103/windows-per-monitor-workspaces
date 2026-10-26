#Requires -Version 5.1
[CmdletBinding()]
param([string]$AutoHotkeyPath = "$env:LOCALAPPDATA\IndependentMonitorWorkspaces\runtime\AutoHotkey.exe")
$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'IndependentMonitorWorkspaces.ahk') -Raw
$globals = $source.Substring(0, $source.IndexOf('DetectHiddenWindows true'))
$functions = $source.Substring($source.IndexOf("`nInitializeMonitors() {"))
# Workspace frames built without a cached screen capture must look like the
# revealed desktop: real wallpaper and icons around the windows, no black
# resize borders, and no black snapshots of hidden windows. Uses one owned
# fixture window; never changes user windows, input, focus, or saved state.
$harness = $globals + @'

WorkspaceStatePersistenceEnabled := false
OverviewPreviewMode := true
DEBUG_LOG_PATH := A_ScriptDir "\background.log"
DEBUG_PREVIOUS_LOG_PATH := A_ScriptDir "\previous.log"
DetectHiddenWindows true
SetWinDelay -1
SetTimer((*) => ExitApp(2), -10000)
try {
    TestDesktopBackgroundFrames()
    FileAppend("Desktop background tests passed (capture, empty workspace, on-demand capture, resize border, hidden snapshots).`n", "*")
    ExitApp(0)
} catch as caughtError {
    FileAppend("FAIL: " caughtError.Message " at line " caughtError.Line "`n", "*")
    ExitApp(1)
}

TestDesktopBackgroundFrames() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript, WindowSnapshots
    monitor := MonitorGetPrimary()
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    width := right - left
    height := bottom - top
    CurrentWorkspace[monitor] := 1
    floating := Gui("+Resize -DPIScale", "IMW desktop background fixture")
    floating.BackColor := "2255CC"
    neverShown := Gui("-Caption +ToolWindow -DPIScale")
    try {
        AssertBackground(CaptureDesktopBackgrounds("test"), "desktop capture succeeds")
        background := FindDesktopBackground(monitor, left, top, width, height)
        AssertBackground(background, "capture matches the work area")
        AssertBackground(!FindDesktopBackground(monitor, left + 1, top, width, height),
            "a moved work area needs a new capture")

        ; An empty workspace slides in as the desktop itself, not a dark fill.
        frame := BuildWorkspaceFrameFromSnapshots(monitor, 3)
        AssertBackground(frame, "empty workspace frame")
        for point in [[1, 1], [width // 2, height // 2], [width - 2, height - 2],
            [width // 3, height - 40]]
            AssertBackground(FramePixel(frame, point[1], point[2])
                = FramePixel(background, point[1], point[2]),
                "empty workspace shows the desktop at " point[1] "," point[2])

        ; With no capture yet, the first uncached frame captures on demand.
        ClearWorkspaceFrames()
        ClearDesktopBackgrounds()
        frame := BuildWorkspaceFrameFromSnapshots(monitor, 3)
        background := FindDesktopBackground(monitor, left, top, width, height)
        AssertBackground(background, "frame build captures the desktop on demand")
        AssertBackground(FramePixel(frame, width // 2, height // 2)
            = FramePixel(background, width // 2, height // 2),
            "on-demand capture is drawn into the frame")

        AssertBackground(!CaptureWindowSnapshot(neverShown.Hwnd)
            && !WindowSnapshots.Has(neverShown.Hwnd), "a hidden window is never snapshotted")

        floating.Show("NA x" (left + 200) " y" (top + 160) " w480 h300")
        DllCall("UpdateWindow", "ptr", floating.Hwnd)
        DllCall("dwmapi\DwmFlush")
        AssertBackground(CaptureWindowSnapshot(floating.Hwnd), "visible window snapshot")
        floating.Hide()
        AssertBackground(!CaptureWindowSnapshot(floating.Hwnd), "no snapshot once hidden")
        snapshot := WindowSnapshots[floating.Hwnd]
        AssertBackground(SimilarColor(FramePixel(snapshot, snapshot.width // 2, snapshot.height // 2),
            0xCC5522), "hiding keeps the visible snapshot instead of a black one")

        WindowWorkspace[floating.Hwnd] := {monitor: monitor, workspace: 2}
        HiddenByScript[floating.Hwnd] := true
        frame := BuildWorkspaceFrameFromSnapshots(monitor, 2)
        windowRect := Buffer(16, 0)
        frameRect := Buffer(16, 0)
        DllCall("GetWindowRect", "ptr", floating.Hwnd, "ptr", windowRect.Ptr)
        AssertBackground(DllCall("dwmapi\DwmGetWindowAttribute", "ptr", floating.Hwnd,
            "uint", 9, "ptr", frameRect.Ptr, "uint", 16, "int") = 0, "visible frame bounds")
        windowLeft := NumGet(windowRect, 0, "int") - left
        frameLeft := NumGet(frameRect, 0, "int") - left
        middle := (NumGet(frameRect, 4, "int") + NumGet(frameRect, 12, "int")) // 2 - top
        AssertBackground(frameLeft - windowLeft >= 2, "fixture has an invisible resize border")
        borderX := windowLeft + (frameLeft - windowLeft) // 2
        AssertBackground(FramePixel(frame, borderX, middle) = FramePixel(background, borderX, middle),
            "the invisible resize border shows the desktop instead of black")
        clientX := (frameLeft + NumGet(frameRect, 8, "int") - left) // 2
        AssertBackground(SimilarColor(FramePixel(frame, clientX, middle), 0xCC5522),
            "the window itself is drawn")
    } finally {
        floating.Destroy()
        neverShown.Destroy()
        ClearWindowSnapshots()
        ClearWorkspaceFrames()
        ClearDesktopBackgrounds()
    }
}
FramePixel(frame, x, y) {
    dc := DllCall("CreateCompatibleDC", "ptr", 0, "ptr")
    old := DllCall("SelectObject", "ptr", dc, "ptr", frame.bitmap, "ptr")
    pixel := DllCall("GetPixel", "ptr", dc, "int", x, "int", y, "uint")
    DllCall("SelectObject", "ptr", dc, "ptr", old)
    DllCall("DeleteDC", "ptr", dc)
    return pixel
}
SimilarColor(actual, expected) {
    Loop 3 {
        shift := (A_Index - 1) * 8
        if Abs(((actual >> shift) & 0xFF) - ((expected >> shift) & 0xFF)) > 8
            return false
    }
    return true
}
AssertBackground(condition, message) {
    if !condition
        throw Error(message)
}
'@ + $functions
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW-background-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testScript = Join-Path $testRoot 'background-tests.ahk'
    [IO.File]::WriteAllText($testScript, $harness, [Text.UTF8Encoding]::new($true))
    $process = Start-Process -FilePath $AutoHotkeyPath -WindowStyle Hidden -PassThru `
        -ArgumentList @('/ErrorStdOut', ('"' + $testScript + '"')) `
        -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') `
        -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
    # Windows PowerShell 5.1 reports no exit code unless the handle is opened
    # while the process is still running.
    $null = $process.Handle
    if (-not $process.WaitForExit(15000)) {
        $process.Kill()
        throw 'Desktop background tests timed out.'
    }
    Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt'), (Join-Path $testRoot 'stderr.txt')
    if ($process.ExitCode -ne 0) {
        Get-Content -LiteralPath (Join-Path $testRoot 'background.log') -Tail 12 -ErrorAction SilentlyContinue
        throw "Desktop background tests failed: $($process.ExitCode)"
    }
} finally {
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
