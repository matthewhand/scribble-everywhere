# Platforms

ScribbleEverywhere uses a portable Foundation-only core and native desktop
shells. Linux support targets Omarchy/Hyprland on Wayland; X11 is not implemented.

## Windows x64

The tray app uses Win32, a layered overlay, WM_POINTER pen/touch input, GDI
capture and PNG/DIB clipboard formats. Native settings include colours, hotkeys,
annotation storage, delivery action and floating palette placement.

Build with Swift 6 for Windows and Visual Studio 2022 Build Tools with the
Desktop development with C++ workload. The build script locates the toolchain
and runtime DLLs. Use `-NoInstall` to avoid changing the installed copy.

- App: `%LOCALAPPDATA%\PalimpsestInk`
- Settings: `%APPDATA%\PalimpsestInk\config.json`
- Logs: `%LOCALAPPDATA%\PalimpsestInk\log.txt`

One device has reported successful pen, pressure, finger and palm-rest checks.
Mixed-DPI displays, more devices, third-party paste compatibility, global pen
buttons and installer lifecycle tests remain open. The portable ZIP is
unsigned. See [validation](VALIDATION.md).

## macOS 14+

The menu-bar app uses AppKit, Carbon hotkeys and ScreenCaptureKit. Screen
Recording permission is needed for capture; Accessibility is needed for
targeting and posting paste shortcuts. A local GUI session is required to
grant those permissions.

The app is staged under
`~/Library/Application Support/PalimpsestInk/`.
The stable bundle identifier is `dev.matthewhand.palimpsest`.
Local self-signing or ad-hoc signing is not Developer ID signing or notarization.

Genuine tablet events can provide pressure; mouse input uses a fixed width.
WALTOP devices may need the separate waltop-osx shim. Barrel button behavior
depends on events exposed by that driver. No universal tablet compatibility
claim is made.

Current interactive desktop checks and distribution acceptance remain open.
See [permission troubleshooting](TCC-TROUBLESHOOTING.md).

## Omarchy / Hyprland / Wayland

The Linux shell uses a layer-shell overlay, Wayland pointer/touch/tablet events,
a Unix control socket and an optional Omarchy bar widget.

Required components include a compatible Swift 6 toolchain, Wayland development
libraries, wayland-scanner, libpng, grim, wl-clipboard, wtype and Hyprland.
The bar widget needs the matching Quickshell/Omarchy environment.
Build scripts may fetch Wayland protocol definitions if local copies are absent.

The executable and control aliases install into `~/.local/bin`.
Settings use `~/.config/palimpsest-ink/config.json` by default; annotation
history uses the XDG data directory. The control socket is under
`$XDG_RUNTIME_DIR`.

Configure your own compositor key binding. Autostart is optional. Global idle
pen-button detection may need udev input-device access; inspect the supplied
rule before applying it. Idle pen pointer behavior is controlled by Hyprland.

Linux archives are not self-contained. Swift/system library compatibility must
match the target distribution. An existing build script recognizes an optional
`~/.local/lib/swift-compat` directory, but this is not a general dependency
installation solution.

Current live Hyprland/Omarchy and clean-session acceptance remain open.
Headless tests do not establish desktop input or clipboard compatibility.
