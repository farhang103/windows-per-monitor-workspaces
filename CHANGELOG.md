# Changelog

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