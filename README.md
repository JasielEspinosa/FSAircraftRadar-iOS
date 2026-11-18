# FS Aircraft Radar for iPhone

SwiftUI (iOS 17+) version of the Android app: lists the closest VATSIM or IVAO aircraft (and ATC) to your sim aircraft or to an airport, as a list or on a map. Same data sources, settings and behaviour as the Android app; the map uses Apple Maps.

## Build
There is no Mac here, so the app is built in the cloud: `.github/workflows/build-ios.yml` runs on a GitHub macOS runner (XcodeGen builds the Xcode project from `project.yml`, then `xcodebuild` makes an **unsigned** `.ipa`). It is attached to a GitHub release and to the workflow run. The version lives in `version.txt` (and the first entry of `Changelog.swift`).

## Install on an iPhone
The `.ipa` is unsigned. Sign and install it with [Sideloadly](https://sideloadly.io) or AltStore using your Apple ID (a free Apple ID works, but the app must be re-signed every 7 days; the paid Apple Developer Program lifts that and allows TestFlight).

## Not in v1.0.0
- "All routes" on the map (the route of the tapped aircraft is shown).
- The built-in default IVAO API key of the Android build: add your own key in Settings.
- A custom app icon.
