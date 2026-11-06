# Privacy and local storage

ScribbleEverywhere captures the selected window and composites your ink onto it.
A window can contain names, messages, documents, financial information or other
sensitive content. Review the window before capturing it.

- Copy places the image on the system clipboard.
- Copy and paste also delivers it to the selected app using that platform's
  paste shortcut. The receiving app may upload, sync or share it under its own
  settings and privacy policy.
- Save and autosave can write annotation images to the configured local folder.
  A folder may itself be synced by another application.
- Settings, history and diagnostic logs remain in platform-specific user
  locations. Logs can include operational details; review them before posting.
- The app contains links that open the project repository and issue tracker
  in your browser. Build tools may download public dependencies.

The reviewed source snapshot does not include an analytics or automatic
capture-upload client. This is a source-review observation, not a security
certification or a promise about destination apps, clipboard managers or
system sync services.

Accessibility, Screen Recording and input-device permissions are powerful.
Grant only those needed for your use. The optional macOS signing helper creates
and trusts a local code-signing identity; keep its private keys private.
Never commit your captures, settings, logs, certificates or signing keys.
