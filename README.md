# WindowSnap

A lightweight macOS menu-bar window manager with a full settings UI:
configurable keyboard snapping, preferences (launch at login, gaps, etc.),
and save/restore of multi-monitor window layouts with a visual preview.
Original code — not derived from any commercial product.

## Build & package (run on a Mac)

Requires the Swift toolchain (`xcode-select --install`). For the custom app
icon, optionally `brew install librsvg` (the build still works without it).

```bash
cd WindowSnap
chmod +x build.sh
./build.sh
```

This produces **WindowSnap.dmg**. Open it, drag WindowSnap to Applications,
launch it, and grant Accessibility access when prompted
(System Settings → Privacy & Security → Accessibility).

## Keeping the Accessibility grant across updates

By default macOS ties the Accessibility permission to an app's *code signature*.
Ad-hoc signing (the `-` identity) produces a different signature every build, so
macOS treats each new version as a new app and resets the grant. To make the
grant persist, sign every build with a stable identity.

Run this **once**:

```bash
chmod +x make-cert.sh
./make-cert.sh
```

It creates a reusable self-signed code-signing certificate ("WindowSnap
Self-Signed") in your login keychain. No paid Apple account needed. From then
on `build.sh` signs with it automatically, the bundle identifier stays
`com.local.windowsnap`, and the signature is identical across versions — so
after you approve Accessibility once, future updates keep the grant.

If you have a paid Apple Developer account, you can instead sign with your
Developer ID (and notarize) for zero Gatekeeper friction; the persistence
mechanism is the same.



**Shortcuts** — Every action (halves, corners, thirds, maximize, center, save
layout) has a configurable shortcut. Click a shortcut button, then press the
new key combination, just like Magnet. At least one modifier is required.
"Reset All to Defaults" restores the ⌃⌥ set.

**Settings** — Toggles similar to Magnet/Moom:
- Launch WindowSnap at login (macOS 13+)
- Show icon in menu bar
- Snap to screen edges
- Play sound on snap / restore
- Match windows by title when restoring layouts
- Gap between snapped windows (0–40 px)

**Layouts** — A list of saved layouts on the left; selecting one draws all your
monitors to scale on the right, with each saved window rendered inside the
monitor it belongs to and labeled with its app name, window title, and **PID**.
Save the current arrangement, restore it, or delete it.

### A note on PID-based identification

Each saved window records its PID and the layout viewer displays it, as
requested. However, macOS assigns a *new* PID every time an app launches, so a
PID saved today won't match the same app tomorrow. To make restore actually
work across relaunches and reboots, WindowSnap matches windows by app bundle ID
+ window title on restore (toggle in Settings), using PID as a live label
rather than the restore key. Layouts are also tagged with your monitor
arrangement and only restore when the same displays are connected, so
unplugging a monitor won't scatter your windows.

Layouts are stored at
`~/Library/Application Support/WindowSnap/layouts.json`.

## Default shortcuts (⌃⌥ = Control + Option)

← → ↑ ↓ halves · U/I/J/K corners · D/F/G thirds · ↩ maximize · C center · S save layout

## Notes

- Built as a Swift Package — no Xcode project file needed.
- Edit `Icon.svg` to change the icon, then delete `Icon.icns` and rebuild.
