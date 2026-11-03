# Code signing

`make app` signs `dist/Molly.app` with the first keychain identity matching
`CODESIGN_IDENTITY` (default `Developer ID Application`), hardened runtime,
a secure timestamp, and `packaging/Molly.entitlements`. If no such identity
exists it falls back to an ad-hoc signature and prints a warning.

## Why it matters

macOS privacy grants (Full Disk Access, Accessibility, Screen Recording,
Automation) are keyed to the app's *designated requirement*. With a
certificate that requirement is the certificate chain plus the bundle id,
which is stable. With an ad-hoc signature it is the binary's content hash,
so every `make install` silently invalidates the grants: System Settings
still shows Molly as enabled, but the daemon logs
`not readable (missing file or Full Disk Access)` for Messages, Notes,
Calendar, Screen Time and Safari history until you remove and re-add the app.

Check what you have:

```sh
security find-identity -v -p codesigning     # lists usable identities
make verify-signature                        # prints the designated requirement
```

A stable signature shows `designated => identifier "com.aschepis.molly" and
anchor apple generic and certificate leaf[...]`. An ad-hoc one shows only
`cdhash H"..."`.

## Choosing an identity

```sh
make app                                            # default: Developer ID Application
make app CODESIGN_IDENTITY="Apple Development"      # a development certificate
make app CODESIGN_IDENTITY="Molly Dev"              # a self-signed code-signing cert
make app CODESIGN_IDENTITY=-                        # force ad-hoc
```

A self-signed certificate is enough for a machine you own: Keychain Access,
Certificate Assistant, Create a Certificate, type "Code Signing". It gives a
stable identity but Gatekeeper will still warn on other Macs.

Switching identities changes the designated requirement once, so after the
first signed install remove Molly from Full Disk Access, add it back, and
restart the daemon:

```sh
launchctl kickstart -k gui/$(id -u)/com.aschepis.molly
```

## Entitlements

`packaging/Molly.entitlements` turns the sandbox off (Molly reads other apps'
databases) and declares the hardened-runtime resource access the collectors
use: calendars, network client and server, microphone and camera presence
checks, Bluetooth. Entitlements declare intent only; the user still grants
each permission in System Settings.

## Notarization (optional)

Only needed to hand the app to another Mac without Gatekeeper warnings.
Create the keychain profile once with an app-specific password from
appleid.apple.com:

```sh
xcrun notarytool store-credentials notary-profile \
  --apple-id you@example.com --team-id TEAMID --password app-specific-password
make notarize            # zips, submits, waits, staples dist/Molly.app
spctl -a -vv -t exec dist/Molly.app
```

Override the profile name with `NOTARY_PROFILE=...`.
