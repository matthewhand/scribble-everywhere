# Validation status

Updated 6 November 2026. This is an experimental source preview.

## Evidence carried into this public snapshot

The following results are recorded in the development validation ledger. They
are historical evidence, not fresh test runs of the public snapshot:

- **Windows:** 108 native tests and a release GUI build passed. An extracted
  portable build started an isolated validation canvas with a system-only PATH.
- **Windows interaction:** an isolated mouse drawing, undo, Escape and
  capture/paste check passed on one display. The user separately reported fast,
  clean pen tracking, pressure response, finger input and a palm-rest check
  without stray or stuck ink on one device.
- **macOS:** an earlier native run passed 110 tests and a release build.
- **Linux:** an earlier native run passed 109 tests, a release build, a headless
  self-test and a QML syntax check.
- **Windows MSI:** WiX validation and database checks passed for a package with
  20 files and 22 components. This did not test installation.

The physical-input report is qualitative and device-specific. It does not
establish measured latency, universal palm rejection, other digitizers or the
global pen-button hook.

## Publication checks

The public source is exported without private Git history, internal issue/run
links, device logs, captures or account-specific operational notes. Existing
source licensing and the vendored protocol notice are preserved. Illustrations
are conceptual artwork, not user screenshots.

Publication-local checks passed on 6 November 2026: version consistency, shell
syntax, ShellCheck at error severity, XML/plist/SVG parsing, relative Markdown
file links, and synthetic Linux packaging fixtures (contents, aliases, checksum
and invalid-input rejection). The banner checksum matched its reviewed original.
No Swift toolchain was available for a native full build in this publication
environment. No hosted CI or native full-build pass is claimed for the first
public commit.

## Remaining acceptance work

- Windows MSI install, upgrade, repair and uninstall on clean and existing
  installations, with settings and annotations preserved.
- Clean-machine Windows portable runtime verification and signing.
- macOS current interactive capture, menus, settings, paste and permission
  behavior; Developer ID signing and notarization for distribution.
- Linux current live Hyprland/Omarchy draw, menu, history, settings and paste
  checks; runtime dependency and clean-session verification.
- Mixed-DPI and multiple displays, hotplug and layered windows.
- Third-party destination apps and clipboard formats.
- Additional pen/tablet devices, pressure ranges, touch and global pen buttons.
- Repeat all relevant checks after code or packaging changes.

See [platform notes](PLATFORMS.md) and [packaging](RELEASING.md).
