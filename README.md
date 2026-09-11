<p align="center">
  <img src="docs/images/icon.png" alt="WindowHop icon" width="112" />
</p>

<h1 align="center">WindowHop</h1>
<p align="center"><strong>Windows-style window switching, built for macOS.</strong></p>
<p align="center">One shortcut. Every window. Even the minimized ones.</p>

<p align="center">
  <img alt="macOS 13 or later" src="https://img.shields.io/badge/macOS-13%2B-222222?logo=apple" />
  <img alt="Built with Swift" src="https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white" />
  <a href="https://github.com/hpkruger/WindowHop/actions/workflows/build.yml"><img alt="Build and test" src="https://github.com/hpkruger/WindowHop/actions/workflows/build.yml/badge.svg" /></a>
</p>

<p align="center">
  <a href="docs/images/switcher.png"><img src="docs/images/switcher.png" alt="WindowHop showing Finder, two Safari windows, Terminal, TextEdit, and Notes, including a minimized window" width="590" /></a>
</p>
<p align="center"><sub>The native picker at 3× resolution, with example window titles. Click to view full size.</sub></p>

## Switch to the window you meant

macOS Command+Tab selects an app. If that app has several windows, finding the one you want takes another step. And activating an app can leave its minimized window tucked away.

WindowHop puts individual windows in a single picker. Two Safari windows get two entries. A minimized document stays within reach. Hold your chosen modifier, tap Tab, and release to bring the selected window forward.

## What it does

- **Switch between windows across apps.** See each window's title and app icon in a horizontal Alt-Tab-style picker.
- **Preview windows at a glance.** Live thumbnails are enabled by default and can be turned off in Settings for a compact picker.
- **Choose Option+Tab or Command+Tab.** Change the shortcut in Settings; your choice survives restarts.
- **Restore minimized windows.** Selecting a window unhides its app and restores the window before raising it.
- **Return to recent windows.** WindowHop tracks focus while running and keeps the order steady while you cycle.
- **Go either direction.** Add Shift to reverse, use arrow keys to navigate, or click a window.
- **Stay out of the way.** A menu-bar utility with a picker that does not take keyboard focus from your work.

## Build and install

You need **macOS 13 or later** and a Swift 5.9-or-later toolchain with the macOS SDK. The app uses AppKit and SwiftUI, with no third-party package dependencies.

```sh
git clone https://github.com/hpkruger/WindowHop.git
cd WindowHop
./scripts/build.sh

mkdir -p ~/Applications
ditto build/WindowHop.app ~/Applications/WindowHop.app
open ~/Applications/WindowHop.app
```

This builds a local, ad-hoc-signed app. There is currently no notarized installer.

### First launch

1. Click **Open Accessibility Settings** in WindowHop.
2. Enable **WindowHop**. If it is missing, use **+** to add the installed app.
3. Choose **Option+Tab** or **Command+Tab** under **Switching shortcut**.
4. Hold the modifier, tap Tab, and release to switch.

WindowHop checks for permission changes automatically. Use **Check Again** or restart the app if necessary.

**Command+Tab mode replaces the standard macOS app switcher while WindowHop is active.** Pause or quit WindowHop from its menu-bar menu to return to the system switcher. Option+Tab is the default and leaves the system's Command+Tab shortcut available.

<p align="center">
  <a href="docs/images/settings.png"><img src="docs/images/settings.png" alt="WindowHop Settings with Command+Tab selected, Accessibility enabled, and shortcut and window controls" width="510" /></a>
</p>
<p align="center"><sub>Settings at 3× resolution. Choose your shortcut and check Accessibility access. Click to view full size.</sub></p>

## Keyboard controls

“Modifier” means **Option** or **Command**, according to your setting.

| Action | Shortcut |
| --- | --- |
| Select the previous window | Hold modifier and tap **Tab** |
| Cycle forward | Keep holding modifier and tap **Tab** again |
| Cycle backward | Modifier + **Shift + Tab** |
| Activate the selection | Release the modifier |
| Activate immediately | **Return**, or click a window |
| Move through the list | **Arrow keys** while the picker is open |
| Cancel | **Escape** |

The picker opens on the display containing your pointer. You can also open it with **Show Windows** in Settings or the menu-bar menu. Typing another key, clicking outside, or switching apps dismisses it.

## Permissions and privacy

WindowHop needs **Accessibility** access to read window titles, handle its shortcut, and focus or restore windows. Live window previews also use macOS **Screen Recording** access; if that permission is unavailable, the picker continues to show titles and icons.

WindowHop does not save preview images or record keystrokes, send network requests, or save window-title history. Recent-window history stays in memory. Turn previews off in Settings if you do not want it to use Screen Recording access.

## Good to know

This is an early version. The build, keyboard callback logic, native configuration UI, and restoration of a real minimized window have been tested. Physical shortcut interception and full-screen, cross-Space, and multi-display behaviour still need broader hands-on validation. See [validation notes](TESTING.md).

- **Spaces and full-screen windows:** visibility and activation depend on what each app exposes through Accessibility and how macOS handles Space changes. WindowHop does not move windows between Spaces.
- **Recent ordering starts at launch:** previously unseen windows initially sort by app and title. Past usage cannot be recovered after a restart.
- **Some windows are excluded:** utility palettes, desktop elements, and WindowHop's own windows are not listed. Apps with unusual Accessibility implementations may behave differently.
- **Shortcut conflicts:** Secure Input or another shortcut utility may prevent interception. Avoid assigning the same shortcut to two active utilities.
- **After rebuilding:** ad-hoc signing can invalidate the existing Accessibility entry. Remove that entry and re-add the current installed app. An available Apple development identity can be supplied through `WINDOWHOP_SIGN_IDENTITY` when building.
- **Start at login:** add WindowHop in macOS Login Items if you want it to launch automatically.

## Development

```sh
swift test                  # Selection, keyboard callback, and preference tests
./scripts/build.sh          # Build the .app and generate its native-symbol icon
./scripts/fixture.sh        # Open three disposable windows for manual testing
./scripts/preview.sh        # Show the documentation picker with example titles
./scripts/preview.sh --export "$PWD/docs/images"  # Export both native views at 3×
```

The documentation preview is a separate app that renders the production picker. It does not inspect your windows or install a keyboard tap.

| Source | Responsibility |
| --- | --- |
| `WindowCatalog.swift` | Window discovery, focus tracking, and restoration on a serial worker queue |
| `KeyboardTap.swift` | Shortcut preferences and keyboard-event handling |
| `SwitchSession.swift` | Stable selection and cycling for one gesture |
| `SwitcherUI.swift` | Native picker and Settings views |
| `main.swift` | Menu-bar lifecycle and coordination |

The keyboard callback works from a cached window list. Accessibility notifications update focus, and a periodic refresh reconciles window changes. Window discovery runs off the UI thread.

Found a window that will not switch, or a shortcut conflict? [Open an issue](https://github.com/hpkruger/WindowHop/issues) with your macOS version, the affected app, and steps to reproduce. Please remove private window titles from screenshots or logs.
