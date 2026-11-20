# TODO

- [x] 1. Rebrand to "ScribbleEverywhere"
  - [x] Rename product/target/module/bundle/display name
  - [x] Bundle ID dev.matthewhand.scribbleeverywhere
  - [x] Update README, LICENSE, Info.plist, scripts, menu/log strings
  - [x] the old name no longer appears anywhere in the tree (`rg -i` finds nothing)
  - [x] README name note (page written over, earlier text still shows through)
- [x] 2. Cross-platform architecture
  - [x] `ScribbleEverywhereCore` library, Foundation only
  - [x] `ScribbleEverywhereCoreTests` covering all pure logic (37 tests, green)
  - [x] Platform protocols: OverlayHost, ScreenCapturer, HotkeyRegistrar, ClipboardWriter, Paster, PenInputSource
  - [x] macOS app target implements them
  - [x] `scripts/check-core.sh` (no platform imports; builds Core) — passes
  - [x] Linux Core build — `swift test --filter ScribbleEverywhereCoreTests` 70 tests
        green on this Surface Book (Swift 6.2.1)
  - [x] docs/PLATFORMS.md roadmap (macOS, Windows, Linux X11, Linux Wayland)
- [x] 3. High
  - [x] Mouse strokes fixed 4pt; pressure only for tablet events; Core + test
  - [x] README honest status, accurate file layout, build instructions
- [x] 4. Medium
  - [x] Retina scale via `backingScaleFactor`
  - [x] Copy & Paste: await activation with timeout; `yieldActivation` + `activate`; AX check
  - [x] Undo/Clear menu enabled state from controller
  - [x] Overlay does not cover the menu bar (level = mainMenu - 1, visibleFrame)
  - [x] Menu shows current hotkey; restore previous hotkey on failed re-register
  - [x] tabletPoint/tabletProximity handling (still untested with a real pen)
  - [x] macOS controller/overlay `@MainActor`; no concurrency warnings
  - [x] Ask Accessibility once at launch
- [x] 5. Low
  - [x] Exclude own windows from primary lookup (own pid + layer 0)
  - [x] Log ScreenCaptureKit error before fallback
  - [x] Put PNG data on pasteboard too
  - [x] Redraw only changed area (invalidate the segment's bounding box)
  - [x] Hotkey handler returns eventNotHandledErr for foreign signatures; install status checked; no silent ⌘
  - [x] No deprecated CGWindowListCreateImage (ScreenCaptureKit only)
  - [x] README: ad-hoc signing re-prompts permissions after rebuild
- [x] 6. README accuracy
  - [x] waltopd link https://github.com/matthewhand/waltop-osx
  - [x] Removed unverified compatibility lists
  - [x] "Tested on" section; "Platforms" section linking docs/PLATFORMS.md
- [x] 7. Finish
  - [x] `swift build -c release` green, no warnings
  - [x] `swift test` green (37 tests)
  - [x] git init (main), logical commits

- [x] 8. Pen input (waltopd)
  - [x] Draw + pressure from `tabletPoint`/`tabletProximity` (verified by injecting
        waltopd-shaped events into a real NSView)
  - [x] Suppress the mouse path while a pen is in proximity (no double strokes)
  - [x] Read pen button bits from `tabletEventPointButtons` via a global CGEvent tap
  - [x] Copy clears the ink and flashes a HUD confirmation
  - [ ] **Blocked on `waltopd`**: it must OR the barrel state into
        `tabletEventPointButtons` (bits 1/2) — currently it writes
        `mouseEventButtonNumber`, which AppKit discards on tablet events — and bind a
        second barrel switch (usage 0x45) for a second button. Not modified here.

- [x] 9. UX / QoL batch
  - [x] Paste Target preference now actually used (`PasteTarget.choose`)
  - [x] Honest HUD: reports copy only, paste success, or paste failure
  - [x] HUD feedback on no-window / no-region / capture failure
  - [x] Stop-with-ink copies (hotkey, menu, barrel 1 unified via `toggleCaptureMode`)
  - [x] Annotation shortcuts: ⌘Z, ⌘⌫, ⌘C, ⌘↩, Esc
  - [x] Settings reachable from the menu (SettingsLink, ⌘,)
  - [x] Stroke end no longer flares to fixed width
  - [x] Pen-button edge resets when the pen leaves proximity
  - [x] Ink palette: 3 defaults + custom colours; barrel 2 cycles; persisted
  - [x] Tests: Palette + edge reset (55 total)

## Not verified

- [x] 10. Clipboard copy never lands (user report) — **confirmed fixed 2026-10-19**
  - Root cause fixed: ad-hoc signing invalidated the TCC Screen Recording grant on
    every rebuild. Now a stable local identity ("ScribbleEverywhere",
    `scripts/make-signing-cert.sh`) signs the bundle, which is staged in
    `~/Library/Application Support/ScribbleEverywhere/` (iCloud xattr detritus in
    Documents blocked codesign). TCC entries were reset; user granted
    Screen Recording + Accessibility once and copy works across rebuilds.
  - Added "Check Permissions" menu item (HUD shows live TCC status).
  - Full post-mortem: docs/TCC-TROUBLESHOOTING.md
- Windows core/shell build (other agents).
- Real tablet pressure end-to-end (Linux `zwp_tablet_v2` is wired, not sampled).
- Multi-display capture and paste.

- [ ] 11. Cross-platform shells (Surface Books)
  - Input architecture documented in docs/PLATFORMS.md: Surface Books use the
    built-in touchscreen/pen (WM_POINTER on Windows, wl_pointer + zwp_tablet_v2
    on Omarchy); this Mac keeps the waltopd shim (waltop-osx).
  - [x] Package.swift conditional targets (ScribbleEverywhereWin, CScribbleEverywhereLinux +
        ScribbleEverywhereLinux) — macOS build untouched
  - [x] Windows scaffold: systray applet, layered overlay, WM_POINTER pen
        input, BitBlt capture, PNG+DIBV5 clipboard, SendInput paste, JSON config
  - [x] Linux scaffold: layer-shell daemon + control CLI, Omarchy bar applet,
        grim capture, wl-copy via libpng C shim, hyprctl+wtype paste
  - [x] Build scripts: scripts/build-linux.sh, scripts/build-windows.ps1,
        scripts/gen-wayland-protocols.sh, scripts/linux-smoke.sh,
        scripts/install-omarchy-applet.sh
  - [x] docs/PLATFORMS.md rewritten with per-device input table + hardware-agent
        testing checklist
  - [x] Linux compile + smoke on this Surface Book (Swift 6.2.1, overlay,
        synthetic stroke, clipboard PNG). Pen pressure and paste not visually
        confirmed. Windows still awaits its hardware agent.
- [x] 12. macOS multi-display: overlay follows the target window's display
  - `DisplayLookup.display(covering:in:)` picks the display (centre-containing,
    then largest overlap) and `AppController.startCapture()` passes its id to
    `OverlayManager.show(onDisplay:)`, which sizes the overlay to that display
    instead of the union. Falls back to the primary display with no target.
  - Paste can never target the applet itself (`PasteTarget.choose(excluding:)`).
  - Version is one value in `ScribbleEverywhereCore.Version`; `scripts/check-version.sh`
    keeps `Info.plist` in step and `scribblectl version` prints it.
- [ ] 13. Roadmap: test XP-Pen 16" (maybe 17") pen display
  - On Linux, `zwp_tablet_v2` should expose it automatically.
  - On Windows, expect HID tablet via WM_POINTER (may need vendor driver off).
  - On macOS, likely needs a waltopd-style shim extension.
