# Changelog

## 1.2.0 - 2026-09-01

- Added a 340 ms directional workspace slide using captured window surfaces, with cubic ease-in-out motion
- Higher-numbered workspaces enter from the right while the current workspace exits left; lower-numbered workspaces use the reverse direction
- Kept real application windows stationary during animation so maximized windows and saved positions are not disturbed
- Removed opacity animation from the D-number indicator
- Added an automatic bidirectional slide preview for runtime regression testing

## 1.1.5 - 2026-09-01

- Persisted per-monitor active workspaces and window assignments across app restarts and installer updates
- Reapplied saved visibility immediately on startup so D1, D2, and D3 no longer collapse back into D1 after an update
- Excluded Windows input and Widgets helper windows from workspace management

## 1.1.4 - 2026-09-01

- Fixed a re-entrant D-number overlay cleanup race that could raise `Item has no value` while rapidly switching workspaces
- Excluded Raycast's UI-access helper window because it is not an app window and rejects normal workspace hide requests

## 1.1.3 - 2026-09-01

- Added persistent diagnostic logging for monitor state, window assignments, overview hit-testing, workspace transitions, show/hide calls, activation retries, and post-switch verification
- Added bounded log rotation at 4 MB and an `Open debug log` tray command
- Added delayed transition verification that records windows whose actual visibility does not match the selected workspace

## 1.1.2 - 2026-09-01

- Made app-preview selection wait for and verify the complete workspace switch before revealing the selected window
- Prevented a selected app from being shown if another workspace becomes active during the activation delay
- Refreshed the `D1`, `D2`, or `D3` indicator after focusing an app selected from the overview

## 1.1.1 - 2026-09-01

- Fixed overview window clicks to switch using the overview's original monitor instead of re-detecting the pointer target
- Restored and showed the exact selected window synchronously after switching workspaces
- Added foreground activation retries for slower and minimized applications

## 1.1.0 - 2026-09-01

- Added a fullscreen, per-monitor workspace overview with clickable `D1`, `D2`, and `D3` panels
- Added live thumbnails for visible windows and memory-bounded cached snapshots for hidden windows
- Added click-to-switch, click-to-focus, `Esc` dismissal, and `Win+Ctrl+Space` toggling
- Added a half-second top-left hot corner on every monitor
- Added multi-monitor preview coverage for mixed 100%, 125%, and high-DPI display scales

## 1.0.3 - 2026-09-01

- Replaced the multi-row workspace indicator with a minimal `D1`, `D2`, or `D3` label
- Removed monitor text, arrows, status wording, and workspace dots from the indicator
- Enabled three workspaces by default
- Added a safe preview mode and verified the indicator across all three connected display scales

## 1.0.2 - 2026-09-01

- Reduced the workspace indicator footprint and animation distance
- Vertically centered indicator text to prevent workspace dots from being clipped
- Scaled long status labels down automatically to fit the compact card

## 1.0.1 - 2026-07-11

- Replaced the winget dependency with a pinned, isolated portable AutoHotkey v2 runtime
- Added SHA-256 verification and AutoHotkey syntax validation before installation
- Added transactional updates with file and Startup-entry rollback
- Added native Windows Shell Startup shortcut fallback
- Added Unicode-path support for Windows PowerShell 5.1
- Added installer coverage for Windows PowerShell 5.1 and PowerShell 7

## 1.0.0 - 2026-07-11

- Independent workspace state for every connected monitor
- Native mixed-DPI cursor-to-monitor detection
- Instant asynchronous window switching
- Animated slide-and-fade workspace indicator
- Numbered workspace selection and window-moving shortcuts
- Automatic display-topology reset for docking and monitor changes
- One-command PowerShell installation and uninstallation
- Startup integration without services, drivers, scheduled tasks, or registry edits
