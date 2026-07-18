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
- **Tests:** `./test.sh` (Swift Testing suite in `Tests/WindowSnapTests`). Use the
  script, not bare `swift test`: on a Command-Line-Tools-only machine the
  framework flags must be passed on the CLI or SwiftPM's synthesized runner
  silently runs zero tests (details in the script). Note the flags create a
  second build configuration, so alternating test.sh and plain builds triggers
  full rebuilds.
- **CI:** `.github/workflows/ci.yml` runs `swift build` + `./test.sh` on every
  push/PR to main.
- **Release:** `./release.sh` (bumps version, builds, updates `appcast.xml`).

### Code signing (important)

macOS ties the Accessibility grant to the app's code signature. Ad-hoc signing
(`-`) changes the signature every build, resetting the grant on each update. Run
`./make-cert.sh` **once** to create the reusable "WindowSnap Self-Signed"
identity; `build.sh`/`dev.sh` then sign with it automatically so the grant
persists. Bundle ID is `com.local.windowsnap`.

## Architecture

- **`AppDelegate`** — the hub. Split by functional area across one core file plus
  extension files (the class declaration + stored properties live in `main.swift`,
  which also holds `applicationDidFinishLaunching` and the app bootstrap):
  - `main.swift` — class decl, stored properties, launch/reopen lifecycle, bootstrap.
  - `AppDelegate+SleepWake.swift` — periodic "Saved" snapshot + sleep/wake/lock/unlock
    layout restore.
  - `AppDelegate+Snapping.swift` — Accessibility/Screen-Recording prompts, snap logic,
    edge detection, multi-monitor cycling.
  - `AppDelegate+Menu.swift` — menu-bar icon, main menu, the dropdown menu, palette
    actions, Keep Awake countdown.
  - `AppDelegate+Hotkeys.swift` — global hotkey registration, function-key & system-task
    actions, force-quit-and-reopen.
  - `AppDelegate+Capture.swift` — screenshot/scrolling capture delivery + on-screen OCR.
  - `AppDelegate+Restore.swift` — layout restore-by-id / pinned restore.

  Start in `main.swift` to trace launch, then follow the extension whose name matches
  the area. Instance stored properties must stay in the `main.swift` class body
  (Swift extensions can't hold them); `static` stored state may live in an extension.
- **Window management:** `WindowController` + `SnapRegion` + `LayoutManager`
  (save/restore multi-monitor arrangements to
  `~/Library/Application Support/WindowSnap/layouts.json`), `DragSnap`/`SnapHUD`
  (drag-to-edge snapping), `LayoutCanvas` (visual preview).
- **Hotkeys:** `HotkeyManager` + `ShortcutRecorder` + `KeyNames`. Every action
  has a configurable shortcut; at least one modifier required.
- **Settings:** `Settings.swift` (model, persisted to UserDefaults) +
  `SettingsWindowController`, the tabbed UI, split like `AppDelegate`:
  `SettingsWindow.swift` (class decl, stored properties, window/tab plumbing, the
  Settings-tab toggle handlers) plus `SettingsWindow+SettingsTab`, `+ShortcutsTab`,
  `+ShortcutsSupport` (function keys, app chooser, accessibility, log), `+FeatureTabs`
  (Annotate/Clipboard/ForceQuit/Conversion/Translation), `+LayoutsTab`, and
  `+LayoutsTable` (the table data source/delegate + rename/shortcut popover). Same
  rule: stored properties stay in the `SettingsWindow.swift` class body.
- **Utilities** (each self-contained, surfaced via menu/palette): `ClipboardHistory`,
  `Dictation`, `ScrollingCapture`, `Calculator`, `CommandPalette`, `WindowSwitcher`,
  `ForceQuit`, `KeepAwake`, `ShelfWindow`, `MeetingBar`, `KeystrokeVisualizer`,
  `QuickAccessOverlay`, `CheatSheetOverlay`. Three utilities span multiple files
  (split by top-level type, not extensions):
  - Annotate: `AnnotatorModel` (tools/shapes), `AnnotationCanvas`, `Annotator` (pane).
  - Convert: `UnitCatalog` (units + time-zone catalog), `WorldClock` (grid views),
    `Conversions` (the pane: currency/units/World Time + calendar events).
  - Translation (WhisperKit): `TranslationEngine` (bridge/translator), `LiveTranslator`
    (audio capture + transcription), `TranslationPane` (tab UI).
- **Permissions:** `PermissionsWindow` (guided Accessibility/Screen Recording grant).
- **Updates:** `Updater` (Sparkle) + `WhatsNew` + `appcast.xml` + `release-notes/`.

## Conventions

- AppKit patterns throughout: `NSWindowController`, delegates, `[weak self]`
  closures. Match the existing dense-comment style — comments explain *why*
  (macOS quirks, timing, permission edge cases), not *what*.
- Features are added as a new `Sources/WindowSnap/<Feature>.swift` file and wired
  into the menu/palette (an `AppDelegate+*.swift` extension — usually `+Menu`) and a
  settings tab (a `SettingsWindow+*.swift` extension). Keep each `AppDelegate` /
  `SettingsWindowController` method in the extension file for its functional area so
  edits stay scoped to one small file; only stored properties go in the core file.
