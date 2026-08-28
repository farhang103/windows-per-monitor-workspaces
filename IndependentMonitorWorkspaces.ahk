#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; Independent per-monitor workspaces for Windows 11.
; This intentionally stays on one native Windows virtual desktop and emulates
; independent desktops by showing/hiding only the windows on the selected monitor.

APP_VERSION := "1.0.0"
WORKSPACE_COUNT := 2
SHOW_FEEDBACK := true
ANIMATION_MS := 180

global CurrentWorkspace := Map()
global WindowWorkspace := Map()
global HiddenByScript := Map()
global WorkspaceOverlays := Map()
global Switching := false

DetectHiddenWindows true
SetTitleMatchMode 2
SetWinDelay -1

InitializeMonitors()
OnExit(RestoreAllWindows)
OnMessage(0x007E, HandleDisplayChange) ; WM_DISPLAYCHANGE

Loop 9 {
    workspace := A_Index
    Hotkey("#^" workspace, SwitchToWorkspace.Bind(workspace))
    Hotkey("#^+" workspace, MoveActiveWindowToWorkspace.Bind(workspace))
}

Hotkey("#^Left", PreviousWorkspace)
Hotkey("#^Right", NextWorkspace)
Hotkey("^!Left", PreviousWorkspace)
Hotkey("^!Right", NextWorkspace)
Hotkey("#^+Esc", ResetAndRevealAll)

A_TrayMenu.Delete()
A_TrayMenu.Add("Show shortcuts", ShowHelp)
A_TrayMenu.Add("Reveal all windows and reset", ResetAndRevealAll)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit (reveals hidden windows)", (*) => ExitApp())
A_TrayMenu.Default := "Show shortcuts"
A_IconTip := "Independent Monitor Workspaces"

ShowFeedbackForMonitor(GetMonitorUnderMouse(), 1, "Ready")

InitializeMonitors() {
    global CurrentWorkspace
    Loop MonitorGetCount()
        CurrentWorkspace[A_Index] := 1
}

SwitchToWorkspace(workspace, direction := 0, *) {
    global WORKSPACE_COUNT, CurrentWorkspace, WindowWorkspace
    global HiddenByScript, Switching

    if Type(direction) != "Integer"
        direction := 0

    if workspace < 1 || workspace > WORKSPACE_COUNT
        return
    if Switching
        return

    Switching := true
    try {
        EnsureMonitorState()
        monitor := GetMonitorUnderMouse()
        oldWorkspace := CurrentWorkspace[monitor]

        ; Discover newly opened windows before changing what is visible.
        LearnVisibleWindows()

        if workspace = oldWorkspace {
            ShowWorkspaceOverlay(monitor, workspace, 0)
            return
        }

        if direction = 0
            direction := workspace > oldWorkspace ? 1 : -1

        ; Hide windows belonging to other workspaces on only this monitor.
        for hwnd, slot in WindowWorkspace.Clone() {
            if !WinExist("ahk_id " hwnd) {
                ForgetWindow(hwnd)
                continue
            }
            if slot.monitor != monitor
                continue

            if slot.workspace = workspace {
                if HiddenByScript.Has(hwnd) {
                    ShowWindowFast(hwnd)
                    HiddenByScript.Delete(hwnd)
                }
            } else if IsVisible(hwnd) && IsManageableWindow(hwnd) {
                HideWindowFast(hwnd)
                HiddenByScript[hwnd] := true
            }
        }

        CurrentWorkspace[monitor] := workspace
        ShowWorkspaceOverlay(monitor, workspace, direction)
    } finally {
        Switching := false
    }
}

PreviousWorkspace(*) {
    global WORKSPACE_COUNT, CurrentWorkspace
    EnsureMonitorState()
    monitor := GetMonitorUnderMouse()
    next := CurrentWorkspace[monitor] - 1
    if next < 1
        next := WORKSPACE_COUNT
    SwitchToWorkspace(next, -1)
}

NextWorkspace(*) {
    global WORKSPACE_COUNT, CurrentWorkspace
    EnsureMonitorState()
    monitor := GetMonitorUnderMouse()
    next := CurrentWorkspace[monitor] + 1
    if next > WORKSPACE_COUNT
        next := 1
    SwitchToWorkspace(next, 1)
}

MoveActiveWindowToWorkspace(workspace, *) {
    global WORKSPACE_COUNT, CurrentWorkspace, WindowWorkspace, HiddenByScript

    if workspace < 1 || workspace > WORKSPACE_COUNT
        return

    hwnd := WinExist("A")
    if !hwnd || !IsManageableWindow(hwnd)
        return

    EnsureMonitorState()
    monitor := GetWindowMonitor(hwnd)
    WindowWorkspace[hwnd] := {monitor: monitor, workspace: workspace}

    if workspace != CurrentWorkspace[monitor] {
        HideWindowFast(hwnd)
        HiddenByScript[hwnd] := true
    }

    ShowFeedbackForMonitor(monitor, workspace, "Window moved to")
}

LearnVisibleWindows() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript

    for hwnd in WinGetList() {
        if HiddenByScript.Has(hwnd)
            continue
        if !IsManageableWindow(hwnd) || !IsVisible(hwnd)
            continue

        monitor := GetWindowMonitor(hwnd)
        if !WindowWorkspace.Has(hwnd) {
            WindowWorkspace[hwnd] := {
                monitor: monitor,
                workspace: CurrentWorkspace[monitor]
            }
            continue
        }

        ; A visible window dragged to another monitor joins the workspace that is
        ; currently displayed there.
        slot := WindowWorkspace[hwnd]
        if slot.monitor != monitor {
            WindowWorkspace[hwnd] := {
                monitor: monitor,
                workspace: CurrentWorkspace[monitor]
            }
        }
    }
}

IsManageableWindow(hwnd) {
    global HiddenByScript

    if hwnd = A_ScriptHwnd
        return false

    try style := WinGetStyle("ahk_id " hwnd)
    catch
        return false

    if style & 0x40000000 ; WS_CHILD
        return false

    try class := WinGetClass("ahk_id " hwnd)
    catch
        return false

    static ignoredClasses := Map(
        "Shell_TrayWnd", true,
        "Shell_SecondaryTrayWnd", true,
        "Progman", true,
        "WorkerW", true,
        "DV2ControlHost", true,
        "MsgrIMEWindowClass", true,
        "SysShadow", true,
        "Windows.UI.Core.CoreWindow", true,
        "AutoHotkeyGUI", true
    )
    if ignoredClasses.Has(class)
        return false

    ; Do not adopt windows hidden by their own application. Windows already
    ; managed by this script are the exception.
    if !HiddenByScript.Has(hwnd) && !(style & 0x10000000) ; WS_VISIBLE
        return false

    try {
        cloaked := 0
        if DllCall("dwmapi\\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14,
            "int*", &cloaked, "uint", 4) = 0 && cloaked
            return false
    }

    return true
}

IsVisible(hwnd) {
    try return DllCall("IsWindowVisible", "ptr", hwnd, "int") != 0
    catch
        return false
}

HideWindowFast(hwnd) {
    ; SW_HIDE = 0. Post to the owning UI thread without waiting for each app.
    try DllCall("ShowWindowAsync", "ptr", hwnd, "int", 0)
}

ShowWindowFast(hwnd) {
    ; SW_SHOWNA = 8: show without activation or restoring minimized windows.
    try DllCall("ShowWindowAsync", "ptr", hwnd, "int", 8)
}

GetMonitorUnderMouse() {
    point := Buffer(8, 0)
    if !DllCall("GetCursorPos", "ptr", point.Ptr)
        return MonitorGetPrimary()

    ; Pass the native POINT by value, preserving physical coordinates on mixed-DPI displays.
    hMonitor := DllCall("MonitorFromPoint", "int64", NumGet(point, 0, "int64"),
        "uint", 2, "ptr")
    return GetMonitorIndexFromHandle(hMonitor)
}

GetWindowMonitor(hwnd) {
    hMonitor := DllCall("MonitorFromWindow", "ptr", hwnd, "uint", 2, "ptr")
    return GetMonitorIndexFromHandle(hMonitor)
}

GetMonitorIndexFromHandle(hMonitor) {
    if !hMonitor
        return MonitorGetPrimary()

    ; MONITORINFOEXW provides the stable \\.\DISPLAYn device name.
    info := Buffer(104, 0)
    NumPut("uint", 104, info, 0)
    if !DllCall("GetMonitorInfoW", "ptr", hMonitor, "ptr", info.Ptr)
        return MonitorGetPrimary()

    deviceName := StrGet(info.Ptr + 40, 32, "UTF-16")
    Loop MonitorGetCount() {
        if StrLower(MonitorGetName(A_Index)) = StrLower(deviceName)
            return A_Index
    }
    return MonitorGetPrimary()
}

EnsureMonitorState() {
    global CurrentWorkspace
    Loop MonitorGetCount() {
        if !CurrentWorkspace.Has(A_Index)
            CurrentWorkspace[A_Index] := 1
    }
}

ForgetWindow(hwnd) {
    global WindowWorkspace, HiddenByScript
    if WindowWorkspace.Has(hwnd)
        WindowWorkspace.Delete(hwnd)
    if HiddenByScript.Has(hwnd)
        HiddenByScript.Delete(hwnd)
}

HandleDisplayChange(*) {
    ; Windows broadcasts WM_DISPLAYCHANGE after monitor connect/disconnect,
    ; resolution changes, docking, and topology changes. Debounce the reset.
    SetTimer(ResetAfterDisplayChange, -750)
}

ResetAfterDisplayChange() {
    global Switching
    if Switching {
        SetTimer(ResetAfterDisplayChange, -300)
        return
    }
    ResetAndRevealAll()
}

RestoreAllWindows(*) {
    global HiddenByScript
    for hwnd in HiddenByScript.Clone() {
        if WinExist("ahk_id " hwnd)
            ShowWindowFast(hwnd)
    }
    HiddenByScript.Clear()
}

ResetAndRevealAll(*) {
    global CurrentWorkspace, WindowWorkspace
    RestoreAllWindows()
    WindowWorkspace.Clear()
    CurrentWorkspace.Clear()
    InitializeMonitors()
    ShowFeedbackForMonitor(GetMonitorUnderMouse(), 1, "Reset to")
}

ShowWorkspaceOverlay(monitor, workspace, direction := 0, prefix := "WORKSPACE") {
    global SHOW_FEEDBACK, WORKSPACE_COUNT, ANIMATION_MS, WorkspaceOverlays
    if !SHOW_FEEDBACK
        return

    CancelWorkspaceOverlay(monitor)
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)

    width := 280
    height := 88
    targetX := left + ((right - left - width) // 2)
    targetY := top + 42
    startX := targetX + (direction * 90)
    label := direction > 0 ? prefix " " workspace "  ›"
        : direction < 0 ? "‹  " prefix " " workspace
        : prefix " " workspace

    overlay := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
    overlay.BackColor := "111827"
    overlay.MarginX := 0
    overlay.MarginY := 0
    overlay.SetFont("s9 c9CA3AF w600", "Segoe UI")
    overlay.AddText("x20 y12 w240 h18 Center BackgroundTrans", "MONITOR " monitor)
    overlay.SetFont("s18 cFFFFFF w600", "Segoe UI Variable Display")
    overlay.AddText("x15 y32 w250 h30 Center BackgroundTrans", label)

    dots := ""
    Loop WORKSPACE_COUNT
        dots .= (A_Index = workspace ? "●" : "○") "  "
    overlay.SetFont("s9 c60A5FA w600", "Segoe UI Symbol")
    overlay.AddText("x20 y65 w240 h16 Center BackgroundTrans", RTrim(dots))

    overlay.Show("NA x" startX " y" targetY " w" width " h" height)
    hwnd := overlay.Hwnd
    try WinSetRegion("0-0 W" width " H" height " R18-18", "ahk_id " hwnd)
    try WinSetTransparent(0, "ahk_id " hwnd)

    state := {
        gui: overlay, hwnd: hwnd, monitor: monitor,
        startX: startX, targetX: targetX, y: targetY,
        started: A_TickCount, duration: ANIMATION_MS
    }
    state.moveTimer := AnimateWorkspaceOverlay.Bind(state)
    WorkspaceOverlays[monitor] := state
    SetTimer(state.moveTimer, 16)
}

AnimateWorkspaceOverlay(state) {
    global WorkspaceOverlays
    if !WorkspaceOverlays.Has(state.monitor)
        return
    if WorkspaceOverlays[state.monitor].hwnd != state.hwnd
        return

    t := Min(1, (A_TickCount - state.started) / state.duration)
    ease := 1 - ((1 - t) ** 3)
    x := state.startX + ((state.targetX - state.startX) * ease)
    alpha := Round(238 * Min(1, t / 0.45))
    try WinMove(Round(x), state.y,,, "ahk_id " state.hwnd)
    try WinSetTransparent(alpha, "ahk_id " state.hwnd)

    if t >= 1 {
        SetTimer(state.moveTimer, 0)
        SetTimer(BeginWorkspaceOverlayFade.Bind(state), -650)
    }
}

BeginWorkspaceOverlayFade(state) {
    global WorkspaceOverlays
    if !WorkspaceOverlays.Has(state.monitor)
        return
    if WorkspaceOverlays[state.monitor].hwnd != state.hwnd
        return

    state.fadeStarted := A_TickCount
    state.fadeTimer := FadeWorkspaceOverlay.Bind(state)
    SetTimer(state.fadeTimer, 16)
}

FadeWorkspaceOverlay(state) {
    global WorkspaceOverlays
    if !WorkspaceOverlays.Has(state.monitor)
        return
    if WorkspaceOverlays[state.monitor].hwnd != state.hwnd
        return

    t := Min(1, (A_TickCount - state.fadeStarted) / 150)
    try WinSetTransparent(Round(238 * (1 - t)), "ahk_id " state.hwnd)
    if t >= 1 {
        SetTimer(state.fadeTimer, 0)
        CancelWorkspaceOverlay(state.monitor)
    }
}

CancelWorkspaceOverlay(monitor) {
    global WorkspaceOverlays
    if !WorkspaceOverlays.Has(monitor)
        return

    state := WorkspaceOverlays[monitor]
    try SetTimer(state.moveTimer, 0)
    if state.HasOwnProp("fadeTimer")
        try SetTimer(state.fadeTimer, 0)
    try state.gui.Destroy()
    WorkspaceOverlays.Delete(monitor)
}

ShowFeedbackForMonitor(monitor, workspace, prefix := "Workspace") {
    ShowWorkspaceOverlay(monitor, workspace, 0, StrUpper(prefix))
}

ShowHelp(*) {
    global WORKSPACE_COUNT
    MsgBox(
        "Independent Monitor Workspaces`n`n"
        . "Point the mouse at the monitor you want to control, then use:`n`n"
        . "Win+Ctrl+Left / Right   Previous or next workspace`n"
        . "Win+Ctrl+1.." WORKSPACE_COUNT "       Open a numbered workspace`n"
        . "Win+Ctrl+Shift+1.." WORKSPACE_COUNT " Move the active window`n"
        . "Win+Ctrl+Shift+Esc      Reveal everything and reset`n`n"
        . "Keep Windows itself on one native virtual desktop while using this script.",
        "Independent Monitor Workspaces",
        "Iconi"
    )
}
