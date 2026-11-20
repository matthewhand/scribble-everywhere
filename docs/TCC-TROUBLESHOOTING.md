# Troubleshooting TCC permissions (Screen Recording / Accessibility)

This is the post-mortem of the "copy never lands, macOS keeps asking me to
toggle Screen Recording" saga, written so a future agent (or maintainer) can
diagnose it in minutes instead of hours.

## Symptoms

- macOS repeatedly prompts for Screen Recording; toggling it on in System
  Settings appears to succeed but the app still cannot capture.
- Toggling the permission off and back on, relaunching, even rebooting does not
  help.
- `codesign` fails with `resource fork, Finder information, or similar detritus
  not allowed`.
- The app works right after granting, then silently loses the grant after the
  next rebuild.

## Root causes (there were three, stacked)

1. **Ad-hoc signing invalidates TCC grants on every rebuild.** TCC keys
   Screen Recording / Accessibility grants on the app's *code signature*. An
   ad-hoc signature (`codesign --sign -`) has no designated requirement beyond
   the cdhash, which changes with every rebuild — so every rebuild looked like
   a *different app* to TCC and the grant silently stopped applying. The System
   Settings toggle kept editing a stale entry for a binary that no longer
   existed.
2. **No signing identity existed** (`security find-identity -v -p codesigning`
   → 0 valid identities), so the build script had always fallen back to ad-hoc.
3. **The app bundle was assembled inside `~/Documents`.** iCloud FileProvider
   syncs Documents and re-stamps `com.apple.FinderInfo` /
   `com.apple.fileprovider.fpfs#P` xattrs on the bundle, which `codesign`
   refuses to sign over. Worse, `xattr -cr` *appears* to strip them, and
   FileProvider immediately re-adds them, so the failure is non-deterministic.

## The fix (as implemented)

- `scripts/make-signing-cert.sh` — one-time creation of a self-signed local
  code-signing identity (`CN = ScribbleEverywhere`, RSA 2048, 10-year leaf + CA,
  `extendedKeyUsage=codeSigning`), imported into the login keychain and trusted
  for code signing in the user domain (`security add-trusted-cert -p codeSign`,
  no admin required). The script is idempotent and exits early if the identity
  exists. Private keys live in `build/signing/`, which is gitignored — never
  commit or share them.
- `scripts/make-app.sh` — prefers that identity; falls back to ad-hoc with a
  loud warning. Assembles the bundle in
  `~/Library/Application Support/ScribbleEverywhere/`, outside any iCloud-synced
  directory.
- A menu item, **Check Permissions**, prints the live TCC status into the HUD
  (`Screen Recording: granted/denied — Accessibility: granted/denied`) so the
  grant state can be verified without touching System Settings.

After switching signatures, the stale TCC entries were cleared once:

```sh
tccutil reset ScreenCapture dev.matthewhand.scribbleeverywhere
tccutil reset Accessibility  dev.matthewhand.scribbleeverywhere
./run.sh        # relaunch, grant each permission once, done forever
```

## Diagnostic playbook

Work down this list in order:

1. **Does the binary have a stable signature?**
   ```sh
   security find-identity -v -p codesigning          # need "ScribbleEverywhere"
   codesign -dvv "$HOME/Library/Application Support/ScribbleEverywhere/ScribbleEverywhere.app" 2>&1 | grep -i authority
   ```
   `Authority=ScribbleEverywhere` (+ `Authority=ScribbleEverywhere CA`) is correct;
   nothing, or `linker-signed`/ad-hoc, is the bug.
2. **Does the grant survive a rebuild?** Run `./run.sh --build` twice; after
   the second launch, **Check Permissions** must still say `granted`. If it
   flips to denied, the signature changed (see 1).
3. **Is the bundle signable at all?**
   ```sh
   codesign --verify <app>        # "detritus not allowed" ⇒ xattr problem
   xattr -lr <app>                # look for FinderInfo / fpfs / provenance
   ```
   `com.apple.provenance` is system-managed and harmless. `FinderInfo` /
   `fpfs#P` re-added instantly by FileProvider means the bundle is inside an
   iCloud-synced tree — move it out (that is what the Application Support
   staging directory is for).
4. **Are the TCC entries sane for the current signature?** When in doubt:
   `tccutil reset ScreenCapture dev.matthewhand.scribbleeverywhere` and grant once
   more. Prefer `tccutil` over editing `~/Library/Application
   Support/com.apple.TCC/TCC.db` (editing TCC.db needs Full Disk Access and is
   fragile across macOS versions).
5. **Run at the machine.** Over SSH, TCC prompts cannot be displayed to the
   remote session, so grants never associate. Granting must happen in a local
   GUI session.

## Rules for future changes

- Never ad-hoc-sign (`codesign --sign -`) a build that needs TCC permissions
  and will be rebuilt. Use the stable identity, or a real Developer ID if one
  is ever available.
- Never move the assembled bundle back under `~/Documents`, `~/Desktop`, or
  another FileProvider-synced path.
- If permission prompts ever return after a rebuild, suspect the signature
  first (`codesign -dvv`), not the user's settings.
- Renaming the bundle identifier (`dev.matthewhand.scribbleeverywhere`) invalidates
  every existing grant; treat it as a permission reset event.