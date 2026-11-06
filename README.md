# ScribbleEverywhere

![ScribbleEverywhere: draw over a window, then copy or paste the annotated image](docs/images/banner.png)

**Draw over a window. Auto-paste the annotated image where you need it.**

ScribbleEverywhere is a desktop annotation app for **Windows, macOS and
Omarchy/Hyprland**. Mark up what you see with a pen or pointer, then copy,
save or auto-paste the window and your ink into another app.

## What it does

- Draw on a transparent overlay, with pressure-sensitive ink on supported pens.
- Copy the annotated window, save it as an image, or use **Copy & Paste**.
- Auto-paste into a **specific destination**, the **foreground window**, or
  the **previous window**.
- Choose ink colours, undo strokes, clear the canvas, and keep ink between sessions.

## Give an AI chat visual context

Useful when an AI chat accepts images but cannot see or control your computer:
circle a problem, sketch a change, or point at a detail, then paste that context
straight into the conversation.

1. Open **Paste into** and choose your chat app, **Frontmost window**, or
   **Previous window**. A specific destination pins an app on macOS or a window
   on Windows/Hyprland.
2. Start annotating and mark up the window you want to share.
3. Choose **Copy & Paste** to focus the destination and paste the image.

The destination needs to accept image paste. Check the selected destination and
what is visible in the capture before sharing.

![Illustration of annotating a window and sharing the result](docs/images/workflow.gif)

*Conceptual illustration, not a screen recording.*

## Shortcuts

Start/stop: **Ctrl+Alt+D** on Windows, **⌥⌘D** on macOS.
On Hyprland, configure a binding for `scribbleeverywherectl toggle`.

While annotating: **Ctrl+Z** undo, **Ctrl+Backspace** clear, **Ctrl+C** copy,
**Ctrl+Enter** copy and paste, **Esc** stop and keep ink.
Use **⌘** instead of **Ctrl** on macOS.

## Build & run

Build from source with a **Swift 6** toolchain. Setup details and device-specific
behaviour are in [platform notes](docs/PLATFORMS.md).

### Windows x64

Requires Visual Studio 2022 Build Tools with **Desktop development with C++**.
From PowerShell, build, test and install:

```powershell
./scripts/build-windows.ps1 -RunTests
```

Add `-NoInstall` to build/test only, or `-Portable` to create an unsigned ZIP.

### macOS 14+

```sh
./run.sh --build
```

Grant **Screen Recording** for capture and **Accessibility** for targeting/paste.
See [permission troubleshooting](docs/TCC-TROUBLESHOOTING.md).

### Omarchy / Hyprland

Requires Wayland development libraries, `wayland-scanner`, `libpng`,
`grim`, `wl-copy`, `wtype` and a running Hyprland session.

```sh
./scripts/build-linux.sh
```

Add `--applet` for the optional Omarchy/Quickshell bar widget.
Commands install under `~/.local/bin`.

## More information

- [Validation status](docs/VALIDATION.md) and [local checks](docs/CI.md)
- [Package-building instructions](docs/RELEASING.md)
- [Privacy and local storage](docs/PRIVACY.md)
- [Detailed acceptance checklist](TODO.md)

MIT. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).

## Roadmap TODO

- [ ] Publish prebuilt downloads, with dependency notices, checksums and release
      signing/notarization. No release binaries are available yet.
- [ ] Validate Windows MSI install/upgrade/repair/uninstall and portable builds
      on a clean machine.
- [ ] Complete current macOS and Hyprland interactive input, capture and paste checks.
- [ ] Broaden third-party paste, multi-display/mixed-DPI and pen/touch device testing.
- [ ] Add an X11 backend.
