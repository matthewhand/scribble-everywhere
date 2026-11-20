# Platforms

ScribbleEverywhere is built as a portable core (`ScribbleEverywhereCore`, Foundation only) plus
a thin platform shell that implements the core protocols (`OverlayHost`,
`ScreenCapturer`, `HotkeyRegistrar`, `ClipboardWriter`, `Paster`, `PenInputSource`).

Legend: [x] done, [~] scaffolded (code written, needs a real machine to compile/test),
[ ] not started.

## Input architecture (per device)

| Machine                  | Ink source                                     | Notes |
|--------------------------|------------------------------------------------|-------|
| Surface Books (primary)  | Built-in touchscreen / pen, `WM_POINTER` on Windows | No external daemon; Windows Ink pressure via `POINTER_PEN_INFO.pressure` |
| Surface Books (Omarchy)  | Built-in touchscreen via `wl_pointer`, pen via `zwp_tablet_v2` | libinput handles the digitizer; Hyprland routes tablet events |
| This Mac                 | Waltop tablet via `waltopd` shim (waltop-osx project) | Barrel1 = toggle/copy/paste, Barrel2 = clear; pressure passthrough |
| Later: XP-Pen 16"/17"    | Untested — roadmap item                        | Likely HID tablet protocol; on macOS may need waltopd extension, on Linux `zwp_tablet_v2` should just work |

## macOS — current

Current finishing changes fix delivery failure gating, login/hotkey rollback,
ink retention and interrupted contacts. The native Apple Silicon CI release
build and 86 tests (79 Core + 7 Mac) pass with Apple Swift 6.3.3. Current
interactive device behavior remains unverified. See [VALIDATION.md](VALIDATION.md).

- [x] Menu-bar applet (`MenuBarExtra`, `LSUIElement`)
- [x] Transparent click-through overlay just below the menu bar
- [x] Global hotkey (Carbon `RegisterEventHotKey`)
- [x] Capture via ScreenCaptureKit `SCScreenshotManager` (macOS 14+)
- [x] Copy & Paste: reactivate target, wait for activation, post ⌘V via `CGEvent`
- [x] Pressure for genuine tablet events; fixed width for mouse
- [x] Stable code-signing identity ("ScribbleEverywhere") so TCC grants survive rebuilds
- [x] Multi-display: the overlay follows the captured window's display
      (`DisplayLookup.display(covering:in:)`), instead of always display 0. No
      second monitor was attached here to exercise it end-to-end.

## Windows — current Surface Book release

Validated 1 November 2026 with Swift 6.4.1 and VS Build Tools. The agent ran
`scripts/build-windows.ps1 -RunTests`: **95 tests in 18 suites** passed (79 Core,
16 Windows), followed by a release GUI build and installation with runtime DLLs.
The installed executable matches the build hash. Tests use the native backend
because swiftbuild discovered zero cases; discovery is now checked explicitly.

- Accessible owner-draw tray menu with swatches, checks and nested commands.
  Real rendering and keyboard/mouse delivery-action selection passed at 200%
  scale. Windows system colours keep native arrows/separators readable.
- Native Settings for arbitrary colours/names, global hotkey, annotation folder,
  delivery action, autosave, paper tone and floating palette placement. Custom
  colour/name saving was verified through the UI and persisted config.
- Layered primary-display overlay: mouse drawing, undo, clear, Escape retention
  and global-shortcut reopening passed interactively. Pen/finger WM_POINTER
  handling is compiled and its ownership/cancel/hover/lift transitions tested.
  Physical feel remains pending. Valid pen pressure uses the documented 0–1024
  range, with raw-sample logging and clamping.
- Capture/composite, PNG/CF_DIB/CF_DIBV5 clipboard and automatic focus/paste passed
  into an isolated receiver that visibly displayed the annotated 3240×2125 image.
  Paint/Word/browser compatibility remains unverified.
- Existing config migration, atomic writes, custom focused-hotkey matching,
  history folder updates and startup `/startup` handling are implemented.
  Real scratch COM shortcut tests cover quoted paths and selective legacy
  migration; a full login cycle remains pending.

Build/install: `scripts/build-windows.ps1` locates Swift and VS Build Tools,
checks the GUI artifact and copies runtime DLLs beside the installed executable
under `%LOCALAPPDATA%\ScribbleEverywhere`. Add `-RunTests` for discovery and tests;
`-NoInstall` preserves the running app. Settings live at
`%APPDATA%\ScribbleEverywhere\config.json`; logs at
`%LOCALAPPDATA%\ScribbleEverywhere\log.txt`.

Remaining gates: physical pen/finger/pressure/latency, all menu/settings controls,
third-party paste targets, mixed DPI/multiple displays and more tablets.
[VALIDATION.md](VALIDATION.md) records current evidence, rolling scores and the
cross-platform parity matrix. Historical observations do not certify new edits.

## Linux (Omarchy / Hyprland / Wayland) — feature-complete for Omarchy on this Surface Book

Current validation: release build, 93 tests (79 Core + 14 Linux) and PNG/HUD
self-test pass under WSL Ubuntu 24.04 and independently in Linux CI with
Swift 6.0.3. Delivery, config,
contact cancellation/ownership and pressure-lift fixes are covered. A current
Hyprland UI/device pass remains pending; the device notes below are historical.

Build: `scripts/build-linux.sh` (runs `scripts/gen-wayland-protocols.sh` first).
Sources in `Sources/ScribbleEverywhereLinux/` + `Sources/CScribbleEverywhereLinux/` (libpng +
Wayland session). Toolchain used here: Swift 6.2.1 official ubi9 tarball under
`~/.local/share/swift`, with RHEL 9 sonames in `~/.local/lib/swift-compat`
(`libncurses.so.6`, `libxml2.so.2`, `libpython3.9.so.1.0`) because Arch's
libraries do not match. `scripts/linux-smoke.sh` passed: overlay mapped,
synthetic stroke, clipboard PNG 2968×1300. Pen drawing and barrel toggle/paste
were used on this Surface Book (not only the smoke path).

- [x] Single binary `scribble` / `scribblectl`: `daemon` subcommand +
      control CLI over a Unix socket (`$XDG_RUNTIME_DIR/scribble.sock`)
- [x] Omarchy bar applet: `packaging/omarchy/matthewh.scribbleeverywhere`, installed
      by `scripts/install-omarchy-applet.sh` / `build-linux.sh --applet`. Left
      click toggles, right click opens the settings popup, middle click pastes.
      Two `Process` objects ping-pong so a second click can stop annotation
      while the first `scribblectl` is still running. `status --waybar` JSON
      still exists for a Waybar fallback
- [x] Overlay: `zwlr_layer_shell_v1` overlay layer, one surface per output,
      ARGB8888 shm buffer redrawn from the stroke model (`BufferInkCompositor`).
      Keyboard interactivity is `ON_DEMAND` so Esc/Ctrl+Z work on the overlay
      without an exclusive grab that would swallow clicks on the bar. On this
      machine: 1500×970 logical at (0,30), buffer 3000×1940, scale 2, 30 px top
      margin so the bar stays clickable
- [x] Input: `wl_pointer` + `wl_touch` + `zwp_tablet_v2` listeners filled for
      libwayland 1.26 (including `wl_seat.name` and `wl_pointer.warp`). Esc /
      Ctrl+Z / Ctrl+Backspace / Ctrl+C / Ctrl+Enter while annotating. Surface
      Pen: evdev `BTN_STYLUS` 0x14B toggles while the overlay is hidden;
      tablet-v2 0x14B toggles and 0x14C clears while annotating. Pen drawing
      and barrel toggle/paste were used on this machine. Pressure is wired;
      the numeric range was not sampled
- [x] Capture: hide overlay, `grim -t ppm -g "<global rect>" -`, PPM decoder,
      PaperTone on capture (default on), composite ink
- [x] Clipboard: `wl-copy -t image/png` from the libpng C shim. Smoke decoded a
      PNG signature and IHDR. `wl-copy` keeps a helper process alive to serve
      the clipboard; the daemon does not wait on it
- [x] Paste: `hyprctl dispatch focuswindow address:…` then
      `wtype -M ctrl v -m ctrl`. Visually confirmed: barrel stop pastes into
      the previous window when the delivery action is copy-and-paste
- [x] Delivery action (default `copyAndPaste`): stop with ink copies and pastes
      into the previous window. Action `clipboard` copies only. The paste-into
      menu is shown only when the action is copy-and-paste
- [x] Save: PNGs under `~/.local/share/scribble/annotations` (XDG). HUD
      save control and `scribblectl save`. History list in the bar popup
- [x] Palette: add / remove / rename from the popup. Floating HUD swatches +
      clear + save are composited into the layer-shell surface. Confirmations
      after copy use `notify-send`
- [x] Autostart: `scribblectl autostart` writes
      `~/.config/autostart/scribble.desktop`. On this machine
      `~/.config/hypr/autostart.lua` already starts the daemon (not edited as
      part of this shell work)
- [x] Hotkey: `SUPER + ALT + D` is a Hyprland bind already in this machine's
      `bindings.lua` → `scribblectl toggle`
- [x] Idle pen pointer behaviour is controlled by Hyprland. The app reports
      that limitation and no longer exposes an ineffective toggle (current source;
      native retest pending). Ink now survives Copy/Escape, matching the other shells
- [ ] Gaps still open: no second monitor attached, so multi-display was not
      tested; tablet pressure range unmeasured. Current headless shell regression tests are
      listed in VALIDATION.md; they do not replace native device checks

## Linux — X11 — not started

Kept for reference; Omarchy is Hyprland/Wayland, so X11 support is unlikely to
be needed. Original notes:

- [~] Shell: override-redirect window sized to the root, `Shape`/ARGB visual
- [~] Input: `XInput2`; hotkey `XGrabKey`; capture `XGetImage`/`XComposite`;
      paste via `XTEST`

## Shared work

- [x] `ScribbleEverywhereCore`: geometry, coordinates, capture geometry, stroke model,
      pressure rules, hotkey model/display, paste-target choice, image buffer,
      ink compositor, platform protocols
- [x] `ScribbleEverywhereCoreTests` (runs on any Swift platform)
- [x] `scripts/check-core.sh` (forbids platform imports in the core, builds it alone)
- [x] Conditional targets: Windows/Linux targets only exist on their host OS,
      so the macOS build is untouched

## Testing checklist for hardware agents

1. Build (`scripts/build-linux.sh` / `scripts/build-windows.ps1`); fix compiler
   errors in the platform shell only — never touch `Sources/ScribbleEverywhereCore/`.
2. Overlay appears on the correct display and covers the screen.
3. Draw with pen: pressure-varying width; draw with finger/mouse: fixed width.
4. Esc / second toggle stops; ink copied to clipboard; paste into a text field
   inserts the image.
5. Undo (Ctrl+Z), colour cycle, clear.
6. Waybar module shows state on Omarchy; tray icon reacts on Windows.
