# Molly Health (iOS)

A small SwiftUI app that reads Apple Health on the iPhone and posts daily totals
to Molly's `POST /health` (see [docs/HEALTH.md](../docs/HEALTH.md), section 4).
No analytics, no third-party code, and no network calls other than the server URL
you configure.

```
ios/
  project.yml            XcodeGen spec (bundle id, team, entitlements, Info.plist keys)
  MollyHealth.xcodeproj  generated from project.yml and committed, open it directly
  MollyHealth/           the app: SwiftUI views, HealthKit reader, sync, background tasks
  MollyHealthCore/       SwiftPM package with all logic that does not need HealthKit
```

`MollyHealthCore` holds the type catalog, the day-total computation from plain
sample structs, payload encoding, settings, the post client, the `Uploader`
actor and the backfill planner. It builds for macOS and iOS, so its tests run
with `swift test`. `MollyHealth/HealthReader.swift` is the only file that
imports HealthKit.

## Commands

```sh
make ios-project   # regenerate MollyHealth.xcodeproj from project.yml (needs xcodegen)
make ios-build     # simulator build, no signing
make ios-test      # swift test in ios/MollyHealthCore
make check-health-types   # catalog names must equal the Mac's HealthType
```

Run on a phone from Xcode: pick your team under Signing & Capabilities, select
the phone, press Run. HealthKit, background delivery and the permission flow do
not work in a useful way without a device.

Adding a type means editing the Mac's `HealthType`, the iOS `MollyHealthType`
(same raw value, cases kept contiguous), and the catalog `spec`; the check script
and the catalog test fail until they agree.
