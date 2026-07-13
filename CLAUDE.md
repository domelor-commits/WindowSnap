# WindowSnap

A lightweight macOS menu-bar window manager plus a suite of productivity
utilities (clipboard history, dictation, live translation, annotation,
scrolling capture, calculator, unit conversions, command palette, and more).
Original code — not derived from any commercial product.

## Tech stack

- **Swift 5.9**, Swift Package Manager (no Xcode project). `Package.swift` is the
  source of truth; `platforms: [.macOS(.v14)]` (macOS 14+).
- **AppKit/Cocoa** UI (not SwiftUI), plus **Vision**, **Carbon.HIToolbox** for
  global hotkeys, and the Accessibility API (AX) for window control.
- Dependencies: **WhisperKit** (on-device speech → dictation/translation) and
  **Sparkle** (in-app updates).
- `Sources/CAXBridge` is a small C shim target the Swift target depends on.

## Build & run

- **Dev iteration:** `./dev.sh` (debug, fastest) or `./dev.sh release`. Builds,
  wraps the binary in `WindowSnap.app`, signs, and relaunches.
- **Full package:** `./build.sh` — regenerates the icon, builds release, embeds
  & signs Sparkle.framework, seals the app, and produces `WindowSnap.dmg`.
- **Plain build:** `swift build` / `swift build -c release`.
- **Release:** `./release.sh` (bumps version, builds, updates `appcast.xml`).

### Code signing (important)

macOS ties the Accessibility grant to the app's code signature. Ad-hoc signing
(`-`) changes the signature every build, resetting the grant on each update. Run
`./make-cert.sh` **once** to create the reusable "WindowSnap Self-Signed"
identity; `build.sh`/`dev.sh` then sign with it automatically so the grant
persists. Bundle ID is `com.local.windowsnap`.

## Architecture

- **`main.swift`** (`AppDelegate`, ~1450 lines) — the hub. Sets up the menu bar,
  registers global hotkeys, wires the settings window and command palette, and
  runs periodic layout snapshots. Start here to trace app behavior.
- **Window management:** `WindowController` + `SnapRegion` + `LayoutManager`
  (save/restore multi-monitor arrangements to
  `~/Library/Application Support/WindowSnap/layouts.json`), `DragSnap`/`SnapHUD`
  (drag-to-edge snapping), `LayoutCanvas` (visual preview).
- **Hotkeys:** `HotkeyManager` + `ShortcutRecorder` + `KeyNames`. Every action
  has a configurable shortcut; at least one modifier required.
- **Settings:** `Settings.swift` (model, persisted to UserDefaults) +
  `SettingsWindow.swift` (the big ~1780-line tabbed UI).
- **Utilities** (each self-contained, surfaced via menu/palette): `ClipboardHistory`,
  `Dictation` + `LiveTranslator` (WhisperKit), `Annotator`, `ScrollingCapture`,
  `Calculator`, `Conversions`, `CommandPalette`, `WindowSwitcher`, `ForceQuit`,
  `KeepAwake`, `ShelfWindow`, `MeetingBar`, `KeystrokeVisualizer`, `QuickAccessOverlay`,
  `CheatSheetOverlay`.
- **Permissions:** `PermissionsWindow` (guided Accessibility/Screen Recording grant).
- **Updates:** `Updater` (Sparkle) + `WhatsNew` + `appcast.xml` + `release-notes/`.

## Conventions

- AppKit patterns throughout: `NSWindowController`, delegates, `[weak self]`
  closures. Match the existing dense-comment style — comments explain *why*
  (macOS quirks, timing, permission edge cases), not *what*.
- Features are added as a new `Sources/WindowSnap/<Feature>.swift` file and wired
  into `main.swift` (menu + palette action) and `SettingsWindow.swift` (a tab).
