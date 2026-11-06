# Local validation

This public source preview has no hosted CI workflows. Publishing or pushing
to this repository does not launch project-provided hosted jobs.

## Checks

On macOS or Linux, `bash scripts/validate-native.sh` checks test discovery,
runs the core and host-shell tests, and builds the release product without
installing it. Linux also runs a headless PNG/HUD self-test.

`bash scripts/check-version.sh` compares the shared version with Info.plist.

`bash scripts/check-packaging.sh` checks Linux archive contents, command
aliases, checksums and rejection of invalid input using a synthetic executable.
It does not build or exercise the desktop app.

On Windows, use:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-windows.ps1 -RunTests -NoInstall
```

The MSI pipeline is described in [release packaging](RELEASING.md).

Native build success does not establish signing, notarization, clean-machine
installation, hardware input or interactive desktop acceptance.
