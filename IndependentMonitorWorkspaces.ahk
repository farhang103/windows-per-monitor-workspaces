#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; Independent per-monitor workspaces for Windows 11.
; This intentionally stays on one native Windows virtual desktop and emulates
; independent desktops by showing/hiding only the windows on the selected monitor.

APP_VERSION := "1.2.14"
WORKSPACE_COUNT := 3
SHOW_FEEDBACK := true
WORKSPACE_SLIDE_MS := 340
RAPID_WORKSPACE_SLIDE_MS := 190
INDICATOR_MS := 850
WORKSPACE_WATCHDOG_SOFT_MS := 1400
WORKSPACE_WATCHDOG_RESTART_MS := 4500

global CurrentWorkspace := Map()
global WindowWorkspace := Map()
global HiddenByScript := Map()
global WindowSnapshots := Map()
global WorkspaceFrames := Map()
global WorkspaceWindowOrders := Map()
global DeferredWorkspaceFrameDeletes := []
global WorkspaceSlideAnimations := Map()
global WorkspaceOverlays := Map()
global WorkspaceOverview := false
global OverviewHotCornerMonitor := 0
global OverviewHotCornerEnteredAt := 0
global OverviewHotCornerCooldownUntil := 0
global OverviewPreviewWindows := []
global OverviewPreviewMode := false
global Switching := false
global SwitchingMonitor := 0
global SwitchingStartedAt := 0
global SwitchingLastProgressAt := 0
global SwitchingTargetWorkspace := 0
global SwitchingDirection := 0
global SwitchingSoftRecoveryRequested := false
global WorkspaceRestartScheduled := false
global WorkspaceRestartPreviewMode := false
global RequestedWorkspace := Map()
global PendingWorkspaceSwitches := Map()
global WorkspaceSlideSkipRequests := Map()
global ExternalActivationHandling := false
global PendingExternalActivations := Map()
global ForegroundWinEventCallback := 0
global ForegroundWinEventHook := 0
global TaskbarActivationShields := Map()
global DEBUG_LOG_PATH := GetWorkspaceStoragePath("debug.log")
global DEBUG_PREVIOUS_LOG_PATH := GetWorkspaceStoragePath("debug.previous.log")
global DEBUG_MAX_BYTES := 4 * 1024 * 1024
global DEBUG_SESSION_ID := FormatTime(, "yyyyMMdd-HHmmss") "-" DllCall("GetCurrentProcessId", "uint")
global WORKSPACE_STATE_PATH := GetWorkspaceStoragePath("workspace-state.tsv", true)
global WORKSPACE_RECOVERY_PATH := GetWorkspaceStoragePath("pending-recovery.tsv", true)
global WorkspaceStatePersistenceEnabled := true

; AutoHotkey starts system-DPI-aware, which virtualizes screen coordinates on
; monitors whose scaling differs from the primary display. Keep the script's
; single native UI thread per-monitor-v2-aware so monitor bounds, screen
; captures, GDI buffers, and presentation windows all use physical pixels.
global StartupPreviousDpiContext := EnablePerMonitorDpiAwareness()

DetectHiddenWindows true
SetTitleMatchMode 2
SetWinDelay -1
OnMessage(0x000F, PaintWorkspaceOverview) ; WM_PAINT
OnMessage(0x0014, HandleWorkspaceSlideEraseBackground) ; WM_ERASEBKGND
OnMessage(0x0202, HandleOverviewClick) ; WM_LBUTTONUP

if A_Args.Length && A_Args[1] = "--navigation-self-test" {
    RunNavigationBoundarySelfTest()
    return
}

InitializeDebugLogging()
DebugLog("STARTUP", "version=" APP_VERSION " script=" A_ScriptFullPath
    " args=" FormatDebugArguments())
DebugLog("DPI_AWARENESS", DebugDpiAwareness())

if A_Args.Length && A_Args[1] = "--preview" {
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    previewWorkspace := A_Args.Length >= 3 ? Integer(A_Args[3]) : 2
    previewDirection := A_Args.Length >= 4 ? Integer(A_Args[4]) : 1
    ShowWorkspaceOverlay(previewMonitor, previewWorkspace, previewDirection)
    SetTimer((*) => ExitApp(), -3000)
    return
}

if A_Args.Length && A_Args[1] = "--overview-preview" {
    WorkspaceStatePersistenceEnabled := false
    InitializeMonitors()
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    SetupWorkspaceOverviewPreview(previewMonitor)
    return
}

if A_Args.Length && A_Args[1] = "--slide-preview" {
    WorkspaceStatePersistenceEnabled := false
    InitializeMonitors()
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    SetupWorkspaceSlidePreview(previewMonitor)
    return
}

if A_Args.Length && A_Args[1] = "--rapid-slide-preview" {
    WorkspaceStatePersistenceEnabled := false
    InitializeMonitors()
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    SetupWorkspaceSlidePreview(previewMonitor, true)
    return
}

if A_Args.Length && A_Args[1] = "--handoff-loop-preview" {
    WorkspaceStatePersistenceEnabled := false
    InitializeMonitors()
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    SetupWorkspaceSlidePreview(previewMonitor, false, true)
    return
}

if A_Args.Length && A_Args[1] = "--taskbar-activation-preview" {
    WorkspaceStatePersistenceEnabled := false
    InitializeMonitors()
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    SetupTaskbarActivationPreview(previewMonitor)
    return
}

if A_Args.Length && A_Args[1] = "--watchdog-preview" {
    WorkspaceStatePersistenceEnabled := false
    WorkspaceRestartPreviewMode := true
    InitializeMonitors()
    Switching := true
    SwitchingMonitor := MonitorGetPrimary()
    SwitchingTargetWorkspace := 2
    SwitchingDirection := 1
    SwitchingStartedAt := A_TickCount - WORKSPACE_WATCHDOG_RESTART_MS - 100
    SwitchingLastProgressAt := SwitchingStartedAt
    CheckWorkspaceEngineHealth()
    SetTimer((*) => ExitApp(), -400)
    return
}

InitializeMonitors()
OnExit(HandleAppExit)
OnMessage(0x007E, HandleDisplayChange) ; WM_DISPLAYCHANGE
LoadWorkspaceState()
SyncRequestedWorkspaces()
LearnVisibleWindows()
ApplyRestoredWorkspaceVisibility()
SaveWorkspaceState()

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
Hotkey("#^+r", RestartWorkspaceEngine)
Hotkey("#^Space", ToggleWorkspaceOverview)
RegisterTaskbarClickHotkeys()
SetTimer(CheckWorkspaceOverviewHotCorner, 100)
InstallForegroundWinEventHook()
SetTimer(CheckExternalWorkspaceActivation, 15)
SetTimer(CheckWorkspaceEngineHealth, 250)

A_TrayMenu.Delete()
A_TrayMenu.Add("Workspace overview", ToggleWorkspaceOverview)
A_TrayMenu.Add("Show shortcuts", ShowHelp)
A_TrayMenu.Add("Open debug log", OpenDebugLog)
A_TrayMenu.Add("Restart workspace engine", RestartWorkspaceEngine)
A_TrayMenu.Add("Reveal all windows and reset", ResetAndRevealAll)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit (reveals hidden windows)", (*) => ExitApp())
A_TrayMenu.Default := "Show shortcuts"
A_IconTip := "Independent Monitor Workspaces"

ResumePendingWorkspaceRecovery()
readyMonitor := GetMonitorUnderMouse()
ShowFeedbackForMonitor(readyMonitor,
    CurrentWorkspace.Has(readyMonitor) ? CurrentWorkspace[readyMonitor] : 1, "Ready")

InitializeMonitors() {
    global CurrentWorkspace
    monitorCount := MonitorGetCount()
    DebugLog("MONITORS_INIT", "count=" monitorCount " primary=" MonitorGetPrimary())
    Loop monitorCount {
        CurrentWorkspace[A_Index] := 1
        MonitorGet(A_Index, &left, &top, &right, &bottom)
        DebugLog("MONITOR", "index=" A_Index " name=" MonitorGetName(A_Index)
            " bounds=" left "," top "," right "," bottom
            " dpi=" GetMonitorDpi(A_Index) " current=D1")
    }
}

GetWorkspaceStoragePath(fileName, stateStore := false) {
    ; Codex is a packaged app, so files installed under LOCALAPPDATA can be
    ; physically redirected into the package's LocalCache. Once installed,
    ; anchor logs and state to the script's resolved on-disk directory so an
    ; Explorer-launched recovery process sees the same data as the installer.
    if FileExist(A_ScriptDir "\install.json") {
        if !stateStore
            return A_ScriptDir "\" fileName
        SplitPath(A_ScriptDir, &directoryName, &parentDirectory)
        return parentDirectory "\IndependentMonitorWorkspacesState\" fileName
    }
    directory := stateStore
        ? "IndependentMonitorWorkspacesState"
        : "IndependentMonitorWorkspaces"
    return EnvGet("LOCALAPPDATA") "\" directory "\" fileName
}

SwitchToWorkspace(workspace, direction := 0, *) {
    if Type(direction) != "Integer"
        direction := 0
    EnsureMonitorState()
    monitor := GetMonitorUnderMouse()
    DebugLog("SWITCH_HOTKEY", "target=D" workspace " monitor=" monitor
        " direction=" direction)
    SwitchToWorkspaceOnMonitor(workspace, monitor, direction)
}

SwitchToWorkspaceOnMonitor(workspace, monitor, direction := 0, rapid := false,
    externalActivatedHwnd := 0) {
    global WORKSPACE_COUNT, CurrentWorkspace, WindowWorkspace
    global WORKSPACE_SLIDE_MS, RAPID_WORKSPACE_SLIDE_MS
    global HiddenByScript, Switching, SwitchingMonitor, WorkspaceOverview, OverviewPreviewMode
    global RequestedWorkspace, PendingWorkspaceSwitches, WorkspaceSlideSkipRequests
    global SwitchingStartedAt, SwitchingLastProgressAt, SwitchingTargetWorkspace
    global SwitchingDirection, SwitchingSoftRecoveryRequested

    if Type(direction) != "Integer"
        direction := 0

    DebugLog("SWITCH_REQUEST", "target=D" workspace " monitor=" monitor
        " direction=" direction " rapid=" rapid " switching=" Switching)
    if workspace < 1 || workspace > WORKSPACE_COUNT {
        DebugLog("SWITCH_REJECT", "reason=invalid-workspace target=" workspace)
        return false
    }
    RequestedWorkspace[monitor] := workspace
    if Switching {
        PendingWorkspaceSwitches[monitor] := {
            workspace: workspace, direction: direction, rapid: true
        }
        if SwitchingMonitor = monitor
            WorkspaceSlideSkipRequests[monitor] := true
        DebugLog("SWITCH_QUEUE", "target=D" workspace " monitor=" monitor
            " direction=" direction " activeMonitor=" SwitchingMonitor
            " accelerateActive=" (SwitchingMonitor = monitor)
            " pendingMonitors=" PendingWorkspaceSwitches.Count)
        return false
    }

    if WorkspaceOverview
        CloseWorkspaceOverview(false)

    Switching := true
    SwitchingMonitor := monitor
    SwitchingStartedAt := A_TickCount
    SwitchingLastProgressAt := SwitchingStartedAt
    SwitchingTargetWorkspace := workspace
    SwitchingDirection := direction
    SwitchingSoftRecoveryRequested := false
    animation := false
    switchSucceeded := false
    try {
        EnsureMonitorState()
        oldWorkspace := CurrentWorkspace[monitor]
        DebugLog("SWITCH_BEGIN", "monitor=" monitor " from=D" oldWorkspace
            " to=D" workspace " map=" DebugWorkspaceSummary(monitor))
        MarkWorkspaceSwitchProgress("begin")

        if externalActivatedHwnd
            PrepareShieldedExternalActivation(
                externalActivatedHwnd, monitor, workspace)

        ; Discover newly opened windows before changing what is visible.
        LearnVisibleWindows()

        if workspace = oldWorkspace {
            DebugLog("SWITCH_SAME", "monitor=" monitor " workspace=D" workspace)
            ShowWorkspaceOverlay(monitor, workspace, 0)
            SetTimer(VerifyWorkspaceTransition.Bind(monitor, workspace, 0), -200)
            return true
        }

        if direction = 0
            direction := workspace > oldWorkspace ? 1 : -1

        ; Preserve the complete top-to-bottom stack before any outgoing app is
        ; hidden. This prevents the order of asynchronous show acknowledgements
        ; from deciding which maximized app appears on top when we return.
        RememberWorkspaceWindowOrder(monitor, oldWorkspace)

        ; The animation layer owns captured window surfaces while the real
        ; outgoing windows are hidden underneath it.
        animationDuration := rapid ? RAPID_WORKSPACE_SLIDE_MS : WORKSPACE_SLIDE_MS
        animation := BeginWorkspaceSlideAnimation(
            monitor, oldWorkspace, workspace, direction, animationDuration)
        MarkWorkspaceSwitchProgress("animation-ready")
        if externalActivatedHwnd && animation
            CancelTaskbarActivationShield(monitor, 0, "animation-handoff")

        ; First hide every non-target window. Incoming windows remain hidden
        ; until their captured surfaces finish sliding into place.
        for hwnd, slot in WindowWorkspace.Clone() {
            if !WinExist("ahk_id " hwnd) {
                ForgetWindow(hwnd)
                continue
            }
            if slot.monitor != monitor
                continue

            if slot.workspace = workspace
                continue

            if IsVisible(hwnd) && (OverviewPreviewMode || IsManageableWindow(hwnd)) {
                DebugLog("SWITCH_HIDE", "target=D" workspace " assigned=D" slot.workspace
                    " " DebugDescribeWindow(hwnd))
                if !animation
                    CaptureWindowSnapshot(hwnd)
                HideWindowFast(hwnd)
                HiddenByScript[hwnd] := true
            } else {
                DebugLog("SWITCH_SKIP", "target=D" workspace " assigned=D" slot.workspace
                    " visible=" IsVisible(hwnd) " manageable=" IsManageableWindow(hwnd)
                    " scriptHidden=" HiddenByScript.Has(hwnd) " " DebugDescribeWindow(hwnd))
            }
        }

        MarkWorkspaceSwitchProgress("windows-hidden")
        RunWorkspaceSlideAnimation(animation)
        MarkWorkspaceSwitchProgress("animation-complete")

        ; Keep the completed, opaque animation frame in place until every app
        ; that this script hid has acknowledged its show request. A fixed delay
        ; races slower application UI threads and exposes only the first app to
        ; respond. Restore the saved window stack while it is still covered.
        RevealWorkspaceForHandoff(monitor, workspace)
        MarkWorkspaceSwitchProgress("handoff-complete")
        EndWorkspaceSlideAnimation(animation)
        animation := false

        CurrentWorkspace[monitor] := workspace
        DebugLog("SWITCH_COMMIT", "monitor=" monitor " current=D" workspace
            " map=" DebugWorkspaceSummary(monitor))
        ShowWorkspaceOverlay(monitor, workspace, direction)
        ScheduleWorkspaceStateSave()
        SetTimer(VerifyWorkspaceTransition.Bind(monitor, workspace, 0), -200)
        switchSucceeded := true
    } catch as error {
        DebugLog("SWITCH_ERROR", "monitor=" monitor " target=D" workspace
            " message=" DebugClean(error.Message) " what=" DebugClean(error.What)
            " line=" error.Line)
        ScheduleWorkspaceEngineRestart(
            "switch-exception", monitor, workspace, direction)
    } finally {
        try EndWorkspaceSlideAnimation(animation)
        if externalActivatedHwnd
            CancelTaskbarActivationShield(monitor, 0, "switch-finalize")
        if WorkspaceSlideSkipRequests.Has(monitor)
            WorkspaceSlideSkipRequests.Delete(monitor)
        Switching := false
        SwitchingMonitor := 0
        SwitchingStartedAt := 0
        SwitchingLastProgressAt := 0
        SwitchingTargetWorkspace := 0
        SwitchingDirection := 0
        SwitchingSoftRecoveryRequested := false
        DebugLog("SWITCH_END", "monitor=" monitor " target=D" workspace
            " current=" (CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing"))
        if PendingWorkspaceSwitches.Count
            SetTimer(ProcessPendingWorkspaceSwitches, -1)
    }
    return switchSucceeded
}

PreviousWorkspace(*) {
    global CurrentWorkspace, RequestedWorkspace
    EnsureMonitorState()
    monitor := GetMonitorUnderMouse()
    baseWorkspace := RequestedWorkspace.Has(monitor)
        ? RequestedWorkspace[monitor] : CurrentWorkspace[monitor]
    nextWorkspace := GetAdjacentWorkspace(baseWorkspace, -1)
    if nextWorkspace = baseWorkspace {
        DebugLog("SWITCH_BOUNDARY", "monitor=" monitor
            " direction=-1 requested=D" baseWorkspace " boundary=D1")
        return
    }
    SwitchToWorkspace(nextWorkspace, -1)
}

NextWorkspace(*) {
    global WORKSPACE_COUNT, CurrentWorkspace, RequestedWorkspace
    EnsureMonitorState()
    monitor := GetMonitorUnderMouse()
    baseWorkspace := RequestedWorkspace.Has(monitor)
        ? RequestedWorkspace[monitor] : CurrentWorkspace[monitor]
    nextWorkspace := GetAdjacentWorkspace(baseWorkspace, 1)
    if nextWorkspace = baseWorkspace {
        DebugLog("SWITCH_BOUNDARY", "monitor=" monitor
            " direction=1 requested=D" baseWorkspace
            " boundary=D" WORKSPACE_COUNT)
        return
    }
    SwitchToWorkspace(nextWorkspace, 1)
}

GetAdjacentWorkspace(baseWorkspace, direction) {
    global WORKSPACE_COUNT
    return Max(1, Min(WORKSPACE_COUNT, baseWorkspace + direction))
}

RunNavigationBoundarySelfTest() {
    cases := [
        [1, -1, 1],
        [1, 1, 2],
        [2, -1, 1],
        [2, 1, 3],
        [3, -1, 2],
        [3, 1, 3]
    ]
    for testCase in cases {
        actual := GetAdjacentWorkspace(testCase[1], testCase[2])
        if actual != testCase[3] {
            FileAppend("Navigation boundary self-test failed: base=D"
                testCase[1] " direction=" testCase[2] " expected=D"
                testCase[3] " actual=D" actual "`n", "*")
            ExitApp(1)
        }
    }

    ; Repeated input is calculated from the latest requested D-number. Verify
    ; that extra presses remain pinned to each edge instead of wrapping.
    workspace := 1
    Loop 5
        workspace := GetAdjacentWorkspace(workspace, 1)
    if workspace != 3 {
        FileAppend("Navigation boundary self-test failed: repeated right ended at D"
            workspace "`n", "*")
        ExitApp(1)
    }
    Loop 5
        workspace := GetAdjacentWorkspace(workspace, -1)
    if workspace != 1 {
        FileAppend("Navigation boundary self-test failed: repeated left ended at D"
            workspace "`n", "*")
        ExitApp(1)
    }

    FileAppend("Navigation boundary self-test passed.`n", "*")
    ExitApp(0)
}

MoveActiveWindowToWorkspace(workspace, *) {
    global WORKSPACE_COUNT, CurrentWorkspace, WindowWorkspace, HiddenByScript

    if workspace < 1 || workspace > WORKSPACE_COUNT
        return

    hwnd := WinExist("A")
    if !hwnd || !IsManageableWindow(hwnd) {
        DebugLog("MOVE_REJECT", "target=D" workspace " hwnd=" hwnd
            " manageable=" (hwnd ? IsManageableWindow(hwnd) : false))
        return
    }

    EnsureMonitorState()
    monitor := GetWindowMonitor(hwnd)
    DebugLog("MOVE_ASSIGN", "target=D" workspace " monitor=" monitor " " DebugDescribeWindow(hwnd))
    if WindowWorkspace.Has(hwnd) {
        previousSlot := WindowWorkspace[hwnd]
        InvalidateWorkspaceFrame(previousSlot.monitor, previousSlot.workspace)
    }
    InvalidateWorkspaceFrame(monitor, workspace)
    WindowWorkspace[hwnd] := {monitor: monitor, workspace: workspace}
    PromoteWorkspaceWindow(monitor, workspace, hwnd)
    ScheduleWorkspaceStateSave()

    if workspace != CurrentWorkspace[monitor] {
        CaptureWindowSnapshot(hwnd)
        HideWindowFast(hwnd)
        HiddenByScript[hwnd] := true
    }

    ShowFeedbackForMonitor(monitor, workspace, "Moved to")
}

ToggleWorkspaceOverview(*) {
    global WorkspaceOverview
    if WorkspaceOverview {
        DebugLog("OVERVIEW_TOGGLE", "action=close monitor=" WorkspaceOverview.monitor)
        CloseWorkspaceOverview()
        return
    }
    monitor := GetMonitorUnderMouse()
    DebugLog("OVERVIEW_TOGGLE", "action=open monitor=" monitor)
    ShowWorkspaceOverview(monitor)
}

ShowWorkspaceOverview(monitor := 0, *) {
    global WORKSPACE_COUNT, CurrentWorkspace, WorkspaceOverview, OverviewPreviewMode

    if WorkspaceOverview
        CloseWorkspaceOverview(false)
    if !monitor
        monitor := GetMonitorUnderMouse()

    EnsureMonitorState()
    DebugLog("OVERVIEW_OPEN", "monitor=" monitor " current=D" CurrentWorkspace[monitor]
        " previousActive=" DebugDescribeWindow(WinExist("A")))
    if !OverviewPreviewMode
        LearnVisibleWindows()
    CancelWorkspaceOverlay(monitor)

    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    width := right - left
    height := bottom - top
    dpi := GetMonitorDpi(monitor)
    scaleRatio := dpi / A_ScreenDPI
    density := dpi / 96
    previousActive := WinExist("A")

    overview := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale")
    overview.BackColor := "070B14"
    overview.MarginX := 0
    overview.MarginY := 0
    overview.OnEvent("Escape", HandleOverviewEscape)
    overview.OnEvent("Close", HandleOverviewEscape)

    state := {
        gui: overview, hwnd: 0, monitor: monitor,
        left: left, top: top, width: width, height: height,
        dpi: dpi, density: density, scaleRatio: scaleRatio,
        previousActive: previousActive,
        paintRects: [], workspaceRects: [], windowRects: [],
        pendingThumbnails: [], thumbnails: [], snapshotDraws: []
    }
    WorkspaceOverview := state
    BuildWorkspaceOverview(state)

    showWidth := Max(1, Round(width / scaleRatio))
    showHeight := Max(1, Round(height / scaleRatio))
    overview.Show("x" left " y" top " w" showWidth " h" showHeight)
    state.hwnd := overview.Hwnd

    ; Lock the final destination to the monitor's exact physical work area.
    try DllCall("SetWindowPos", "ptr", state.hwnd, "ptr", -1,
        "int", left, "int", top, "int", width, "int", height,
        "uint", 0x0040)
    try DllCall("InvalidateRect", "ptr", state.hwnd, "ptr", 0, "int", true)

    for pending in state.pendingThumbnails
        RegisterOverviewThumbnail(state, pending)

    try WinActivate("ahk_id " state.hwnd)
    DebugLog("OVERVIEW_READY", "monitor=" monitor " hwnd=" state.hwnd
        " workspaceRects=" state.workspaceRects.Length
        " windowRects=" state.windowRects.Length)
}

BuildWorkspaceOverview(state) {
    global WORKSPACE_COUNT, CurrentWorkspace

    density := state.density
    outerPadding := Round(28 * density)
    panelGap := Round(18 * density)
    panelWidth := Floor((state.width - (outerPadding * 2) - (panelGap * (WORKSPACE_COUNT - 1))) / WORKSPACE_COUNT)
    panelHeight := state.height - (outerPadding * 2)
    headerHeight := Round(64 * density)
    innerPadding := Round(16 * density)
    tileGap := Round(12 * density)
    activeWorkspace := CurrentWorkspace.Has(state.monitor) ? CurrentWorkspace[state.monitor] : 1

    ; COLORREF values are BGR rather than RGB.
    state.paintRects.Push({x: 0, y: 0, w: state.width, h: state.height, color: 0x140B07})

    Loop WORKSPACE_COUNT {
        workspace := A_Index
        panelX := outerPadding + ((workspace - 1) * (panelWidth + panelGap))
        panelY := outerPadding
        border := Max(1, Round((workspace = activeWorkspace ? 3 : 1) * density))
        borderColor := workspace = activeWorkspace ? 0xEB6325 : 0x493729

        state.paintRects.Push({x: panelX, y: panelY, w: panelWidth, h: panelHeight, color: borderColor})
        state.paintRects.Push({
            x: panelX + border, y: panelY + border,
            w: panelWidth - (border * 2), h: panelHeight - (border * 2),
            color: 0x271811
        })
        state.workspaceRects.Push({x: panelX, y: panelY, w: panelWidth, h: panelHeight, workspace: workspace})

        windows := GetOverviewWindows(state.monitor, workspace)
        windowCount := windows.Length
        DebugLog("OVERVIEW_PANEL", "monitor=" state.monitor " workspace=D" workspace
            " windows=" windowCount " active=" (workspace = activeWorkspace))
        countLabel := windowCount = 1 ? "1 window" : windowCount " windows"
        AddOverviewText(state,
            panelX + innerPadding, panelY + Round(12 * density),
            panelWidth - (innerPadding * 2), Round(34 * density),
            "D" workspace, "s20 cFFFFFF w600", "Center +0x200 BackgroundTrans")
        AddOverviewText(state,
            panelX + innerPadding, panelY + Round(42 * density),
            panelWidth - (innerPadding * 2), Round(18 * density),
            countLabel, "s9 c94A3B8 w500", "Center +0x200 BackgroundTrans")

        contentX := panelX + innerPadding
        contentY := panelY + headerHeight
        contentWidth := panelWidth - (innerPadding * 2)
        contentHeight := panelHeight - headerHeight - innerPadding

        if !windowCount {
            AddOverviewText(state, contentX, contentY, contentWidth, contentHeight,
                "Empty", "s13 c64748B w500", "Center +0x200 BackgroundTrans")
            continue
        }

        visibleCount := Min(windowCount, 9)
        columns := visibleCount <= 2 ? 1 : visibleCount <= 6 ? 2 : 3
        rows := Ceil(visibleCount / columns)
        tileWidth := Floor((contentWidth - (tileGap * (columns - 1))) / columns)
        tileHeight := Floor((contentHeight - (tileGap * (rows - 1))) / rows)
        titleHeight := Round(30 * density)

        Loop visibleCount {
            itemIndex := A_Index
            hwnd := windows[itemIndex]
            DebugLog("OVERVIEW_ITEM", "monitor=" state.monitor " workspace=D" workspace
                " item=" itemIndex " " DebugDescribeWindow(hwnd))
            column := Mod(itemIndex - 1, columns)
            row := Floor((itemIndex - 1) / columns)
            tileX := contentX + (column * (tileWidth + tileGap))
            tileY := contentY + (row * (tileHeight + tileGap))
            previewInset := Round(7 * density)
            previewRect := {
                x: tileX + previewInset,
                y: tileY + previewInset,
                w: tileWidth - (previewInset * 2),
                h: Max(1, tileHeight - titleHeight - (previewInset * 2))
            }

            state.paintRects.Push({x: tileX, y: tileY, w: tileWidth, h: tileHeight, color: 0x20120B})
            state.windowRects.Push({
                x: tileX, y: tileY, w: tileWidth, h: tileHeight,
                workspace: workspace, hwnd: hwnd
            })

            title := GetOverviewWindowTitle(hwnd)
            AddOverviewText(state,
                tileX + previewInset, tileY + tileHeight - titleHeight,
                tileWidth - (previewInset * 2), titleHeight,
                title, "s9 cE2E8F0 w500", "Center +0x200 +0x4000 BackgroundTrans")
            state.pendingThumbnails.Push({hwnd: hwnd, rect: previewRect})
        }
    }
}

GetOverviewWindows(monitor, workspace) {
    global WindowWorkspace
    result := []
    seen := Map()

    for hwnd in WinGetList() {
        if !WindowWorkspace.Has(hwnd)
            continue
        slot := WindowWorkspace[hwnd]
        if slot.monitor != monitor || slot.workspace != workspace
            continue
        if !WinExist("ahk_id " hwnd)
            continue
        result.Push(hwnd)
        seen[hwnd] := true
    }

    for hwnd, slot in WindowWorkspace {
        if seen.Has(hwnd) || slot.monitor != monitor || slot.workspace != workspace
            continue
        if WinExist("ahk_id " hwnd)
            result.Push(hwnd)
    }
    return result
}

GetOverviewWindowTitle(hwnd) {
    try title := Trim(WinGetTitle("ahk_id " hwnd))
    catch
        title := ""
    if title
        return title
    try return WinGetProcessName("ahk_id " hwnd)
    catch
        return "Window"
}

AddOverviewText(state, x, y, width, height, text, fontOptions, controlOptions := "") {
    options := OverviewRectOptions(x, y, width, height, state.scaleRatio)
    if controlOptions
        options .= " " controlOptions
    control := state.gui.AddText(options, text)
    control.SetFont(fontOptions, "Segoe UI")
    return control
}

OverviewRectOptions(x, y, width, height, scaleRatio) {
    return "x" Round(x / scaleRatio)
        . " y" Round(y / scaleRatio)
        . " w" Max(1, Round(width / scaleRatio))
        . " h" Max(1, Round(height / scaleRatio))
}

RegisterOverviewThumbnail(state, pending) {
    global HiddenByScript, WindowSnapshots

    if HiddenByScript.Has(pending.hwnd) && WindowSnapshots.Has(pending.hwnd) {
        snapshot := WindowSnapshots[pending.hwnd]
        destination := FitOverviewRect(snapshot.width, snapshot.height, pending.rect)
        state.snapshotDraws.Push({snapshot: snapshot, rect: destination})
        try DllCall("InvalidateRect", "ptr", state.hwnd, "ptr", 0, "int", true)
        return true
    }

    thumbnail := 0
    try result := DllCall("dwmapi\DwmRegisterThumbnail",
        "ptr", state.hwnd, "ptr", pending.hwnd, "ptr*", &thumbnail, "int")
    catch
        result := -1

    if result != 0 || !thumbnail {
        AddOverviewText(state,
            pending.rect.x, pending.rect.y, pending.rect.w, pending.rect.h,
            "Preview unavailable", "s10 c64748B w500", "Center +0x200 BackgroundTrans")
        return false
    }

    sourceWidth := 0
    sourceHeight := 0
    clientRect := Buffer(16, 0)
    if DllCall("GetClientRect", "ptr", pending.hwnd, "ptr", clientRect.Ptr) {
        sourceWidth := NumGet(clientRect, 8, "int")
        sourceHeight := NumGet(clientRect, 12, "int")
    }
    if sourceWidth <= 0 || sourceHeight <= 0 {
        sourceSize := Buffer(8, 0)
        if DllCall("dwmapi\DwmQueryThumbnailSourceSize", "ptr", thumbnail, "ptr", sourceSize.Ptr, "int") = 0 {
            sourceWidth := NumGet(sourceSize, 0, "int")
            sourceHeight := NumGet(sourceSize, 4, "int")
        }
    }

    if sourceWidth <= 0 || sourceHeight <= 0 {
        DllCall("dwmapi\DwmUnregisterThumbnail", "ptr", thumbnail)
        return false
    }

    destination := FitOverviewRect(sourceWidth, sourceHeight, pending.rect)
    drawX := destination.x
    drawY := destination.y
    drawWidth := destination.w
    drawHeight := destination.h

    ; DWM_THUMBNAIL_PROPERTIES: flags, destination/source RECTs, opacity, visibility.
    properties := Buffer(48, 0)
    NumPut("uint", 0x1D, properties, 0)
    NumPut("int", drawX, "int", drawY,
        "int", drawX + drawWidth, "int", drawY + drawHeight, properties, 4)
    NumPut("uchar", 255, properties, 36)
    NumPut("int", 1, properties, 40)
    NumPut("int", 1, properties, 44)

    result := DllCall("dwmapi\DwmUpdateThumbnailProperties",
        "ptr", thumbnail, "ptr", properties.Ptr, "int")
    if result != 0 {
        DllCall("dwmapi\DwmUnregisterThumbnail", "ptr", thumbnail)
        return false
    }

    state.thumbnails.Push(thumbnail)
    return true
}

FitOverviewRect(sourceWidth, sourceHeight, bounds) {
    fit := Min(bounds.w / sourceWidth, bounds.h / sourceHeight)
    width := Max(1, Round(sourceWidth * fit))
    height := Max(1, Round(sourceHeight * fit))
    return {
        x: bounds.x + Floor((bounds.w - width) / 2),
        y: bounds.y + Floor((bounds.h - height) / 2),
        w: width, h: height
    }
}

PaintWorkspaceOverview(wParam, lParam, msg, hwnd) {
    global WorkspaceOverview, WorkspaceSlideAnimations
    if WorkspaceSlideAnimations.Has(hwnd) {
        PaintWorkspaceSlide(hwnd)
        return 0
    }
    if PaintTaskbarActivationShield(hwnd)
        return 0
    if !WorkspaceOverview || !WorkspaceOverview.hwnd || hwnd != WorkspaceOverview.hwnd
        return

    state := WorkspaceOverview
    paint := Buffer(72, 0)
    hdc := DllCall("BeginPaint", "ptr", hwnd, "ptr", paint.Ptr, "ptr")
    if !hdc
        return

    for item in state.paintRects {
        rect := Buffer(16, 0)
        NumPut("int", item.x, "int", item.y,
            "int", item.x + item.w, "int", item.y + item.h, rect, 0)
        brush := DllCall("CreateSolidBrush", "uint", item.color, "ptr")
        DllCall("FillRect", "ptr", hdc, "ptr", rect.Ptr, "ptr", brush)
        DllCall("DeleteObject", "ptr", brush)
    }

    for item in state.snapshotDraws
        DrawOverviewSnapshot(hdc, item.snapshot, item.rect)
    DllCall("EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
    return 0
}

HandleWorkspaceSlideEraseBackground(wParam, lParam, msg, hwnd) {
    global WorkspaceSlideAnimations, TaskbarActivationShields
    if WorkspaceSlideAnimations.Has(hwnd)
        return 1
    for monitor, state in TaskbarActivationShields {
        if state.hwnd = hwnd
            return 1
    }
}

DrawOverviewSnapshot(destinationDc, snapshot, rect) {
    sourceDc := DllCall("CreateCompatibleDC", "ptr", destinationDc, "ptr")
    if !sourceDc
        return
    oldBitmap := DllCall("SelectObject", "ptr", sourceDc, "ptr", snapshot.bitmap, "ptr")
    DllCall("SetStretchBltMode", "ptr", destinationDc, "int", 4)
    DllCall("StretchBlt",
        "ptr", destinationDc, "int", rect.x, "int", rect.y, "int", rect.w, "int", rect.h,
        "ptr", sourceDc, "int", 0, "int", 0, "int", snapshot.width, "int", snapshot.height,
        "uint", 0x00CC0020)
    DllCall("SelectObject", "ptr", sourceDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", sourceDc)
}

HandleOverviewClick(wParam, lParam, msg, hwnd) {
    global WorkspaceOverview
    if !WorkspaceOverview || !WorkspaceOverview.hwnd
        return

    state := WorkspaceOverview
    if hwnd != state.hwnd && !DllCall("IsChild", "ptr", state.hwnd, "ptr", hwnd)
        return

    point := Buffer(8, 0)
    if !DllCall("GetCursorPos", "ptr", point.Ptr)
        return
    if !DllCall("ScreenToClient", "ptr", state.hwnd, "ptr", point.Ptr)
        return
    x := NumGet(point, 0, "int")
    y := NumGet(point, 4, "int")
    DebugLog("OVERVIEW_CLICK", "messageHwnd=" hwnd " overviewHwnd=" state.hwnd
        " monitor=" state.monitor " client=" x "," y)

    for item in state.windowRects {
        if PointInsideOverviewRect(x, y, item) {
            targetHwnd := item.hwnd
            targetWorkspace := item.workspace
            targetMonitor := state.monitor
            DebugLog("OVERVIEW_WINDOW_HIT", "workspace=D" targetWorkspace
                " monitor=" targetMonitor " rect=" item.x "," item.y "," item.w "," item.h
                " " DebugDescribeWindow(targetHwnd))
            CloseWorkspaceOverview(false)
            ; Finish the workspace transition outside WM_LBUTTONUP. The selected
            ; window is revealed only after that transition is confirmed.
            SetTimer(CompleteOverviewWindowSelection.Bind(
                targetHwnd, targetWorkspace, targetMonitor, 0), -1)
            return 0
        }
    }

    for item in state.workspaceRects {
        if PointInsideOverviewRect(x, y, item) {
            targetWorkspace := item.workspace
            targetMonitor := state.monitor
            DebugLog("OVERVIEW_PANEL_HIT", "workspace=D" targetWorkspace
                " monitor=" targetMonitor " rect=" item.x "," item.y "," item.w "," item.h)
            CloseWorkspaceOverview(false)
            SwitchToWorkspaceOnMonitor(targetWorkspace, targetMonitor)
            return 0
        }
    }

    DebugLog("OVERVIEW_CLICK_MISS", "monitor=" state.monitor " client=" x "," y)
    CloseWorkspaceOverview()
    return 0
}

PointInsideOverviewRect(x, y, rect) {
    return x >= rect.x && x < rect.x + rect.w
        && y >= rect.y && y < rect.y + rect.h
}

CompleteOverviewWindowSelection(hwnd, workspace, monitor, attempt := 0) {
    global CurrentWorkspace, Switching
    DebugLog("SELECTION_STEP", "attempt=" attempt " workspace=D" workspace
        " monitor=" monitor " switching=" Switching " current="
        (CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing")
        " " DebugDescribeWindow(hwnd))
    if !WinExist("ahk_id " hwnd) {
        DebugLog("SELECTION_ABORT", "reason=window-gone hwnd=" hwnd)
        return
    }

    ; A hotkey or another monitor may already be switching. Wait for it to
    ; finish instead of revealing one window on the currently displayed D-slot.
    if Switching {
        DebugLog("SELECTION_WAIT", "reason=switch-in-progress attempt=" attempt)
        if attempt < 10
            SetTimer(CompleteOverviewWindowSelection.Bind(
                hwnd, workspace, monitor, attempt + 1), -50)
        return
    }

    switched := SwitchToWorkspaceOnMonitor(workspace, monitor)
    if !switched || !CurrentWorkspace.Has(monitor)
        || CurrentWorkspace[monitor] != workspace {
        DebugLog("SELECTION_WAIT", "reason=switch-not-committed switched=" switched
            " expected=D" workspace " actual="
            (CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing")
            " attempt=" attempt)
        if attempt < 10
            SetTimer(CompleteOverviewWindowSelection.Bind(
                hwnd, workspace, monitor, attempt + 1), -50)
        return
    }

    DebugLog("SELECTION_COMMITTED", "workspace=D" workspace " monitor=" monitor
        " activationDelayMs=80 " DebugDescribeWindow(hwnd))
    SetTimer(ActivateOverviewWindow.Bind(hwnd, monitor, workspace, 0), -80)
}

ActivateOverviewWindow(hwnd, monitor, workspace, attempt := 0) {
    global CurrentWorkspace, HiddenByScript
    DebugLog("ACTIVATE_ATTEMPT", "attempt=" attempt " workspace=D" workspace
        " monitor=" monitor " current="
        (CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing")
        " activeHwnd=" WinExist("A") " " DebugDescribeWindow(hwnd))
    if !WinExist("ahk_id " hwnd) {
        DebugLog("ACTIVATE_ABORT", "reason=window-gone hwnd=" hwnd)
        return
    }

    ; Do not leak the selected window into another workspace if the user starts
    ; a new switch during the short activation delay or focus retry period.
    if !CurrentWorkspace.Has(monitor) || CurrentWorkspace[monitor] != workspace {
        DebugLog("ACTIVATE_ABORT", "reason=workspace-mismatch expected=D" workspace
            " actual=" (CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing"))
        return
    }

    if HiddenByScript.Has(hwnd)
        HiddenByScript.Delete(hwnd)

    try minimized := WinGetMinMax("ahk_id " hwnd) = -1
    catch
        minimized := false
    ; A direct restore/show is intentional here: clicking a preview means the
    ; user explicitly wants that exact window in the foreground.
    try DllCall("ShowWindow", "ptr", hwnd, "int", minimized ? 9 : 5)
    if minimized
        try WinRestore("ahk_id " hwnd)
    try WinActivate("ahk_id " hwnd)
    try DllCall("SetForegroundWindow", "ptr", hwnd)

    ; Focusing some applications can briefly cover a newly created overlay.
    ; Refresh it after focus so app-preview clicks visibly confirm D1/D2/D3,
    ; exactly like the numbered and previous/next hotkeys.
    if attempt = 0
        ShowWorkspaceOverlay(monitor, workspace, 0)

    activated := WinActive("ahk_id " hwnd) != 0
    if activated {
        PromoteWorkspaceWindow(monitor, workspace, hwnd)
        ScheduleWorkspaceStateSave()
    }
    DebugLog("ACTIVATE_RESULT", "attempt=" attempt " activated=" activated
        " activeHwnd=" WinExist("A") " visible=" IsVisible(hwnd)
        " scriptHidden=" HiddenByScript.Has(hwnd) " " DebugDescribeWindow(hwnd))
    if !activated && attempt < 5
        SetTimer(ActivateOverviewWindow.Bind(
            hwnd, monitor, workspace, attempt + 1), -120)
}

IsPointerOverTaskbarAppList(*) {
    MouseGetPos(&x, &y)
    for hwnd in WinGetList("ahk_class MSTaskListWClass") {
        if !IsVisible(hwnd)
            continue
        rect := Buffer(16, 0)
        if !DllCall("GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
            continue
        if x >= NumGet(rect, 0, "int") && x < NumGet(rect, 8, "int")
            && y >= NumGet(rect, 4, "int") && y < NumGet(rect, 12, "int")
            return true
    }
    return false
}

RegisterTaskbarClickHotkeys() {
    HotIf(IsPointerOverTaskbarAppList)
    Hotkey("$LButton", HandleTaskbarAppMouseDown)
    Hotkey("$LButton Up", HandleTaskbarAppMouseUp)
    HotIf()
}

HandleTaskbarAppMouseDown(*) {
    BeginTaskbarActivationShield(GetMonitorUnderMouse())
    SendEvent("{LButton Down}")
}

HandleTaskbarAppMouseUp(*) {
    SendEvent("{LButton Up}")
    SetTimer(CancelUnclaimedTaskbarActivationShields, -180)
}

BeginTaskbarActivationShield(monitor) {
    global CurrentWorkspace, Switching, WorkspaceOverview
    global ExternalActivationHandling, TaskbarActivationShields
    if Switching || WorkspaceOverview || ExternalActivationHandling
        return false
    EnsureMonitorState()
    CancelTaskbarActivationShield(monitor, 0, "replace")

    workspace := CurrentWorkspace[monitor]
    captureStarted := A_TickCount
    frame := CaptureMonitorWorkspaceFrame(monitor, workspace)
    if !frame
        return false
    bitmap := DuplicateWorkspaceBitmap(frame.bitmap, frame.width, frame.height)
    if !bitmap
        return false

    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    layer := CreatePhysicalPixelLayer()
    state := {
        gui: layer, hwnd: layer.Hwnd, monitor: monitor, workspace: workspace,
        left: left, top: top, width: right - left, height: bottom - top,
        bitmap: bitmap, claimed: false, startedAt: A_TickCount
    }
    TaskbarActivationShields[monitor] := state
    ; Position the hidden HWND in physical pixels first. Gui.Show() interprets
    ; dimensions through the GUI DPI and can expose one scaled frame before a
    ; corrective SetWindowPos on mixed-scaling displays.
    try DllCall("SetWindowPos", "ptr", state.hwnd, "ptr", -1,
        "int", left, "int", top, "int", state.width, "int", state.height,
        "uint", 0x0010)
    try DllCall("SetWindowPos", "ptr", state.hwnd, "ptr", -1,
        "int", left, "int", top, "int", state.width, "int", state.height,
        "uint", 0x0050)
    PresentTaskbarActivationShield(state)
    try DllCall("dwmapi\DwmFlush")
    DebugLog("TASKBAR_SHIELD_BEGIN", "monitor=" monitor
        " workspace=D" workspace " hwnd=" state.hwnd
        " resolution=" state.width "x" state.height
        " geometry=" DebugWindowRenderGeometry(state.hwnd)
        " preparationMs=" (A_TickCount - captureStarted))
    SetTimer(CancelTaskbarActivationShield.Bind(
        monitor, state.hwnd, "timeout"), -900)
    return true
}

DuplicateWorkspaceBitmap(sourceBitmap, width, height) {
    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    sourceDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
    destinationDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
    bitmap := screenDc ? DllCall("CreateCompatibleBitmap", "ptr", screenDc,
        "int", width, "int", height, "ptr") : 0
    if !screenDc || !sourceDc || !destinationDc || !bitmap {
        if bitmap
            DllCall("DeleteObject", "ptr", bitmap)
        if sourceDc
            DllCall("DeleteDC", "ptr", sourceDc)
        if destinationDc
            DllCall("DeleteDC", "ptr", destinationDc)
        if screenDc
            DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
        return 0
    }
    oldSource := DllCall("SelectObject", "ptr", sourceDc, "ptr", sourceBitmap, "ptr")
    oldDestination := DllCall("SelectObject", "ptr", destinationDc, "ptr", bitmap, "ptr")
    copied := DllCall("BitBlt", "ptr", destinationDc,
        "int", 0, "int", 0, "int", width, "int", height,
        "ptr", sourceDc, "int", 0, "int", 0, "uint", 0x00CC0020, "int")
    DllCall("SelectObject", "ptr", sourceDc, "ptr", oldSource)
    DllCall("SelectObject", "ptr", destinationDc, "ptr", oldDestination)
    DllCall("DeleteDC", "ptr", sourceDc)
    DllCall("DeleteDC", "ptr", destinationDc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
    if !copied {
        DllCall("DeleteObject", "ptr", bitmap)
        return 0
    }
    return bitmap
}

PresentTaskbarActivationShield(state, destinationDc := 0) {
    sourceDc := DllCall("CreateCompatibleDC", "ptr", destinationDc ? destinationDc : 0, "ptr")
    if !sourceDc
        return false
    oldBitmap := DllCall("SelectObject", "ptr", sourceDc, "ptr", state.bitmap, "ptr")
    releaseDestination := false
    if !destinationDc {
        destinationDc := DllCall("GetDC", "ptr", state.hwnd, "ptr")
        releaseDestination := true
    }
    copied := destinationDc ? DllCall("BitBlt", "ptr", destinationDc,
        "int", 0, "int", 0, "int", state.width, "int", state.height,
        "ptr", sourceDc, "int", 0, "int", 0, "uint", 0x00CC0020, "int") : 0
    DllCall("SelectObject", "ptr", sourceDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", sourceDc)
    if releaseDestination && destinationDc
        DllCall("ReleaseDC", "ptr", state.hwnd, "ptr", destinationDc)
    return copied != 0
}

PaintTaskbarActivationShield(hwnd) {
    global TaskbarActivationShields
    for monitor, state in TaskbarActivationShields {
        if state.hwnd != hwnd
            continue
        paint := Buffer(72, 0)
        hdc := DllCall("BeginPaint", "ptr", hwnd, "ptr", paint.Ptr, "ptr")
        if hdc {
            PresentTaskbarActivationShield(state, hdc)
            DllCall("EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
        }
        return true
    }
    return false
}

CancelUnclaimedTaskbarActivationShields(*) {
    global TaskbarActivationShields
    for monitor, state in TaskbarActivationShields.Clone() {
        if !state.claimed
            CancelTaskbarActivationShield(monitor, state.hwnd, "unclaimed")
    }
}

CancelTaskbarActivationShield(monitor, expectedHwnd := 0, reason := "cancel", *) {
    global TaskbarActivationShields
    if !TaskbarActivationShields.Has(monitor)
        return
    state := TaskbarActivationShields[monitor]
    if expectedHwnd && state.hwnd != expectedHwnd
        return
    TaskbarActivationShields.Delete(monitor)
    try state.gui.Destroy()
    if state.bitmap
        try DllCall("DeleteObject", "ptr", state.bitmap)
    DebugLog("TASKBAR_SHIELD_END", "monitor=" monitor
        " workspace=D" state.workspace " reason=" reason
        " elapsedMs=" (A_TickCount - state.startedAt))
}

ClearTaskbarActivationShields(reason := "clear") {
    global TaskbarActivationShields
    for monitor in TaskbarActivationShields.Clone()
        CancelTaskbarActivationShield(monitor, 0, reason)
}

PrepareShieldedExternalActivation(hwnd, monitor, workspace) {
    global WindowWorkspace, HiddenByScript, TaskbarActivationShields
    if !TaskbarActivationShields.Has(monitor)
        return false
    if !WinExist("ahk_id " hwnd) || !WindowWorkspace.Has(hwnd)
        return false
    slot := WindowWorkspace[hwnd]
    if slot.monitor != monitor || slot.workspace != workspace
        return false

    startedAt := A_TickCount
    HiddenByScript[hwnd] := true
    if IsVisible(hwnd)
        HideWindowFast(hwnd)
    while IsVisible(hwnd) && A_TickCount - startedAt < 120
        Sleep(4)
    hidden := !IsVisible(hwnd)
    DebugLog("TASKBAR_SHIELD_PREPARE", "monitor=" monitor
        " workspace=D" workspace " hidden=" hidden
        " elapsedMs=" (A_TickCount - startedAt) " hwnd=" hwnd)
    return hidden
}

CheckExternalWorkspaceActivation(*) {
    global Switching, ExternalActivationHandling, WorkspaceOverview
    if Switching || ExternalActivationHandling || WorkspaceOverview
        return
    foregroundHwnd := WinExist("A")
    hwnd := ResolveTrackedWorkspaceWindow(foregroundHwnd)
    if !hwnd || !IsVisible(hwnd)
        return
    QueueExternalWorkspaceActivation(hwnd, "poll", 0)
}

InstallForegroundWinEventHook() {
    global ForegroundWinEventCallback, ForegroundWinEventHook
    if ForegroundWinEventHook
        return true
    try {
        ForegroundWinEventCallback := CallbackCreate(HandleForegroundWinEvent,, 7)
        ; EVENT_SYSTEM_FOREGROUND = 3. Out-of-context delivery keeps this hook
        ; isolated from application UI threads while arriving before polling or
        ; the next ordinary AutoHotkey timer tick.
        ForegroundWinEventHook := DllCall("SetWinEventHook",
            "uint", 3, "uint", 3, "ptr", 0,
            "ptr", ForegroundWinEventCallback,
            "uint", 0, "uint", 0, "uint", 0, "ptr")
        if !ForegroundWinEventHook
            throw Error("SetWinEventHook returned null")
        DebugLog("FOREGROUND_HOOK_INSTALL", "result=ok hook=" ForegroundWinEventHook)
        return true
    } catch as error {
        DebugLog("FOREGROUND_HOOK_ERROR", "message=" DebugClean(error.Message))
        if ForegroundWinEventCallback {
            try CallbackFree(ForegroundWinEventCallback)
            ForegroundWinEventCallback := 0
        }
        ForegroundWinEventHook := 0
        return false
    }
}

RemoveForegroundWinEventHook() {
    global ForegroundWinEventCallback, ForegroundWinEventHook
    if ForegroundWinEventHook {
        try DllCall("UnhookWinEvent", "ptr", ForegroundWinEventHook)
        ForegroundWinEventHook := 0
    }
    if ForegroundWinEventCallback {
        try CallbackFree(ForegroundWinEventCallback)
        ForegroundWinEventCallback := 0
    }
}

HandleForegroundWinEvent(hook, event, foregroundHwnd, objectId,
    childId, eventThread, eventTime) {
    if event != 3 || !foregroundHwnd
        return
    hwnd := ResolveTrackedWorkspaceWindow(foregroundHwnd)
    if hwnd
        QueueExternalWorkspaceActivation(hwnd, "win-event", eventTime)
}

QueueExternalWorkspaceActivation(hwnd, source, eventTime := 0) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global PendingExternalActivations, TaskbarActivationShields
    global ExternalActivationHandling
    if ExternalActivationHandling
        return true
    if !hwnd || !WindowWorkspace.Has(hwnd)
        return false

    slot := WindowWorkspace[hwnd]
    if !CurrentWorkspace.Has(slot.monitor)
        return false
    current := CurrentWorkspace[slot.monitor]
    if slot.workspace = current
        return false
    if PendingExternalActivations.Has(hwnd)
        return true
    if TaskbarActivationShields.Has(slot.monitor) {
        shield := TaskbarActivationShields[slot.monitor]
        if shield.workspace = current
            shield.claimed := true
    }

    ; Windows has already made this app visible before it sends either the
    ; foreground event or the polling fallback. Keep that frame in place and
    ; adopt its assigned workspace atomically; hiding it here would cause a
    ; visible reopen followed by a second slide.
    detectedAt := A_TickCount
    wasVisible := IsVisible(hwnd)
    PendingExternalActivations[hwnd] := {
        source: source, eventTime: eventTime, queuedAt: detectedAt
    }
    shielded := TaskbarActivationShields.Has(slot.monitor)
        && TaskbarActivationShields[slot.monitor].claimed
    DebugLog("EXTERNAL_ACTIVATION_INTERCEPT", "source=" source
        " eventTime=" eventTime " detectedAt=" detectedAt
        " wasVisible=" wasVisible " action="
        (shielded ? "shielded-slide" : "adopt-without-slide")
        " monitor=" slot.monitor " current=D" current
        " assigned=D" slot.workspace " hwnd=" hwnd)
    SetTimer(ProcessPendingExternalActivations, -1)
    return true
}

ProcessPendingExternalActivations(*) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global Switching, WorkspaceOverview, ExternalActivationHandling
    global PendingExternalActivations, TaskbarActivationShields
    if !PendingExternalActivations.Count
        return
    if ExternalActivationHandling || Switching || WorkspaceOverview {
        SetTimer(ProcessPendingExternalActivations, -15)
        return
    }

    for hwnd, request in PendingExternalActivations.Clone() {
        PendingExternalActivations.Delete(hwnd)
        if !WinExist("ahk_id " hwnd) || !WindowWorkspace.Has(hwnd)
            continue
        slot := WindowWorkspace[hwnd]
        if !CurrentWorkspace.Has(slot.monitor)
            continue
        current := CurrentWorkspace[slot.monitor]

        ; A concurrently finishing hotkey may already have reached the app's
        ; workspace after the event was queued. Reveal/focus it without starting
        ; a redundant transition.
        if slot.workspace = current {
            if HiddenByScript.Has(hwnd) {
                ShowWindowFast(hwnd)
                HiddenByScript.Delete(hwnd)
            }
            SetTimer(ActivateOverviewWindow.Bind(
                hwnd, slot.monitor, slot.workspace, 0), -20)
            continue
        }

        ExternalActivationHandling := true
        try {
            DebugLog("EXTERNAL_ACTIVATION_DETECT", "source=" request.source
                " queuedMs=" (A_TickCount - request.queuedAt)
                " trackedHwnd=" hwnd " monitor=" slot.monitor
                " current=D" current " assigned=D" slot.workspace
                " scriptHidden=" HiddenByScript.Has(hwnd) " " DebugDescribeWindow(hwnd))

            shielded := TaskbarActivationShields.Has(slot.monitor)
                && TaskbarActivationShields[slot.monitor].claimed
            if shielded {
                PromoteWorkspaceWindow(slot.monitor, slot.workspace, hwnd)
                InvalidateWorkspaceFrame(slot.monitor, slot.workspace)
                direction := slot.workspace > current ? 1 : -1
                switched := SwitchToWorkspaceOnMonitor(
                    slot.workspace, slot.monitor, direction, false, hwnd)
                committed := switched && CurrentWorkspace.Has(slot.monitor)
                    && CurrentWorkspace[slot.monitor] = slot.workspace
            } else {
                committed := AdoptExternallyActivatedWorkspace(
                    hwnd, slot.monitor, slot.workspace)
            }
            DebugLog("EXTERNAL_ACTIVATION_SWITCH", "mode="
                (shielded ? "shielded-slide" : "instant-adopt")
                " committed=" committed " monitor=" slot.monitor
                " from=D" current " to=D" slot.workspace
                " source=" request.source " " DebugDescribeWindow(hwnd))
            if committed
                SetTimer(ActivateOverviewWindow.Bind(
                    hwnd, slot.monitor, slot.workspace, 0), -20)
        } catch as error {
            DebugLog("EXTERNAL_ACTIVATION_ERROR", "message=" DebugClean(error.Message)
                " trackedHwnd=" hwnd " source=" request.source)
        } finally {
            ExternalActivationHandling := false
        }
        break
    }
    if PendingExternalActivations.Count
        SetTimer(ProcessPendingExternalActivations, -1)
}

AdoptExternallyActivatedWorkspace(hwnd, monitor, workspace) {
    global CurrentWorkspace, RequestedWorkspace, WindowWorkspace, HiddenByScript
    global Switching, SwitchingMonitor, PendingWorkspaceSwitches, WorkspaceOverview

    if Switching || !CurrentWorkspace.Has(monitor)
        return false
    oldWorkspace := CurrentWorkspace[monitor]
    if oldWorkspace = workspace
        return true

    startedAt := A_TickCount
    Switching := true
    SwitchingMonitor := monitor
    try {
        if WorkspaceOverview
            CloseWorkspaceOverview(false)
        RememberWorkspaceWindowOrder(monitor, oldWorkspace)
        PromoteWorkspaceWindow(monitor, workspace, hwnd)
        InvalidateWorkspaceFrame(monitor, oldWorkspace)
        InvalidateWorkspaceFrame(monitor, workspace)

        hiddenOutgoing := 0
        requestedIncoming := 0
        for candidate, slot in WindowWorkspace.Clone() {
            if slot.monitor != monitor
                continue
            if !WinExist("ahk_id " candidate) {
                ForgetWindow(candidate)
                continue
            }
            if slot.workspace != workspace {
                if IsVisible(candidate) {
                    HideWindowFast(candidate)
                    HiddenByScript[candidate] := true
                    hiddenOutgoing += 1
                }
                continue
            }

            ; The taskbar-selected window is already the frame the user sees.
            ; Leave it completely untouched. Reveal workspace siblings behind
            ; it without waiting or replaying a slide.
            if candidate = hwnd && IsVisible(candidate) {
                if HiddenByScript.Has(candidate)
                    HiddenByScript.Delete(candidate)
                continue
            }
            if HiddenByScript.Has(candidate) {
                ShowWindowFast(candidate)
                requestedIncoming += 1
            }
        }

        CurrentWorkspace[monitor] := workspace
        RequestedWorkspace[monitor] := workspace
        RaiseWorkspacePriorityWindow(hwnd)
        ShowWorkspaceOverlay(monitor, workspace,
            workspace > oldWorkspace ? 1 : -1)
        ScheduleWorkspaceStateSave()
        SetTimer(FinalizeAdoptedWorkspace.Bind(
            hwnd, monitor, workspace, 0), -35)
        SetTimer(VerifyWorkspaceTransition.Bind(monitor, workspace, 0), -200)
        DebugLog("EXTERNAL_ADOPT_COMMIT", "monitor=" monitor
            " from=D" oldWorkspace " to=D" workspace
            " elapsedMs=" (A_TickCount - startedAt)
            " hiddenOutgoing=" hiddenOutgoing
            " requestedIncoming=" requestedIncoming
            " selected=" DebugDescribeWindow(hwnd))
        return true
    } finally {
        Switching := false
        SwitchingMonitor := 0
        if PendingWorkspaceSwitches.Count
            SetTimer(ProcessPendingWorkspaceSwitches, -1)
    }
}

FinalizeAdoptedWorkspace(hwnd, monitor, workspace, attempt := 0) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    if !CurrentWorkspace.Has(monitor) || CurrentWorkspace[monitor] != workspace
        return

    pending := 0
    for candidate, slot in WindowWorkspace.Clone() {
        if slot.monitor != monitor || slot.workspace != workspace
            continue
        if !WinExist("ahk_id " candidate) {
            ForgetWindow(candidate)
            continue
        }
        if IsVisible(candidate) {
            if HiddenByScript.Has(candidate)
                HiddenByScript.Delete(candidate)
        } else if HiddenByScript.Has(candidate) {
            ShowWindowFast(candidate)
            pending += 1
        }
    }
    RestoreWorkspaceWindowOrder(monitor, workspace)
    RaiseWorkspacePriorityWindow(hwnd)
    DebugLog("EXTERNAL_ADOPT_FINALIZE", "attempt=" attempt
        " monitor=" monitor " workspace=D" workspace
        " pending=" pending " selectedVisible=" IsVisible(hwnd))
    if pending && attempt < 5
        SetTimer(FinalizeAdoptedWorkspace.Bind(
            hwnd, monitor, workspace, attempt + 1), -50)
}

RaiseWorkspacePriorityWindow(hwnd) {
    if !hwnd || !WinExist("ahk_id " hwnd) || !IsVisible(hwnd)
        return false
    try return DllCall("SetWindowPos", "ptr", hwnd, "ptr", 0,
        "int", 0, "int", 0, "int", 0, "int", 0,
        "uint", 0x0013, "int") != 0 ; NOMOVE|NOSIZE|NOACTIVATE
    catch
        return false
}

ResolveTrackedWorkspaceWindow(hwnd) {
    global WindowWorkspace
    if !hwnd
        return 0
    if WindowWorkspace.Has(hwnd)
        return hwnd
    for ancestorMode in [2, 3] { ; GA_ROOT, GA_ROOTOWNER
        try ancestor := DllCall("GetAncestor", "ptr", hwnd, "uint", ancestorMode, "ptr")
        catch
            ancestor := 0
        if ancestor && WindowWorkspace.Has(ancestor)
            return ancestor
    }
    return 0
}

HandleOverviewEscape(*) {
    CloseWorkspaceOverview()
}

CloseWorkspaceOverview(restoreFocus := true, *) {
    global WorkspaceOverview, OverviewHotCornerCooldownUntil
    if !WorkspaceOverview
        return

    state := WorkspaceOverview
    DebugLog("OVERVIEW_CLOSE", "monitor=" state.monitor " restoreFocus=" restoreFocus
        " previousActive=" state.previousActive)
    WorkspaceOverview := false
    for thumbnail in state.thumbnails
        try DllCall("dwmapi\DwmUnregisterThumbnail", "ptr", thumbnail)
    try state.gui.Destroy()

    OverviewHotCornerCooldownUntil := A_TickCount + 900
    if restoreFocus && state.previousActive && WinExist("ahk_id " state.previousActive)
        try WinActivate("ahk_id " state.previousActive)
}

CheckWorkspaceOverviewHotCorner() {
    global WorkspaceOverview, OverviewHotCornerMonitor, OverviewHotCornerEnteredAt
    global OverviewHotCornerCooldownUntil

    if WorkspaceOverview {
        OverviewHotCornerMonitor := 0
        OverviewHotCornerEnteredAt := 0
        return
    }
    if A_TickCount < OverviewHotCornerCooldownUntil
        return

    point := Buffer(8, 0)
    if !DllCall("GetCursorPos", "ptr", point.Ptr)
        return
    x := NumGet(point, 0, "int")
    y := NumGet(point, 4, "int")
    monitor := GetMonitorUnderMouse()
    MonitorGet(monitor, &left, &top, &right, &bottom)
    threshold := Max(3, Round(4 * (GetMonitorDpi(monitor) / 96)))
    inCorner := x >= left && x <= left + threshold && y >= top && y <= top + threshold

    if !inCorner {
        OverviewHotCornerMonitor := 0
        OverviewHotCornerEnteredAt := 0
        return
    }

    if OverviewHotCornerMonitor != monitor {
        OverviewHotCornerMonitor := monitor
        OverviewHotCornerEnteredAt := A_TickCount
        return
    }

    if A_TickCount - OverviewHotCornerEnteredAt >= 500 {
        OverviewHotCornerMonitor := 0
        OverviewHotCornerEnteredAt := 0
        OverviewHotCornerCooldownUntil := A_TickCount + 1500
        ShowWorkspaceOverview(monitor)
    }
}

GetMonitorDpi(monitor) {
    MonitorGet(monitor, &left, &top, &right, &bottom)
    point := Buffer(8, 0)
    NumPut("int", left + 1, "int", top + 1, point, 0)
    hMonitor := DllCall("MonitorFromPoint", "int64", NumGet(point, 0, "int64"),
        "uint", 2, "ptr")
    dpiX := A_ScreenDPI
    dpiY := A_ScreenDPI
    try {
        if DllCall("Shcore\GetDpiForMonitor", "ptr", hMonitor, "int", 0,
            "uint*", &dpiX, "uint*", &dpiY, "int") != 0
            dpiX := A_ScreenDPI
    }
    return dpiX > 0 ? dpiX : A_ScreenDPI
}

EnablePerMonitorDpiAwareness() {
    previousContext := 0
    try previousContext := DllCall(
        "SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
    return previousContext
}

DebugDpiAwareness() {
    context := 0
    awareness := -1
    try context := DllCall("GetThreadDpiAwarenessContext", "ptr")
    if context
        try awareness := DllCall(
            "GetAwarenessFromDpiAwarenessContext", "ptr", context, "int")
    return "threadContext=" context " awareness=" awareness
        . " screenDpi=" A_ScreenDPI
}

CreatePhysicalPixelLayer() {
    ; AHK's process DPI mode can still let a newly-created GUI pass through a
    ; scaled intermediate size. Create the native HWND under per-monitor-v2 so
    ; every subsequent SetWindowPos value is interpreted as a physical pixel.
    previousContext := 0
    try previousContext := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
    try {
        layer := Gui("+AlwaysOnTop -Caption -Border +ToolWindow +E0x20 -DPIScale")
        ; Force HWND creation before restoring the caller's DPI context.
        layerHwnd := layer.Hwnd
    } finally {
        if previousContext
            try DllCall("SetThreadDpiAwarenessContext", "ptr", previousContext, "ptr")
    }
    layer.BackColor := "111827"
    layer.MarginX := 0
    layer.MarginY := 0
    return layer
}

DebugWindowRenderGeometry(hwnd) {
    clientRect := Buffer(16, 0)
    windowRect := Buffer(16, 0)
    if !DllCall("GetClientRect", "ptr", hwnd, "ptr", clientRect.Ptr)
        return "unavailable"
    clientWidth := NumGet(clientRect, 8, "int") - NumGet(clientRect, 0, "int")
    clientHeight := NumGet(clientRect, 12, "int") - NumGet(clientRect, 4, "int")
    windowDetails := "window=unavailable"
    if DllCall("GetWindowRect", "ptr", hwnd, "ptr", windowRect.Ptr) {
        windowDetails := "window=" NumGet(windowRect, 0, "int")
            . "," NumGet(windowRect, 4, "int")
            . "," NumGet(windowRect, 8, "int")
            . "," NumGet(windowRect, 12, "int")
    }
    try windowDpi := DllCall("GetDpiForWindow", "ptr", hwnd, "uint")
    catch
        windowDpi := 0
    return "client=" clientWidth "x" clientHeight " " windowDetails
        . " windowDpi=" windowDpi
}

SetupWorkspaceOverviewPreview(monitor) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global OverviewPreviewWindows, OverviewPreviewMode

    OverviewPreviewMode := true
    CurrentWorkspace[monitor] := 1
    colors := ["173B66", "4C1D95", "14532D", "7C2D12", "164E63", "713F12"]
    labels := ["Browser", "Notes", "Editor", "Terminal", "Calendar", "Files"]

    Loop 3 {
        workspace := A_Index
        Loop 2 {
            item := A_Index
            colorIndex := ((workspace - 1) * 2) + item
            source := Gui("+ToolWindow -DPIScale", "D" workspace " - " labels[colorIndex])
            source.BackColor := colors[colorIndex]
            source.MarginX := 0
            source.MarginY := 0
            source.SetFont("s24 cFFFFFF w600", "Segoe UI")
            source.AddText("x0 y0 w520 h300 Center +0x200 BackgroundTrans",
                "D" workspace "`n" labels[colorIndex])
            source.Show("x80 y80 w520 h300")
            WindowWorkspace[source.Hwnd] := {monitor: monitor, workspace: workspace}
            OverviewPreviewWindows.Push({gui: source, workspace: workspace, hwnd: source.Hwnd})
        }
    }

    SetTimer(LaunchWorkspaceOverviewPreview.Bind(monitor), -350)
    SetTimer((*) => ExitApp(), -8000)
}

LaunchWorkspaceOverviewPreview(monitor) {
    global OverviewPreviewWindows, HiddenByScript
    for item in OverviewPreviewWindows {
        if item.workspace = 1
            continue
        CaptureWindowSnapshot(item.hwnd)
        item.gui.Hide()
        HiddenByScript[item.hwnd] := true
    }
    ShowWorkspaceOverview(monitor)
}

SetupWorkspaceSlidePreview(monitor, rapidTest := false, handoffLoopTest := false) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global OverviewPreviewWindows, OverviewPreviewMode

    OverviewPreviewMode := true
    CurrentWorkspace[monitor] := 1
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    colors := ["173B66", "4C1D95", "14532D", "7C2D12"]
    labels := ["D1 Browser", "D1 Notes", "D2 Editor", "D2 Terminal"]

    Loop 4 {
        item := A_Index
        workspace := item <= 2 ? 1 : 2
        column := Mod(item - 1, 2)
        source := Gui("+ToolWindow -DPIScale", labels[item])
        source.BackColor := colors[item]
        source.MarginX := 0
        source.MarginY := 0
        source.SetFont("s24 cFFFFFF w600", "Segoe UI")
        source.AddText("x0 y0 w520 h300 Center +0x200 BackgroundTrans", labels[item])
        source.Show("x" (left + 120 + column * 600) " y" (top + 180)
            " w520 h300")
        WindowWorkspace[source.Hwnd] := {monitor: monitor, workspace: workspace}
        OverviewPreviewWindows.Push({gui: source, workspace: workspace, hwnd: source.Hwnd})
        if workspace = 2 {
            CaptureWindowSnapshot(source.Hwnd)
            source.Hide()
            HiddenByScript[source.Hwnd] := true
        }
    }

    if handoffLoopTest
        SetTimer(RunWorkspaceHandoffLoopPreview.Bind(monitor, 1), -300)
    else if rapidTest
        SetTimer(RunRapidWorkspaceSlidePreview.Bind(monitor), -450)
    else
        SetTimer(RunWorkspaceSlidePreview.Bind(monitor, 1), -450)
    SetTimer((*) => ExitApp(), handoffLoopTest ? -5200 : -2600)
}

RunWorkspaceSlidePreview(monitor, step) {
    if step = 1 {
        SwitchToWorkspaceOnMonitor(2, monitor, 1)
        SetTimer(RunWorkspaceSlidePreview.Bind(monitor, 2), -650)
    } else {
        SwitchToWorkspaceOnMonitor(1, monitor, -1)
    }
}

RunRapidWorkspaceSlidePreview(monitor) {
    ; These timers interrupt the active animation just like repeated hotkeys.
    SetTimer(SwitchToWorkspaceOnMonitor.Bind(3, monitor, 1), -80)
    SetTimer(SwitchToWorkspaceOnMonitor.Bind(1, monitor, 1), -140)
    SwitchToWorkspaceOnMonitor(2, monitor, 1)
}

RunWorkspaceHandoffLoopPreview(monitor, step) {
    if step > 8
        return
    targetWorkspace := Mod(step, 2) ? 2 : 1
    direction := targetWorkspace = 2 ? 1 : -1
    SwitchToWorkspaceOnMonitor(targetWorkspace, monitor, direction)
    SetTimer(RunWorkspaceHandoffLoopPreview.Bind(monitor, step + 1), -90)
}

SetupTaskbarActivationPreview(monitor) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global OverviewPreviewWindows, OverviewPreviewMode

    OverviewPreviewMode := true
    CurrentWorkspace[monitor] := 1
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    labels := ["D1 Codex", "D1 Browser", "D3 Editor"]
    colors := ["173B66", "4C1D95", "14532D"]
    workspaces := [1, 1, 3]

    Loop labels.Length {
        item := A_Index
        source := Gui("+ToolWindow -DPIScale", labels[item])
        source.BackColor := colors[item]
        source.MarginX := 0
        source.MarginY := 0
        source.SetFont("s24 cFFFFFF w600", "Segoe UI")
        source.AddText("x0 y0 w560 h330 Center +0x200 BackgroundTrans", labels[item])
        source.Show("x" (left + 180 + (item - 1) * 55)
            " y" (top + 200 + (item - 1) * 45) " w560 h330")
        workspace := workspaces[item]
        WindowWorkspace[source.Hwnd] := {monitor: monitor, workspace: workspace}
        OverviewPreviewWindows.Push({
            gui: source, workspace: workspace, hwnd: source.Hwnd, label: labels[item]
        })
        if workspace = 3 {
            CaptureWindowSnapshot(source.Hwnd)
            source.Hide()
            HiddenByScript[source.Hwnd] := true
        }
    }

    RegisterTaskbarClickHotkeys()
    InstallForegroundWinEventHook()
    SetTimer(CheckExternalWorkspaceActivation, 15)
    SetTimer(SwitchToWorkspaceOnMonitor.Bind(3, monitor, 1), -250)
    SetTimer(SimulateTaskbarWorkspaceActivation.Bind(monitor), -950)
    SetTimer((*) => ExitApp(), -2800)
}

SimulateTaskbarWorkspaceActivation(monitor) {
    global OverviewPreviewWindows
    BeginTaskbarActivationShield(monitor)
    for item in OverviewPreviewWindows {
        if item.label != "D1 Codex"
            continue
        DebugLog("TASKBAR_PREVIEW_CLICK", "monitor=" monitor
            " target=D1 " DebugDescribeWindow(item.hwnd))
        item.gui.Show()
        try WinActivate("ahk_id " item.hwnd)
        return
    }
}

LearnVisibleWindows() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global OverviewPreviewMode

    ; Regression previews own an isolated set of synthetic windows. Never pull
    ; the user's real applications into those temporary workspace assignments.
    if OverviewPreviewMode {
        DebugLog("WINDOW_SCAN_SKIP", "reason=preview-mode tracked=" WindowWorkspace.Count)
        return
    }

    learned := 0
    moved := 0
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
            learned += 1
            DebugLog("WINDOW_LEARN", "monitor=" monitor " workspace=D" CurrentWorkspace[monitor]
                " " DebugDescribeWindow(hwnd))
            continue
        }

        ; A visible window dragged to another monitor joins the workspace that is
        ; currently displayed there.
        slot := WindowWorkspace[hwnd]
        if slot.monitor != monitor {
            oldMonitor := slot.monitor
            oldWorkspace := slot.workspace
            WindowWorkspace[hwnd] := {
                monitor: monitor,
                workspace: CurrentWorkspace[monitor]
            }
            PromoteWorkspaceWindow(monitor, CurrentWorkspace[monitor], hwnd)
            moved += 1
            DebugLog("WINDOW_MONITOR_MOVE", "fromMonitor=" oldMonitor
                " fromWorkspace=D" oldWorkspace " toMonitor=" monitor
                " toWorkspace=D" CurrentWorkspace[monitor] " " DebugDescribeWindow(hwnd))
        }
    }
    DebugLog("WINDOW_SCAN_END", "learned=" learned " moved=" moved
        " tracked=" WindowWorkspace.Count " scriptHidden=" HiddenByScript.Count)
    if learned || moved
        ScheduleWorkspaceStateSave()
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
        "EdgeUiInputTopWndClass", true,
        "XamlExplorerHostIslandWindow_WASDK", true,
        "RaycastUIAccessHelper", true,
        "RaycastNodeGracefulShutdownClass", true,
        "AutoHotkeyGUI", true
    )
    if ignoredClasses.Has(class)
        return false

    ; Windows Widgets exposes a browser-class helper window, but it is a shell
    ; surface rather than a workspace app.
    try processName := WinGetProcessName("ahk_id " hwnd)
    catch
        processName := ""
    try title := WinGetTitle("ahk_id " hwnd)
    catch
        title := ""
    if StrLower(processName) = "msedgewebview2.exe" && title = "Widgets"
        return false
    if StrLower(processName) = "raycast.exe"
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
    try {
        result := DllCall("ShowWindowAsync", "ptr", hwnd, "int", 0)
        DebugLog("WINDOW_HIDE_ASYNC", "result=" result " " DebugDescribeWindow(hwnd))
        return result
    } catch as error {
        DebugLog("WINDOW_HIDE_ERROR", "message=" DebugClean(error.Message) " " DebugDescribeWindow(hwnd))
        return false
    }
}

ShowWindowFast(hwnd) {
    ; SW_SHOWNA = 8: show without activation or restoring minimized windows.
    try {
        result := DllCall("ShowWindowAsync", "ptr", hwnd, "int", 8)
        DebugLog("WINDOW_SHOW_ASYNC", "result=" result " " DebugDescribeWindow(hwnd))
        return result
    } catch as error {
        DebugLog("WINDOW_SHOW_ERROR", "message=" DebugClean(error.Message) " " DebugDescribeWindow(hwnd))
        return false
    }
}

WorkspaceWindowOrderKey(monitor, workspace) {
    return monitor ":" workspace
}

RememberWorkspaceWindowOrder(monitor, workspace) {
    global WindowWorkspace, HiddenByScript, WorkspaceWindowOrders
    key := WorkspaceWindowOrderKey(monitor, workspace)
    visibleOrder := []
    allInWindowsOrder := []
    total := 0
    for hwnd in WinGetList() {
        if !WindowWorkspace.Has(hwnd)
            continue
        slot := WindowWorkspace[hwnd]
        if slot.monitor != monitor || slot.workspace != workspace
            continue
        total += 1
        allInWindowsOrder.Push(hwnd)
        if IsVisible(hwnd) && !HiddenByScript.Has(hwnd)
            visibleOrder.Push(hwnd)
    }

    ; An incomplete handoff must not overwrite a complete saved stack with only
    ; the first application that happened to respond. Keep the prior order and
    ; append genuinely new handles until every assigned window is visible.
    order := []
    included := Map()
    if visibleOrder.Length < total && WorkspaceWindowOrders.Has(key) {
        for hwnd in WorkspaceWindowOrders[key] {
            if !WindowWorkspace.Has(hwnd)
                continue
            slot := WindowWorkspace[hwnd]
            if slot.monitor = monitor && slot.workspace = workspace {
                order.Push(hwnd)
                included[hwnd] := true
            }
        }
    } else {
        for hwnd in visibleOrder {
            order.Push(hwnd)
            included[hwnd] := true
        }
    }
    for hwnd in allInWindowsOrder {
        if !included.Has(hwnd)
            order.Push(hwnd)
    }

    if order.Length
        WorkspaceWindowOrders[key] := order
    else if WorkspaceWindowOrders.Has(key)
        WorkspaceWindowOrders.Delete(key)
    DebugLog("STACK_REMEMBER", "monitor=" monitor " workspace=D" workspace
        " visible=" visibleOrder.Length " total=" total
        " order=" DebugWindowOrder(order))
    return order
}

GetWorkspaceWindowOrder(monitor, workspace) {
    global WindowWorkspace, WorkspaceWindowOrders
    key := WorkspaceWindowOrderKey(monitor, workspace)
    saved := WorkspaceWindowOrders.Has(key) ? WorkspaceWindowOrders[key] : []
    order := []
    included := Map()

    ; First retain the remembered top-to-bottom stack, discarding stale or
    ; reassigned handles. Then append newly discovered windows in their current
    ; Windows Z-order so they are never omitted from the restored group.
    for hwnd in saved {
        if !WinExist("ahk_id " hwnd) || !WindowWorkspace.Has(hwnd)
            continue
        slot := WindowWorkspace[hwnd]
        if slot.monitor != monitor || slot.workspace != workspace
            continue
        order.Push(hwnd)
        included[hwnd] := true
    }
    for hwnd in WinGetList() {
        if included.Has(hwnd) || !WindowWorkspace.Has(hwnd)
            continue
        slot := WindowWorkspace[hwnd]
        if slot.monitor = monitor && slot.workspace = workspace {
            order.Push(hwnd)
            included[hwnd] := true
        }
    }
    WorkspaceWindowOrders[key] := order
    return order
}

RestoreWorkspaceWindowOrder(monitor, workspace) {
    order := GetWorkspaceWindowOrder(monitor, workspace)
    restored := 0

    ; The saved array is top-to-bottom. Raising it in reverse reconstructs that
    ; ordering without activating or moving any application window.
    Loop order.Length {
        hwnd := order[order.Length - A_Index + 1]
        if !WinExist("ahk_id " hwnd) || !IsVisible(hwnd)
            continue
        try {
            result := DllCall("SetWindowPos", "ptr", hwnd, "ptr", 0,
                "int", 0, "int", 0, "int", 0, "int", 0,
                "uint", 0x0013, "int") ; NOMOVE|NOSIZE|NOACTIVATE
            restored += result ? 1 : 0
        }
    }
    DebugLog("STACK_RESTORE", "monitor=" monitor " workspace=D" workspace
        " requested=" order.Length " restored=" restored
        " order=" DebugWindowOrder(order))
    return restored
}

RevealWorkspaceForHandoff(monitor, workspace, timeoutMs := 260) {
    global WindowWorkspace, HiddenByScript
    expected := []
    showStartedAt := A_TickCount

    for hwnd, slot in WindowWorkspace.Clone() {
        if slot.monitor != monitor || slot.workspace != workspace
            continue
        if !WinExist("ahk_id " hwnd) {
            ForgetWindow(hwnd)
            continue
        }
        if HiddenByScript.Has(hwnd) {
            expected.Push(hwnd)
            DebugLog("SWITCH_SHOW", "target=D" workspace " " DebugDescribeWindow(hwnd))
            ShowWindowFast(hwnd)
        } else {
            DebugLog("SWITCH_KEEP", "target=D" workspace " already-not-script-hidden "
                DebugDescribeWindow(hwnd))
        }
    }

    DebugLog("HANDOFF_BEGIN", "monitor=" monitor " workspace=D" workspace
        " expected=" expected.Length " timeoutMs=" timeoutMs)
    pending := []
    retryAt := 48
    loop {
        pending := []
        for hwnd in expected {
            if !WinExist("ahk_id " hwnd)
                continue
            if IsVisible(hwnd) {
                if HiddenByScript.Has(hwnd)
                    HiddenByScript.Delete(hwnd)
            } else
                pending.Push(hwnd)
        }
        elapsed := A_TickCount - showStartedAt
        if !pending.Length || elapsed >= timeoutMs
            break
        if elapsed >= retryAt {
            DebugLog("HANDOFF_RETRY", "monitor=" monitor " workspace=D" workspace
                " elapsedMs=" elapsed " pending=" pending.Length
                " windows=" DebugWindowOrder(pending))
            for hwnd in pending
                ShowWindowFast(hwnd)
            retryAt += 64
        }
        Sleep(8)
    }

    RestoreWorkspaceWindowOrder(monitor, workspace)
    ; IsWindowVisible changes before every compositor surface is necessarily on
    ; screen. Two DWM presentation boundaries make the cover removal atomic to
    ; the user's eye while adding only one or two refresh intervals.
    try DllCall("dwmapi\DwmFlush")
    try DllCall("dwmapi\DwmFlush")
    elapsed := A_TickCount - showStartedAt
    DebugLog("HANDOFF_COMPLETE", "monitor=" monitor " workspace=D" workspace
        " elapsedMs=" elapsed " expected=" expected.Length
        " visible=" (expected.Length - pending.Length)
        " pending=" pending.Length " windows=" DebugWindowOrder(pending))
    return pending.Length = 0
}

RemoveWindowFromWorkspaceOrders(hwnd) {
    global WorkspaceWindowOrders
    for key, order in WorkspaceWindowOrders.Clone() {
        filtered := []
        for savedHwnd in order {
            if savedHwnd != hwnd
                filtered.Push(savedHwnd)
        }
        if filtered.Length
            WorkspaceWindowOrders[key] := filtered
        else
            WorkspaceWindowOrders.Delete(key)
    }
}

PromoteWorkspaceWindow(monitor, workspace, hwnd) {
    global WorkspaceWindowOrders
    RemoveWindowFromWorkspaceOrders(hwnd)
    key := WorkspaceWindowOrderKey(monitor, workspace)
    order := WorkspaceWindowOrders.Has(key) ? WorkspaceWindowOrders[key] : []
    order.InsertAt(1, hwnd)
    WorkspaceWindowOrders[key] := order
    DebugLog("STACK_PROMOTE", "monitor=" monitor " workspace=D" workspace
        " hwnd=" hwnd " order=" DebugWindowOrder(order))
}

DebugWindowOrder(order) {
    value := ""
    for hwnd in order
        value .= (value ? "," : "") hwnd
    return value ? value : "none"
}

CaptureWindowSnapshot(hwnd) {
    global WindowSnapshots
    if !WinExist("ahk_id " hwnd)
        return false

    windowRect := Buffer(16, 0)
    if !DllCall("GetWindowRect", "ptr", hwnd, "ptr", windowRect.Ptr)
        return false
    left := NumGet(windowRect, 0, "int")
    top := NumGet(windowRect, 4, "int")
    width := NumGet(windowRect, 8, "int") - left
    height := NumGet(windowRect, 12, "int") - top
    if width <= 0 || height <= 0
        return false

    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    memoryDc := DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr")
    bitmap := DllCall("CreateCompatibleBitmap", "ptr", screenDc,
        "int", width, "int", height, "ptr")
    if !screenDc || !memoryDc || !bitmap {
        if bitmap
            DllCall("DeleteObject", "ptr", bitmap)
        if memoryDc
            DllCall("DeleteDC", "ptr", memoryDc)
        if screenDc
            DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
        return false
    }

    oldBitmap := DllCall("SelectObject", "ptr", memoryDc, "ptr", bitmap, "ptr")
    captured := false
    try captured := DllCall("PrintWindow", "ptr", hwnd, "ptr", memoryDc, "uint", 2, "int") != 0
    if !captured {
        captured := DllCall("BitBlt", "ptr", memoryDc,
            "int", 0, "int", 0, "int", width, "int", height,
            "ptr", screenDc, "int", left, "int", top, "uint", 0x00CC0020, "int") != 0
    }

    sourceRestored := false
    if captured && Max(width, height) > 1280 {
        resizeScale := 1280 / Max(width, height)
        resizedWidth := Max(1, Round(width * resizeScale))
        resizedHeight := Max(1, Round(height * resizeScale))
        resizedDc := DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr")
        resizedBitmap := DllCall("CreateCompatibleBitmap", "ptr", screenDc,
            "int", resizedWidth, "int", resizedHeight, "ptr")
        if resizedDc && resizedBitmap {
            oldResizedBitmap := DllCall("SelectObject", "ptr", resizedDc, "ptr", resizedBitmap, "ptr")
            DllCall("SetStretchBltMode", "ptr", resizedDc, "int", 4)
            resized := DllCall("StretchBlt",
                "ptr", resizedDc, "int", 0, "int", 0, "int", resizedWidth, "int", resizedHeight,
                "ptr", memoryDc, "int", 0, "int", 0, "int", width, "int", height,
                "uint", 0x00CC0020, "int") != 0
            DllCall("SelectObject", "ptr", resizedDc, "ptr", oldResizedBitmap)
            if resized {
                DllCall("SelectObject", "ptr", memoryDc, "ptr", oldBitmap)
                sourceRestored := true
                DllCall("DeleteObject", "ptr", bitmap)
                bitmap := resizedBitmap
                width := resizedWidth
                height := resizedHeight
            } else {
                DllCall("DeleteObject", "ptr", resizedBitmap)
            }
        }
        if resizedDc
            DllCall("DeleteDC", "ptr", resizedDc)
    }

    if !sourceRestored
        DllCall("SelectObject", "ptr", memoryDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", memoryDc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)

    if !captured {
        DllCall("DeleteObject", "ptr", bitmap)
        return false
    }

    DeleteWindowSnapshot(hwnd)
    WindowSnapshots[hwnd] := {bitmap: bitmap, width: width, height: height}
    return true
}

DeleteWindowSnapshot(hwnd) {
    global WindowSnapshots
    if !WindowSnapshots.Has(hwnd)
        return
    snapshot := WindowSnapshots[hwnd]
    if snapshot.bitmap
        try DllCall("DeleteObject", "ptr", snapshot.bitmap)
    WindowSnapshots.Delete(hwnd)
}

ClearWindowSnapshots() {
    global WindowSnapshots
    for hwnd in WindowSnapshots.Clone()
        DeleteWindowSnapshot(hwnd)
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
    global CurrentWorkspace, RequestedWorkspace
    Loop MonitorGetCount() {
        if !CurrentWorkspace.Has(A_Index)
            CurrentWorkspace[A_Index] := 1
        if !RequestedWorkspace.Has(A_Index)
            RequestedWorkspace[A_Index] := CurrentWorkspace[A_Index]
    }
}

SyncRequestedWorkspaces() {
    global CurrentWorkspace, RequestedWorkspace
    RequestedWorkspace.Clear()
    Loop MonitorGetCount()
        RequestedWorkspace[A_Index] := CurrentWorkspace.Has(A_Index)
            ? CurrentWorkspace[A_Index] : 1
}

ProcessPendingWorkspaceSwitches(*) {
    global Switching, PendingWorkspaceSwitches, WorkspaceRestartScheduled
    if Switching || WorkspaceRestartScheduled || !PendingWorkspaceSwitches.Count
        return
    for monitor, request in PendingWorkspaceSwitches.Clone() {
        PendingWorkspaceSwitches.Delete(monitor)
        DebugLog("SWITCH_QUEUE_PROCESS", "target=D" request.workspace
            " monitor=" monitor " direction=" request.direction
            " rapid=" request.rapid
            " remainingMonitors=" PendingWorkspaceSwitches.Count)
        SwitchToWorkspaceOnMonitor(
            request.workspace, monitor, request.direction, request.rapid)
        break
    }
    if PendingWorkspaceSwitches.Count
        SetTimer(ProcessPendingWorkspaceSwitches, -1)
}

MarkWorkspaceSwitchProgress(stage) {
    global SwitchingLastProgressAt, SwitchingMonitor, SwitchingTargetWorkspace
    SwitchingLastProgressAt := A_TickCount
    DebugLog("SWITCH_PROGRESS", "stage=" stage " monitor=" SwitchingMonitor
        " target=D" SwitchingTargetWorkspace)
}

CheckWorkspaceEngineHealth(*) {
    global Switching, SwitchingMonitor, SwitchingStartedAt, SwitchingLastProgressAt
    global SwitchingTargetWorkspace, SwitchingDirection, SwitchingSoftRecoveryRequested
    global WORKSPACE_WATCHDOG_SOFT_MS, WORKSPACE_WATCHDOG_RESTART_MS
    global PendingWorkspaceSwitches, RequestedWorkspace, WorkspaceSlideSkipRequests
    global WorkspaceRestartScheduled

    if WorkspaceRestartScheduled
        return
    if !Switching {
        if SwitchingStartedAt || SwitchingLastProgressAt {
            DebugLog("WATCHDOG_STATE_REPAIR", "reason=orphan-timestamps")
            SwitchingStartedAt := 0
            SwitchingLastProgressAt := 0
        }
        return
    }

    now := A_TickCount
    elapsed := SwitchingStartedAt ? now - SwitchingStartedAt : 0
    idle := SwitchingLastProgressAt ? now - SwitchingLastProgressAt : elapsed
    if !SwitchingSoftRecoveryRequested && idle >= WORKSPACE_WATCHDOG_SOFT_MS {
        SwitchingSoftRecoveryRequested := true
        if SwitchingMonitor {
            WorkspaceSlideSkipRequests[SwitchingMonitor] := true
            RequestedWorkspace[SwitchingMonitor] := SwitchingTargetWorkspace
            PendingWorkspaceSwitches[SwitchingMonitor] := {
                workspace: SwitchingTargetWorkspace,
                direction: SwitchingDirection,
                rapid: true
            }
        }
        DebugLog("WATCHDOG_SOFT_RECOVERY", "monitor=" SwitchingMonitor
            " target=D" SwitchingTargetWorkspace " elapsedMs=" elapsed
            " idleMs=" idle " action=finish-and-retry")
    }

    if elapsed >= WORKSPACE_WATCHDOG_RESTART_MS {
        DebugLog("WATCHDOG_HARD_RECOVERY", "monitor=" SwitchingMonitor
            " target=D" SwitchingTargetWorkspace " elapsedMs=" elapsed
            " idleMs=" idle " action=restart-and-resume")
        ScheduleWorkspaceEngineRestart("stalled-switch", SwitchingMonitor,
            SwitchingTargetWorkspace, SwitchingDirection)
    }
}

RestartWorkspaceEngine(*) {
    ScheduleWorkspaceEngineRestart("manual")
}

ScheduleWorkspaceEngineRestart(reason, monitor := 0, workspace := 0, direction := 0) {
    global WorkspaceRestartScheduled, WorkspaceRestartPreviewMode
    global WorkspaceStatePersistenceEnabled, Switching
    if WorkspaceRestartScheduled
        return false
    WorkspaceRestartScheduled := true

    if WorkspaceRestartPreviewMode {
        DebugLog("ENGINE_RESTART_PREVIEW", "reason=" reason " monitor=" monitor
            " workspace=" workspace " direction=" direction)
        return true
    }

    if !Switching
        try SaveWorkspaceState()
    if monitor && workspace
        WriteWorkspaceRecoveryRequest(monitor, workspace, direction, reason)
    ; A stalled transition may have partially hidden windows. Do not overwrite
    ; the last known-good state during OnExit; it will reveal all windows, then
    ; the new process will reapply that state and replay the pending request.
    WorkspaceStatePersistenceEnabled := false
    DebugLog("ENGINE_RESTART_SCHEDULE", "reason=" reason " monitor=" monitor
        " workspace=" workspace " direction=" direction " delayMs=80")
    SetTimer(PerformWorkspaceEngineRestart.Bind(reason), -80)
    return true
}

PerformWorkspaceEngineRestart(reason) {
    DebugLog("ENGINE_RESTART", "reason=" reason)
    Reload()
}

WriteWorkspaceRecoveryRequest(monitor, workspace, direction, reason) {
    global WORKSPACE_RECOVERY_PATH
    try {
        SplitPath(WORKSPACE_RECOVERY_PATH,, &recoveryDirectory)
        DirCreate(recoveryDirectory)
        if FileExist(WORKSPACE_RECOVERY_PATH)
            FileDelete(WORKSPACE_RECOVERY_PATH)
        FileAppend(MonitorGetName(monitor) "`t" workspace "`t" direction
            "`t" reason, WORKSPACE_RECOVERY_PATH, "UTF-8")
        DebugLog("RECOVERY_REQUEST_SAVE", "monitor=" monitor " target=D" workspace
            " direction=" direction " reason=" reason)
        return true
    } catch as error {
        DebugLog("RECOVERY_REQUEST_ERROR", "action=save message="
            DebugClean(error.Message))
        return false
    }
}

ResumePendingWorkspaceRecovery() {
    global WORKSPACE_RECOVERY_PATH, WORKSPACE_COUNT
    if !FileExist(WORKSPACE_RECOVERY_PATH)
        return false
    try {
        contents := Trim(FileRead(WORKSPACE_RECOVERY_PATH, "UTF-8"))
        FileDelete(WORKSPACE_RECOVERY_PATH)
        fields := StrSplit(contents, "`t")
        if fields.Length < 3
            throw Error("Recovery request is incomplete")
        deviceName := fields[1]
        workspace := Integer(fields[2])
        direction := Integer(fields[3])
        if workspace < 1 || workspace > WORKSPACE_COUNT
            throw Error("Recovery workspace is invalid")
        monitor := 0
        Loop MonitorGetCount() {
            if StrLower(MonitorGetName(A_Index)) = StrLower(deviceName) {
                monitor := A_Index
                break
            }
        }
        if !monitor
            throw Error("Recovery monitor is no longer connected")
        DebugLog("RECOVERY_REQUEST_RESUME", "monitor=" monitor
            " target=D" workspace " direction=" direction " delayMs=350")
        SetTimer(SwitchToWorkspaceOnMonitor.Bind(
            workspace, monitor, direction, true), -350)
        return true
    } catch as error {
        try {
            if FileExist(WORKSPACE_RECOVERY_PATH)
                FileDelete(WORKSPACE_RECOVERY_PATH)
        }
        DebugLog("RECOVERY_REQUEST_ERROR", "action=resume message="
            DebugClean(error.Message))
        return false
    }
}

ForgetWindow(hwnd) {
    global WindowWorkspace, HiddenByScript
    if WindowWorkspace.Has(hwnd) {
        slot := WindowWorkspace[hwnd]
        InvalidateWorkspaceFrame(slot.monitor, slot.workspace)
        WindowWorkspace.Delete(hwnd)
    }
    if HiddenByScript.Has(hwnd)
        HiddenByScript.Delete(hwnd)
    RemoveWindowFromWorkspaceOrders(hwnd)
    DeleteWindowSnapshot(hwnd)
}

HandleDisplayChange(*) {
    ; Windows broadcasts WM_DISPLAYCHANGE after monitor connect/disconnect,
    ; resolution changes, docking, and topology changes. Debounce the reset.
    DebugLog("DISPLAY_CHANGE", "debounceMs=750")
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
    DebugLog("RESTORE_ALL_BEGIN", "count=" HiddenByScript.Count)
    for hwnd in HiddenByScript.Clone() {
        if WinExist("ahk_id " hwnd) {
            DebugLog("RESTORE_ALL_WINDOW", DebugDescribeWindow(hwnd))
            ShowWindowFast(hwnd)
        }
    }
    HiddenByScript.Clear()
    DebugLog("RESTORE_ALL_END", "count=0")
}

HandleAppExit(*) {
    DebugLog("APP_EXIT", "begin")
    RemoveForegroundWinEventHook()
    ClearTaskbarActivationShields("app-exit")
    SaveWorkspaceState()
    CloseWorkspaceOverview(false)
    RestoreAllWindows()
    ClearWindowSnapshots()
    ClearWorkspaceFrames()
    DebugLog("APP_EXIT", "complete")
}

ResetAndRevealAll(*) {
    global CurrentWorkspace, WindowWorkspace, RequestedWorkspace
    global PendingWorkspaceSwitches, WorkspaceSlideSkipRequests
    global WorkspaceWindowOrders, PendingExternalActivations
    DebugLog("RESET", "begin")
    ClearTaskbarActivationShields("reset")
    CloseWorkspaceOverview(false)
    RestoreAllWindows()
    WindowWorkspace.Clear()
    WorkspaceWindowOrders.Clear()
    ClearWindowSnapshots()
    ClearWorkspaceFrames()
    CurrentWorkspace.Clear()
    RequestedWorkspace.Clear()
    PendingWorkspaceSwitches.Clear()
    WorkspaceSlideSkipRequests.Clear()
    PendingExternalActivations.Clear()
    InitializeMonitors()
    SyncRequestedWorkspaces()
    SaveWorkspaceState()
    ShowFeedbackForMonitor(GetMonitorUnderMouse(), 1, "Reset to")
    DebugLog("RESET", "complete")
}

BeginWorkspaceSlideAnimation(monitor, oldWorkspace, newWorkspace, direction, duration := 0) {
    global WORKSPACE_SLIDE_MS, WorkspaceSlideAnimations
    if !duration
        duration := WORKSPACE_SLIDE_MS

    preparationStarted := A_TickCount
    CancelWorkspaceOverlay(monitor)
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    width := right - left
    height := bottom - top
    RefreshWorkspaceWindowSnapshots(monitor, oldWorkspace)
    outgoingCaptureStarted := A_TickCount
    outgoingFrame := CaptureMonitorWorkspaceFrame(monitor, oldWorkspace)
    outgoingCaptureMs := A_TickCount - outgoingCaptureStarted
    if !outgoingFrame
        outgoingFrame := BuildWorkspaceFrameFromSnapshots(monitor, oldWorkspace)
    incomingWasCached := GetWorkspaceFrame(monitor, newWorkspace) != false
    incomingStarted := A_TickCount
    incomingFrame := GetWorkspaceFrame(monitor, newWorkspace)
    if !incomingFrame
        incomingFrame := BuildWorkspaceFrameFromSnapshots(monitor, newWorkspace)
    incomingPreparationMs := A_TickCount - incomingStarted
    if !outgoingFrame || !incomingFrame {
        DebugLog("SLIDE_SKIP", "reason=frame-capture-failed monitor=" monitor
            " from=D" oldWorkspace " to=D" newWorkspace)
        return false
    }

    layer := CreatePhysicalPixelLayer()
    state := {
        gui: layer, hwnd: 0, monitor: monitor,
        left: left, top: top, width: width, height: height,
        oldWorkspace: oldWorkspace, newWorkspace: newWorkspace,
        direction: direction, duration: duration,
        outgoingFrame: outgoingFrame, incomingFrame: incomingFrame,
        outgoingOffset: 0, incomingOffset: direction * width,
        bufferDc: 0, bufferBitmap: 0, oldBufferBitmap: 0, sourceDc: 0
    }

    state.hwnd := layer.Hwnd
    ; Size the still-hidden layer in physical pixels. Never use Gui.Show here:
    ; it can present a DPI-scaled intermediate frame before SetWindowPos fixes
    ; the dimensions, which looks like a zoom immediately before the slide.
    try DllCall("SetWindowPos", "ptr", state.hwnd, "ptr", -1,
        "int", left, "int", top, "int", width, "int", height,
        "uint", 0x0010)
    if !InitializeWorkspaceSlideBackBuffer(state) {
        try layer.Destroy()
        DebugLog("SLIDE_SKIP", "reason=back-buffer-failed monitor=" monitor
            " resolution=" width "x" height " dpi=" GetMonitorDpi(monitor))
        return false
    }
    WorkspaceSlideAnimations[state.hwnd] := state
    try DllCall("SetWindowPos", "ptr", state.hwnd, "ptr", -1,
        "int", left, "int", top, "int", width, "int", height,
        "uint", 0x0050)
    RenderWorkspaceSlideFrame(state)
    try DllCall("dwmapi\DwmFlush")
    DebugLog("SLIDE_BEGIN", "monitor=" monitor " from=D" oldWorkspace
        " to=D" newWorkspace " direction=" direction
        " mode=double-buffered-bitblt durationMs=" state.duration
        " resolution=" width "x" height " dpi=" GetMonitorDpi(monitor)
        " geometry=" DebugWindowRenderGeometry(state.hwnd)
        " outgoingCaptureMs=" outgoingCaptureMs
        " incomingCached=" incomingWasCached
        " incomingPreparationMs=" incomingPreparationMs
        " totalPreparationMs=" (A_TickCount - preparationStarted))
    return state
}

RefreshWorkspaceWindowSnapshots(monitor, workspace) {
    windows := GetOverviewWindows(monitor, workspace)
    for hwnd in windows {
        if !WinExist("ahk_id " hwnd)
            continue
        try minimized := WinGetMinMax("ahk_id " hwnd) = -1
        catch
            minimized := false
        if !minimized
            CaptureWindowSnapshot(hwnd)
    }
}

CaptureMonitorWorkspaceFrame(monitor, workspace) {
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    width := right - left
    height := bottom - top
    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    memoryDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
    bitmap := screenDc ? DllCall("CreateCompatibleBitmap", "ptr", screenDc,
        "int", width, "int", height, "ptr") : 0
    if !screenDc || !memoryDc || !bitmap {
        if bitmap
            DllCall("DeleteObject", "ptr", bitmap)
        if memoryDc
            DllCall("DeleteDC", "ptr", memoryDc)
        if screenDc
            DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
        return false
    }

    oldBitmap := DllCall("SelectObject", "ptr", memoryDc, "ptr", bitmap, "ptr")
    captured := DllCall("BitBlt", "ptr", memoryDc,
        "int", 0, "int", 0, "int", width, "int", height,
        "ptr", screenDc, "int", left, "int", top, "uint", 0x00CC0020, "int") != 0
    DllCall("SelectObject", "ptr", memoryDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", memoryDc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
    if !captured {
        DllCall("DeleteObject", "ptr", bitmap)
        return false
    }
    return StoreWorkspaceFrame(monitor, workspace,
        {bitmap: bitmap, width: width, height: height})
}

BuildWorkspaceFrameFromSnapshots(monitor, workspace) {
    global WindowSnapshots, OverviewPreviewMode
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    width := right - left
    height := bottom - top
    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    memoryDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
    bitmap := screenDc ? DllCall("CreateCompatibleBitmap", "ptr", screenDc,
        "int", width, "int", height, "ptr") : 0
    if !screenDc || !memoryDc || !bitmap {
        if bitmap
            DllCall("DeleteObject", "ptr", bitmap)
        if memoryDc
            DllCall("DeleteDC", "ptr", memoryDc)
        if screenDc
            DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
        return false
    }

    oldBitmap := DllCall("SelectObject", "ptr", memoryDc, "ptr", bitmap, "ptr")
    backgroundRect := Buffer(16, 0)
    NumPut("int", 0, "int", 0, "int", width, "int", height, backgroundRect, 0)
    backgroundBrush := DllCall("CreateSolidBrush", "uint", 0x271811, "ptr")
    DllCall("FillRect", "ptr", memoryDc, "ptr", backgroundRect.Ptr, "ptr", backgroundBrush)
    DllCall("DeleteObject", "ptr", backgroundBrush)

    windows := GetOverviewWindows(monitor, workspace)
    drawn := 0
    Loop windows.Length {
        hwnd := windows[windows.Length - A_Index + 1]
        if !WinExist("ahk_id " hwnd)
            continue
        if !OverviewPreviewMode && !IsManageableWindow(hwnd)
            continue
        try minimized := WinGetMinMax("ahk_id " hwnd) = -1
        catch
            minimized := false
        if minimized
            continue
        if !WindowSnapshots.Has(hwnd)
            CaptureWindowSnapshot(hwnd)
        if !WindowSnapshots.Has(hwnd)
            continue
        rect := Buffer(16, 0)
        if !DllCall("GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
            continue
        windowLeft := NumGet(rect, 0, "int")
        windowTop := NumGet(rect, 4, "int")
        windowWidth := NumGet(rect, 8, "int") - windowLeft
        windowHeight := NumGet(rect, 12, "int") - windowTop
        if windowWidth <= 0 || windowHeight <= 0
            continue
        DrawOverviewSnapshot(memoryDc, WindowSnapshots[hwnd], {
            x: windowLeft - left, y: windowTop - top,
            w: windowWidth, h: windowHeight
        })
        drawn += 1
    }

    DllCall("SelectObject", "ptr", memoryDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", memoryDc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
    DebugLog("SLIDE_FRAME_BUILD", "monitor=" monitor " workspace=D" workspace
        " windows=" drawn " background=opaque")
    return StoreWorkspaceFrame(monitor, workspace,
        {bitmap: bitmap, width: width, height: height})
}

GetWorkspaceFrame(monitor, workspace) {
    global WorkspaceFrames
    key := monitor ":" workspace
    return WorkspaceFrames.Has(key) ? WorkspaceFrames[key] : false
}

StoreWorkspaceFrame(monitor, workspace, frame) {
    global WorkspaceFrames
    key := monitor ":" workspace
    if WorkspaceFrames.Has(key) {
        previous := WorkspaceFrames[key]
        if previous.bitmap && previous.bitmap != frame.bitmap
            try DllCall("DeleteObject", "ptr", previous.bitmap)
    }
    WorkspaceFrames[key] := frame
    return frame
}

InvalidateWorkspaceFrame(monitor, workspace) {
    global WorkspaceFrames, DeferredWorkspaceFrameDeletes, Switching
    key := monitor ":" workspace
    if !WorkspaceFrames.Has(key)
        return
    frame := WorkspaceFrames[key]
    WorkspaceFrames.Delete(key)
    if frame.bitmap {
        if Switching
            DeferredWorkspaceFrameDeletes.Push(frame.bitmap)
        else
            try DllCall("DeleteObject", "ptr", frame.bitmap)
    }
    DebugLog("SLIDE_FRAME_INVALIDATE", "monitor=" monitor " workspace=D" workspace)
}

ClearWorkspaceFrames() {
    global WorkspaceFrames, DeferredWorkspaceFrameDeletes
    for key, frame in WorkspaceFrames.Clone() {
        if frame.bitmap
            try DllCall("DeleteObject", "ptr", frame.bitmap)
    }
    WorkspaceFrames.Clear()
    for bitmap in DeferredWorkspaceFrameDeletes {
        if bitmap
            try DllCall("DeleteObject", "ptr", bitmap)
    }
    DeferredWorkspaceFrameDeletes := []
}

FlushDeferredWorkspaceFrameDeletes() {
    global DeferredWorkspaceFrameDeletes
    for bitmap in DeferredWorkspaceFrameDeletes {
        if bitmap
            try DllCall("DeleteObject", "ptr", bitmap)
    }
    DeferredWorkspaceFrameDeletes := []
}

InitializeWorkspaceSlideBackBuffer(state) {
    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    if !screenDc
        return false
    state.bufferDc := DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr")
    state.sourceDc := DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr")
    state.bufferBitmap := DllCall("CreateCompatibleBitmap", "ptr", screenDc,
        "int", state.width, "int", state.height, "ptr")
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
    if !state.bufferDc || !state.sourceDc || !state.bufferBitmap {
        DestroyWorkspaceSlideBackBuffer(state)
        return false
    }
    state.oldBufferBitmap := DllCall("SelectObject", "ptr", state.bufferDc,
        "ptr", state.bufferBitmap, "ptr")
    DebugLog("SLIDE_BUFFER_INIT", "monitor=" state.monitor
        " resolution=" state.width "x" state.height
        " bytes=" (state.width * state.height * 4)
        " bufferDc=" state.bufferDc " sourceDc=" state.sourceDc)
    return true
}

PaintWorkspaceSlide(hwnd) {
    global WorkspaceSlideAnimations
    if !WorkspaceSlideAnimations.Has(hwnd)
        return
    state := WorkspaceSlideAnimations[hwnd]
    paint := Buffer(72, 0)
    hdc := DllCall("BeginPaint", "ptr", hwnd, "ptr", paint.Ptr, "ptr")
    if hdc {
        RenderWorkspaceSlideFrame(state, hdc)
        DllCall("EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
    }
}

RenderWorkspaceSlideFrame(state, destinationDc := 0) {
    if !state.bufferDc || !state.sourceDc
        return false

    ; The two frames cover every pixel, but clear the back buffer defensively
    ; without asking Windows to erase the visible animation window.
    DllCall("PatBlt", "ptr", state.bufferDc,
        "int", 0, "int", 0, "int", state.width, "int", state.height,
        "uint", 0x00000042)

    oldSourceBitmap := DllCall("SelectObject", "ptr", state.sourceDc,
        "ptr", state.outgoingFrame.bitmap, "ptr")
    DllCall("BitBlt", "ptr", state.bufferDc,
        "int", state.outgoingOffset, "int", 0,
        "int", state.width, "int", state.height,
        "ptr", state.sourceDc, "int", 0, "int", 0,
        "uint", 0x00CC0020)
    DllCall("SelectObject", "ptr", state.sourceDc, "ptr", state.incomingFrame.bitmap)
    DllCall("BitBlt", "ptr", state.bufferDc,
        "int", state.incomingOffset, "int", 0,
        "int", state.width, "int", state.height,
        "ptr", state.sourceDc, "int", 0, "int", 0,
        "uint", 0x00CC0020)
    DllCall("SelectObject", "ptr", state.sourceDc, "ptr", oldSourceBitmap)

    releaseDestination := false
    if !destinationDc {
        destinationDc := DllCall("GetDC", "ptr", state.hwnd, "ptr")
        releaseDestination := true
    }
    if !destinationDc
        return false
    result := DllCall("BitBlt", "ptr", destinationDc,
        "int", 0, "int", 0, "int", state.width, "int", state.height,
        "ptr", state.bufferDc, "int", 0, "int", 0,
        "uint", 0x00CC0020)
    if releaseDestination
        DllCall("ReleaseDC", "ptr", state.hwnd, "ptr", destinationDc)
    return result != 0
}

DestroyWorkspaceSlideBackBuffer(state) {
    if state.bufferDc && state.oldBufferBitmap
        try DllCall("SelectObject", "ptr", state.bufferDc, "ptr", state.oldBufferBitmap)
    if state.bufferBitmap
        try DllCall("DeleteObject", "ptr", state.bufferBitmap)
    if state.sourceDc
        try DllCall("DeleteDC", "ptr", state.sourceDc)
    if state.bufferDc
        try DllCall("DeleteDC", "ptr", state.bufferDc)
    state.bufferDc := 0
    state.sourceDc := 0
    state.bufferBitmap := 0
    state.oldBufferBitmap := 0
}

RunWorkspaceSlideAnimation(state) {
    global WorkspaceSlideSkipRequests
    if !state
        return

    started := A_TickCount
    previousPresented := started
    frameCount := 0
    intervalTotal := 0
    maxInterval := 0
    maxRenderMs := 0
    slowFrames := 0
    accelerated := false
    Loop {
        if WorkspaceSlideSkipRequests.Has(state.monitor) {
            WorkspaceSlideSkipRequests.Delete(state.monitor)
            accelerated := true
            progress := 1
            DebugLog("SLIDE_ACCELERATE", "monitor=" state.monitor
                " from=D" state.oldWorkspace " to=D" state.newWorkspace
                " elapsedMs=" (A_TickCount - started))
        } else {
            progress := Min(1, (A_TickCount - started) / state.duration)
        }
        ; Ease-in-out cubic gives the transition weight without overshoot.
        eased := progress < 0.5
            ? 4 * progress * progress * progress
            : 1 - (((-2 * progress + 2) ** 3) / 2)
        outgoingOffset := Round(-state.direction * state.width * eased)
        ; Keep both full-frame edges locked to the exact same pixel so rounding
        ; can never expose a one-pixel gap between workspaces.
        incomingOffset := outgoingOffset + (state.direction * state.width)
        state.outgoingOffset := outgoingOffset
        state.incomingOffset := incomingOffset

        renderStarted := A_TickCount
        RenderWorkspaceSlideFrame(state)
        try DllCall("dwmapi\DwmFlush")
        presented := A_TickCount
        renderMs := presented - renderStarted
        maxRenderMs := Max(maxRenderMs, renderMs)
        frameCount += 1
        if frameCount > 1 {
            interval := presented - previousPresented
            intervalTotal += interval
            maxInterval := Max(maxInterval, interval)
            if interval > 20
                slowFrames += 1
        }
        previousPresented := presented
        if progress >= 1
            break
        Sleep(1)
    }
    averageInterval := frameCount > 1 ? Round(intervalTotal / (frameCount - 1), 2) : 0
    DebugLog("SLIDE_COMPLETE", "monitor=" state.monitor " from=D" state.oldWorkspace
        " to=D" state.newWorkspace " elapsedMs=" (A_TickCount - started)
        " frames=" frameCount " averageIntervalMs=" averageInterval
        " maxIntervalMs=" maxInterval " maxRenderMs=" maxRenderMs
        " slowFramesOver20Ms=" slowFrames " accelerated=" accelerated)
}

EndWorkspaceSlideAnimation(state) {
    global WorkspaceSlideAnimations
    if state {
        if WorkspaceSlideAnimations.Has(state.hwnd)
            WorkspaceSlideAnimations.Delete(state.hwnd)
        try state.gui.Destroy()
        DestroyWorkspaceSlideBackBuffer(state)
    }
    FlushDeferredWorkspaceFrameDeletes()
    if state
        DebugLog("SLIDE_END", "monitor=" state.monitor " from=D" state.oldWorkspace
            " to=D" state.newWorkspace)
}

ShowWorkspaceOverlay(monitor, workspace, direction := 0) {
    global SHOW_FEEDBACK, INDICATOR_MS, WorkspaceOverlays
    if !SHOW_FEEDBACK
        return

    DebugLog("OVERLAY_SHOW", "monitor=" monitor " workspace=D" workspace
        " direction=" direction)
    CancelWorkspaceOverlay(monitor)
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)

    width := 78
    height := 44
    targetX := left + ((right - left - width) // 2)
    targetY := top + 20
    label := "D" workspace

    overlay := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 -DPIScale")
    overlay.BackColor := "111827"
    overlay.MarginX := 0
    overlay.MarginY := 0
    overlay.SetFont("s18 cFFFFFF w600", "Segoe UI")
    overlay.AddText("x0 y0 w78 h44 Center +0x200 BackgroundTrans", label)

    overlay.Show("NA x" targetX " y" targetY " w" width " h" height)
    hwnd := overlay.Hwnd
    try WinSetRegion("0-0 W" width " H" height " R12-12", "ahk_id " hwnd)
    try WinSetTransparent(238, "ahk_id " hwnd)

    state := {
        gui: overlay, hwnd: hwnd, monitor: monitor,
        workspace: workspace,
        targetX: targetX, y: targetY
    }
    state.dismissTimer := CancelWorkspaceOverlay.Bind(monitor)
    WorkspaceOverlays[monitor] := state
    SetTimer(state.dismissTimer, -INDICATOR_MS)
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
    ; Relinquish ownership before stopping timers or destroying the GUI. Those
    ; operations can dispatch pending timer/window messages re-entrantly; any
    ; duplicate cancellation must see that this overlay is already gone.
    WorkspaceOverlays.Delete(monitor)
    DebugLog("OVERLAY_CANCEL", "monitor=" monitor " workspace=D" state.workspace
        " hwnd=" state.hwnd)
    if state.HasOwnProp("moveTimer")
        try SetTimer(state.moveTimer, 0)
    if state.HasOwnProp("dismissTimer")
        try SetTimer(state.dismissTimer, 0)
    if state.HasOwnProp("fadeTimer")
        try SetTimer(state.fadeTimer, 0)
    try state.gui.Destroy()
}

ShowFeedbackForMonitor(monitor, workspace, *) {
    ShowWorkspaceOverlay(monitor, workspace)
}

OpenDebugLog(*) {
    global DEBUG_LOG_PATH
    DebugLog("DEBUG_LOG_OPEN", "path=" DEBUG_LOG_PATH)
    try Run('notepad.exe "' DEBUG_LOG_PATH '"')
}

ScheduleWorkspaceStateSave(*) {
    global WorkspaceStatePersistenceEnabled
    if !WorkspaceStatePersistenceEnabled
        return
    SetTimer(SaveWorkspaceState, -250)
}

SaveWorkspaceState(*) {
    global CurrentWorkspace, WindowWorkspace, WORKSPACE_STATE_PATH, WORKSPACE_COUNT
    global WorkspaceStatePersistenceEnabled, WorkspaceWindowOrders
    if !WorkspaceStatePersistenceEnabled
        return
    try {
        SplitPath(WORKSPACE_STATE_PATH,, &stateDirectory)
        DirCreate(stateDirectory)
        ; Refresh the stack for each workspace that is currently visible. Hidden
        ; workspaces keep the order captured immediately before they were left.
        Loop MonitorGetCount() {
            monitor := A_Index
            if CurrentWorkspace.Has(monitor)
                RememberWorkspaceWindowOrder(monitor, CurrentWorkspace[monitor])
        }

        contents := "IMW_STATE_V2`n"
        Loop MonitorGetCount() {
            monitor := A_Index
            workspace := CurrentWorkspace.Has(monitor) ? CurrentWorkspace[monitor] : 1
            contents .= "M`t" MonitorGetName(monitor) "`t" workspace "`n"
        }
        savedWindows := 0
        for hwnd, slot in WindowWorkspace {
            if !WinExist("ahk_id " hwnd)
                continue
            if slot.monitor < 1 || slot.monitor > MonitorGetCount()
                continue
            try pid := WinGetPID("ahk_id " hwnd)
            catch
                continue
            contents .= "W`t" hwnd "`t" pid "`t" MonitorGetName(slot.monitor)
                . "`t" slot.workspace "`n"
            savedWindows += 1
        }

        savedOrderEntries := 0
        for key, order in WorkspaceWindowOrders {
            rank := 0
            for hwnd in order {
                if !WinExist("ahk_id " hwnd) || !WindowWorkspace.Has(hwnd)
                    continue
                slot := WindowWorkspace[hwnd]
                if WorkspaceWindowOrderKey(slot.monitor, slot.workspace) != key
                    continue
                try pid := WinGetPID("ahk_id " hwnd)
                catch
                    continue
                rank += 1
                contents .= "O`t" hwnd "`t" pid "`t" MonitorGetName(slot.monitor)
                    . "`t" slot.workspace "`t" rank "`n"
                savedOrderEntries += 1
            }
        }

        temporaryPath := WORKSPACE_STATE_PATH ".tmp"
        if FileExist(temporaryPath)
            FileDelete(temporaryPath)
        FileAppend(contents, temporaryPath, "UTF-8")
        FileMove(temporaryPath, WORKSPACE_STATE_PATH, true)
        DebugLog("STATE_SAVE", "path=" WORKSPACE_STATE_PATH
            " monitors=" MonitorGetCount() " windows=" savedWindows
            " orderEntries=" savedOrderEntries)
    } catch as error {
        DebugLog("STATE_SAVE_ERROR", "message=" DebugClean(error.Message))
    }
}

LoadWorkspaceState() {
    global CurrentWorkspace, WindowWorkspace, WORKSPACE_STATE_PATH, WORKSPACE_COUNT
    global WorkspaceWindowOrders
    if !FileExist(WORKSPACE_STATE_PATH) {
        DebugLog("STATE_LOAD", "result=missing path=" WORKSPACE_STATE_PATH)
        return false
    }

    monitorLookup := Map()
    Loop MonitorGetCount()
        monitorLookup[StrLower(MonitorGetName(A_Index))] := A_Index

    restoredMonitors := 0
    restoredWindows := 0
    restoredOrderEntries := 0
    rejectedWindows := 0
    try contents := FileRead(WORKSPACE_STATE_PATH, "UTF-8")
    catch as error {
        DebugLog("STATE_LOAD_ERROR", "message=" DebugClean(error.Message))
        return false
    }

    for line in StrSplit(contents, "`n", "`r") {
        if !line || line = "IMW_STATE_V1" || line = "IMW_STATE_V2"
            continue
        fields := StrSplit(line, "`t")
        if fields.Length >= 3 && fields[1] = "M" {
            deviceName := StrLower(fields[2])
            try workspace := Integer(fields[3])
            catch
                continue
            if monitorLookup.Has(deviceName)
                && workspace >= 1 && workspace <= WORKSPACE_COUNT {
                CurrentWorkspace[monitorLookup[deviceName]] := workspace
                restoredMonitors += 1
            }
            continue
        }
        if fields.Length >= 6 && fields[1] = "O" {
            try {
                hwnd := Integer(fields[2])
                expectedPid := Integer(fields[3])
                deviceName := StrLower(fields[4])
                workspace := Integer(fields[5])
                rank := Integer(fields[6])
            } catch
                continue
            if !monitorLookup.Has(deviceName) || workspace < 1
                || workspace > WORKSPACE_COUNT || rank < 1
                || !WinExist("ahk_id " hwnd) || !WindowWorkspace.Has(hwnd)
                continue
            try actualPid := WinGetPID("ahk_id " hwnd)
            catch
                continue
            monitor := monitorLookup[deviceName]
            slot := WindowWorkspace[hwnd]
            if actualPid != expectedPid || slot.monitor != monitor
                || slot.workspace != workspace
                continue
            key := WorkspaceWindowOrderKey(monitor, workspace)
            if !WorkspaceWindowOrders.Has(key)
                WorkspaceWindowOrders[key] := []
            WorkspaceWindowOrders[key].Push(hwnd)
            restoredOrderEntries += 1
            continue
        }
        if fields.Length < 5 || fields[1] != "W"
            continue

        try {
            hwnd := Integer(fields[2])
            expectedPid := Integer(fields[3])
            deviceName := StrLower(fields[4])
            workspace := Integer(fields[5])
        } catch {
            rejectedWindows += 1
            continue
        }
        if !monitorLookup.Has(deviceName) || workspace < 1 || workspace > WORKSPACE_COUNT
            || !WinExist("ahk_id " hwnd) {
            rejectedWindows += 1
            continue
        }
        try actualPid := WinGetPID("ahk_id " hwnd)
        catch {
            rejectedWindows += 1
            continue
        }
        if actualPid != expectedPid || IsIgnoredPersistedWindow(hwnd) {
            rejectedWindows += 1
            continue
        }
        monitor := monitorLookup[deviceName]
        WindowWorkspace[hwnd] := {monitor: monitor, workspace: workspace}
        restoredWindows += 1
        DebugLog("STATE_WINDOW_RESTORE", "monitor=" monitor " workspace=D" workspace
            " " DebugDescribeWindow(hwnd))
    }

    DebugLog("STATE_LOAD", "result=ok monitors=" restoredMonitors
        " windows=" restoredWindows " rejected=" rejectedWindows
        " orderEntries=" restoredOrderEntries
        " path=" WORKSPACE_STATE_PATH)
    return restoredMonitors || restoredWindows
}

IsIgnoredPersistedWindow(hwnd) {
    try className := WinGetClass("ahk_id " hwnd)
    catch
        return true
    if className = "EdgeUiInputTopWndClass"
        || className = "XamlExplorerHostIslandWindow_WASDK"
        || className = "RaycastUIAccessHelper"
        || className = "RaycastNodeGracefulShutdownClass"
        return true
    try processName := WinGetProcessName("ahk_id " hwnd)
    catch
        processName := ""
    try title := WinGetTitle("ahk_id " hwnd)
    catch
        title := ""
    return (StrLower(processName) = "msedgewebview2.exe" && title = "Widgets")
        || StrLower(processName) = "raycast.exe"
}

ApplyRestoredWorkspaceVisibility() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    applied := 0
    for hwnd, slot in WindowWorkspace.Clone() {
        if !WinExist("ahk_id " hwnd) {
            ForgetWindow(hwnd)
            continue
        }
        if !CurrentWorkspace.Has(slot.monitor)
            continue
        expectedVisible := slot.workspace = CurrentWorkspace[slot.monitor]
        if expectedVisible {
            if !IsVisible(hwnd) {
                DebugLog("STATE_APPLY_SHOW", "current=D" CurrentWorkspace[slot.monitor]
                    " " DebugDescribeWindow(hwnd))
                ShowWindowFast(hwnd)
            }
            if HiddenByScript.Has(hwnd)
                HiddenByScript.Delete(hwnd)
        } else {
            if IsVisible(hwnd) {
                DebugLog("STATE_APPLY_HIDE", "current=D" CurrentWorkspace[slot.monitor]
                    " assigned=D" slot.workspace " " DebugDescribeWindow(hwnd))
                CaptureWindowSnapshot(hwnd)
                HideWindowFast(hwnd)
            }
            HiddenByScript[hwnd] := true
        }
        applied += 1
    }
    DebugLog("STATE_APPLY", "windows=" applied)
    Loop MonitorGetCount()
        SetTimer(VerifyWorkspaceTransition.Bind(A_Index, CurrentWorkspace[A_Index], 0), -300)
}

InitializeDebugLogging() {
    global DEBUG_LOG_PATH, DEBUG_PREVIOUS_LOG_PATH, DEBUG_MAX_BYTES, DEBUG_SESSION_ID
    try {
        SplitPath(DEBUG_LOG_PATH,, &logDirectory)
        DirCreate(logDirectory)
        if FileExist(DEBUG_LOG_PATH) && FileGetSize(DEBUG_LOG_PATH) >= DEBUG_MAX_BYTES {
            if FileExist(DEBUG_PREVIOUS_LOG_PATH)
                FileDelete(DEBUG_PREVIOUS_LOG_PATH)
            FileMove(DEBUG_LOG_PATH, DEBUG_PREVIOUS_LOG_PATH, true)
        }
        FileAppend("`n===== SESSION " DEBUG_SESSION_ID " =====`n", DEBUG_LOG_PATH, "UTF-8")
    }
}

DebugLog(event, details := "") {
    global DEBUG_LOG_PATH, DEBUG_SESSION_ID
    try {
        timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss") "." Format("{:03}", A_MSec)
        line := timestamp " [" DEBUG_SESSION_ID "] [" event "]"
        if details != ""
            line .= " " DebugClean(details)
        FileAppend(line "`n", DEBUG_LOG_PATH, "UTF-8")
    }
}

DebugClean(value) {
    text := value ""
    text := StrReplace(text, "`r", "\\r")
    text := StrReplace(text, "`n", "\\n")
    text := StrReplace(text, "`t", " ")
    return text
}

FormatDebugArguments() {
    result := "["
    for index, argument in A_Args {
        if index > 1
            result .= ", "
        result .= '"' DebugClean(argument) '"'
    }
    return result "]"
}

DebugDescribeWindow(hwnd) {
    if !hwnd
        return "hwnd=0"
    exists := WinExist("ahk_id " hwnd) != 0
    if !exists
        return "hwnd=" hwnd " exists=false"
    try title := DebugClean(WinGetTitle("ahk_id " hwnd))
    catch
        title := "<error>"
    try processName := WinGetProcessName("ahk_id " hwnd)
    catch
        processName := "<error>"
    try className := WinGetClass("ahk_id " hwnd)
    catch
        className := "<error>"
    try minimized := WinGetMinMax("ahk_id " hwnd)
    catch
        minimized := "<error>"
    try monitor := GetWindowMonitor(hwnd)
    catch
        monitor := "<error>"
    quote := Chr(34)
    return "hwnd=" hwnd " title=" quote title quote " process=" processName
        . " class=" className " monitor=" monitor " visible=" IsVisible(hwnd)
        . " minmax=" minimized
}

DebugWorkspaceSummary(monitor) {
    global WindowWorkspace, HiddenByScript, WORKSPACE_COUNT
    counts := []
    Loop WORKSPACE_COUNT
        counts.Push(0)
    tracked := 0
    hidden := 0
    for hwnd, slot in WindowWorkspace {
        if slot.monitor != monitor
            continue
        tracked += 1
        if slot.workspace >= 1 && slot.workspace <= WORKSPACE_COUNT
            counts[slot.workspace] += 1
        if HiddenByScript.Has(hwnd)
            hidden += 1
    }
    result := "tracked=" tracked " hidden=" hidden
    Loop WORKSPACE_COUNT
        result .= " D" A_Index "=" counts[A_Index]
    return result
}

VerifyWorkspaceTransition(monitor, workspace, attempt := 0) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    mismatchCount := 0
    mismatchDetails := ""
    for hwnd, slot in WindowWorkspace {
        if slot.monitor != monitor || !WinExist("ahk_id " hwnd)
            continue
        expectedVisible := slot.workspace = workspace
        actualVisible := IsVisible(hwnd)
        scriptHidden := HiddenByScript.Has(hwnd)
        if expectedVisible != actualVisible {
            mismatchCount += 1
            if mismatchCount <= 12
                mismatchDetails .= " | expected=" (expectedVisible ? "visible" : "hidden")
                    . " assigned=D" slot.workspace " scriptHidden=" scriptHidden
                    . " " DebugDescribeWindow(hwnd)
        }
    }
    actualWorkspace := CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing"
    DebugLog("SWITCH_VERIFY", "attempt=" attempt " monitor=" monitor
        " expected=D" workspace " actual=" actualWorkspace
        " mismatches=" mismatchCount " active=" DebugDescribeWindow(WinExist("A"))
        mismatchDetails)
    if mismatchCount && attempt < 3
        SetTimer(VerifyWorkspaceTransition.Bind(monitor, workspace, attempt + 1), -250)
}

ShowHelp(*) {
    global WORKSPACE_COUNT
    MsgBox(
        "Independent Monitor Workspaces`n`n"
        . "Point the mouse at the monitor you want to control, then use:`n`n"
        . "Win+Ctrl+Left / Right   Previous or next workspace`n"
        . "Win+Ctrl+Space          Show all workspace windows`n"
        . "Win+Ctrl+1.." WORKSPACE_COUNT "       Open a numbered workspace`n"
        . "Win+Ctrl+Shift+1.." WORKSPACE_COUNT " Move the active window`n"
        . "Win+Ctrl+Shift+R        Restart and recover the workspace engine`n"
        . "Ctrl+Alt+Shift+R        Launch recovery even if the engine stopped`n"
        . "Win+Ctrl+Shift+Esc      Reveal everything and reset`n`n"
        . "Move the pointer to a monitor's top-left corner and hold to open the overview.`n`n"
        . "Keep Windows itself on one native virtual desktop while using this script.",
        "Independent Monitor Workspaces",
        "Iconi"
    )
}
