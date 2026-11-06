# macOS capture and paste permissions

ScribbleEverywhere needs Screen Recording to capture windows and Accessibility
to inspect targets and post paste shortcuts. Grant these in System Settings →
Privacy & Security, then relaunch the app in your local desktop session.

## If capture or paste stops working

1. Use **Check Permissions** in the app menu to inspect the current grant state.
2. Confirm that the app bundle you launched is the one listed in System Settings.
3. If you rebuilt or changed the signature, macOS may require a new grant.
4. Check that the selected window still exists and that the paste destination
   accepts images.

## Local signing

The build script prefers an existing local identity named `Palimpsest Ink` and
otherwise attempts ad-hoc signing. Changes to a build's signature can affect
permission continuity. Local self-signing does not provide Developer ID
reputation or notarization.

The optional `scripts/make-signing-cert.sh` creates a local code-signing
certificate and private keys, imports them into the login keychain, and trusts
the certificate for code signing in the user domain. Review the script before
running it. It changes local trust settings. Keep the generated files under
`build/signing/` private; never commit or distribute them.

The bundle is assembled under
`~/Library/Application Support/PalimpsestInk/`, outside common synced folders.
File-provider metadata in synced folders can interfere with signing. You can
inspect the bundle with `codesign --verify` and `codesign -dvv`.

## Resetting a stale permission entry

Only if a permission entry is stale, you can reset that app's grants:

```sh
tccutil reset ScreenCapture dev.matthewhand.palimpsest
tccutil reset Accessibility dev.matthewhand.palimpsest
```

These commands revoke the existing grants for this bundle identifier. Relaunch
and grant the required permissions again in the local GUI session. Do not edit
the TCC database directly. Renaming the bundle identifier also changes the
permission identity.
