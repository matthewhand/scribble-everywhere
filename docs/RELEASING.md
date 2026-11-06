# Release packaging

The intended release downloads are:

| Platform | Intended artifact | Status |
|---|---|---|
| Windows x64 | MSI installer and portable ZIP | Build scripts are available; MSI installation, signing and clean-machine acceptance remain open. |
| macOS | Signed and notarized app archive | Experimental archive script available; distribution signing, notarization and acceptance remain open. |
| Omarchy / Hyprland | Package or archive with install instructions | Experimental archive script available; runtime dependencies and clean-session acceptance remain open. |

Do not publish these as production-ready downloads until their installation,
upgrade, removal and main drawing/capture/paste workflows have been tested on
the target platform. Preserve settings and saved annotations on upgrades and
uninstall. Record checksums and release provenance with published artifacts.

## Windows portable ZIP

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-windows.ps1 -RunTests -Portable
```

The script builds the GUI executable, collects its Swift runtime DLL dependency
closure, and writes `.build/artifacts/ScribbleEverywhere-windows-x64-portable.zip`.
It does not install the app. Its preferences and saved annotations still live in
the user profile, so the ZIP is portable in the sense of requiring no installer,
not in the sense of keeping user data beside the executable. The current build
is unsigned and needs clean Windows-machine verification.

## Windows MSI (experimental)

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-msi.ps1
```

This builds and tests the portable ZIP, then builds an unsigned, per-user MSI
at `.build/artifacts/ScribbleEverywhere-windows-x64.msi`. It downloads a pinned
WiX 3.14.1 tool archive into `.build/tools` and checks its SHA-256 before use.
An existing WiX tool directory may be supplied with `-WixBinPath`; an existing
portable archive may be used with `-SkipBuild`. `-WorkRoot` and `-OutputDirectory`
allow scratch space and artifacts to be placed on another writable drive.
With `-SkipBuild`, `-PayloadDirectory` can reuse an already-extracted, trusted
portable payload on a low-space workstation; it must correspond to the build
being packaged. Normal builds extract the ZIP themselves.

The MSI has a stable upgrade identity, installs under the current user's local
app data and creates a Start menu shortcut. It does not create an autostart
shortcut or remove saved annotations and settings. Installation, upgrade and
uninstall have **not yet been validated**; test on a clean machine and an
existing Palimpsest Ink installation before release.

On 6 November 2026 an MSI linked with WiX validation enabled. Database checks
confirmed the product name, version, upgrade identity, 20 packaged files and
HKCU registry key paths for all 22 components. The expected ICE91 warnings
describe its deliberate per-user installation scope. This is a package-build
check, not an install/upgrade/uninstall acceptance pass.
Run `powershell -ExecutionPolicy Bypass -File scripts/check-msi.ps1` to repeat
the read-only database check on a built MSI.

## macOS archive (experimental)

On a Mac, build the app with `./scripts/make-app.sh`, then run
`bash scripts/package-macos.sh`. The archive contains a
`ScribbleEverywhere.app` bundle and a SHA-256 file is written beside it. This
retains the existing bundle identifier and signing identity to preserve
preferences and permission continuity. The script checks the existing code
signature, but it does not provide Developer ID signing or notarization. The
renamed archive bundle has not been tested on a Mac.

## Omarchy / Hyprland archive (experimental)

On Linux, run `bash scripts/package-linux.sh`. It builds the executable and
creates a tarball with new and legacy command names, the optional bar widget,
and a SHA-256 file. It is not self-contained: compatible Swift and system
runtime libraries and the documented Wayland/Hyprland tools are required. Use
`--binary PATH` only when packaging a binary already built for the target
architecture. Neither installation nor clean-session use has been verified.
