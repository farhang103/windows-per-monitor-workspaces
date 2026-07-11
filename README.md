# Independent Monitor Workspaces

Independent, fast workspace switching for each monitor on Windows 11.

Windows virtual desktops switch every display together. This lightweight AutoHotkey v2 utility gives each monitor its own workspace state: point at a screen, switch, and only the windows on that screen change. Other monitors stay exactly where they are.

- Instant asynchronous switching—no staggered window-by-window delay
- Smooth slide-and-fade workspace indicator
- Native cursor-to-monitor detection that works across mixed DPI and scaling
- Automatically supports one, two, three, four, or more connected monitors
- Safely resets when displays are connected, disconnected, docked, or rearranged
- No background service, driver, scheduled task, registry edit, telemetry, or administrator requirement

## Install in one command

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/Allaa-boutaleb/windows-per-monitor-workspaces/main/install.ps1 | iex
```

The command downloads one readable AutoHotkey script to `%LOCALAPPDATA%\IndependentMonitorWorkspaces`, creates a normal Startup shortcut, and launches it. If AutoHotkey v2 is missing, the installer uses `winget` to install it.

Prefer to inspect commands before running them? Open [install.ps1](install.ps1), or use the manual installation steps below.

## Controls

Point the mouse at the monitor you want to control, then use:

| Shortcut | Action |
|---|---|
| `Win+Ctrl+Left` / `Win+Ctrl+Right` | Previous / next workspace on that monitor |
| `Win+Ctrl+1` … `Win+Ctrl+4` | Open a numbered workspace on that monitor |
| `Win+Ctrl+Shift+1` … `Win+Ctrl+Shift+4` | Move the active window to a workspace |
| `Win+Ctrl+Shift+Esc` | Reveal every window and reset all workspace state |

Four workspaces are enabled by default. Change `WORKSPACE_COUNT := 4` near the top of the script to any value from 1 to 9.

## Uninstall in one command

```powershell
irm https://raw.githubusercontent.com/Allaa-boutaleb/windows-per-monitor-workspaces/main/uninstall.ps1 | iex
```

Uninstalling reveals windows managed by the script, removes its Startup shortcut and local files, and leaves AutoHotkey installed so other scripts are not disrupted.

## How it works

Windows exposes a single active native virtual desktop across the full display topology. This utility stays on one native Windows desktop and maintains lightweight window groups for each physical monitor. Switching a monitor sends asynchronous show/hide requests only to windows assigned to that monitor.

Monitor targeting uses the native Windows `HMONITOR` device under the physical cursor instead of comparing logical screen coordinates. This avoids the common wrong-monitor problem on displays with different scaling factors.

Display count is dynamic. One monitor works like a normal workspace switcher; additional monitors receive independent state automatically. A Windows display-topology notification triggers a safe reveal-and-reset after docking, unplugging, rearranging, or resolution changes.

## Manual installation

1. Install [AutoHotkey v2](https://www.autohotkey.com/).
2. Download `IndependentMonitorWorkspaces.ahk` from this repository.
3. Double-click the script.
4. Optionally place a shortcut to it in `shell:startup`.

## Limitations

- These are independent window workspaces, not separate native Windows virtual desktops.
- Keep Windows itself on one native virtual desktop while using the utility.
- Wallpaper and desktop icons do not change between workspaces.
- Elevated applications cannot be controlled by a non-elevated script. Running the utility as administrator is possible but generally unnecessary.
- A small number of specialized or protected application windows may ignore standard Windows show/hide messages.

If anything behaves unexpectedly, press `Win+Ctrl+Shift+Esc` to reveal everything and reset.

## Requirements

- Windows 11
- AutoHotkey v2
- Multiple monitors are optional

## License

[MIT](LICENSE)