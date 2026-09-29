# Soundcore Pull

Small macOS app that copies recordings off a Soundcore Work (Anker / Feishu D3200) AI voice
recorder over Bluetooth LE into iCloud Drive › Soundcore Work. No phone, no account, no cloud
service. Output is Ogg/Opus, a lossless copy of what the device stores.

SwiftUI, macOS 26+, no third-party packages. The Xcode GUI is never opened.

Website: https://knorthfield.github.io/soundcore-pull/

## What it does

Leave the app open. When the recorder is awake and not held by the phone, the app connects,
lists its recordings, and pulls anything not already in the iCloud folder. It re-checks every
15 seconds. The toolbar has Show in Finder and Delete from Recorder (only for recordings that are
already in iCloud).

Files are named `yyyyMMdd-HHmmss-<fileId>.ogg`. The file id is the recording's start time as a
Unix timestamp, and it is what marks a recording as already downloaded.

## Build and run

- `project.yml` is the source of truth; `SoundcorePull.xcodeproj` is generated and git-ignored.
- `scripts/build.sh` — xcodegen + build.
- `scripts/run.sh` — build, then launch the app.
- `scripts/test.sh` — unit tests.
- `Local.xcconfig` (git-ignored) holds `DEVELOPMENT_TEAM`; `scripts/env.sh` creates a stub.

First launch asks for Bluetooth permission. Signing asks for the keychain password for the
Apple Development key; choose Always Allow once.

Settings (⌘,) has Launch at login. It points at the app where it was last registered, so after
cleaning `build/` turn it off and on again.

## Icon

`SoundcorePull/AppIcon.icon` is a hand-written Icon Composer bundle: the case is the icon
background (white in light mode, charcoal in dark mode), with the round mic, its LED and an `icloud.and.arrow.down.fill` symbol as Liquid Glass
layers. `swift scripts/render-icon-assets.swift` regenerates the PNG layers. Preview with
`"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
SoundcorePull/AppIcon.icon --export-image --output-file out.png --platform macOS --rendition Dark
--width 512 --height 512 --scale 1` (`xcrun ictool` is a different binary).

## Recorder notes

- It does not advertise while asleep in the case or while connected to the phone. Take it out of
  the case or tap it, and close the Soundcore app on the phone.
- USB on the case is charge-only.
- Protocol layout: `SoundcorePull/Protocol` (frames, ECDH/HKDF session, AES-CTR file decryption,
  Ogg/Opus muxing, blocking CoreBluetooth session). The sync loop is `Model/Syncer.swift`.

## Credits

The protocol comes from community work, not from this project:

- [tacshi/Soundcore](https://github.com/tacshi/Soundcore) documented the D3200 protocol
  (`PROTOCOL.md`) from the Anker SDK inside the Feishu Android app. Used as reference only.
- [Shawn-TKD/recording-bean-web](https://github.com/Shawn-TKD/recording-bean-web) (MIT) is a
  browser client for the same recorder. The framing, key exchange, chunk decryption and Ogg muxing
  here are a Swift port of its logic. Its notice: Copyright (c) 2026 Recording Bean Local
  contributors, MIT License.

For interoperability with hardware you own.

## Licence

MIT. See [LICENSE](LICENSE). The ported recording-bean-web code is MIT too; see Credits.

### Recorder pairing

On the first connection, Soundcore Pull reads the recorder's device information and
saves its serial number in this Mac's UserDefaults **before** requesting any
recording list or starting a download. Keep only your intended recorder awake and
nearby for this initial pairing. Each later connection must report the same serial;
a different or invalid identity is disconnected without listing, downloading, or
deleting recordings. Rejected Bluetooth identifiers are skipped until the app
restarts or the pairing is forgotten, so another nearby recorder cannot monopolize
scanning. The serial remains the identity check on every accepted connection.

Settings shows **Paired Recorder** and its serial. **Forget Recorder…** confirms
that syncing will stop and the next compatible recorder found will be paired
automatically. Forgetting cancels the active connection, clears queued deletions,
and revokes any in-flight transfer before it can save. Existing iCloud files and
launch-at-login settings are kept. Pairing uses the recorder-reported serial; it
is not cryptographic device authentication.

`./scripts/test.sh` covers pairing persistence, reconnects, rejected/invalid
identities, and forgetting during device info and transfer responses using a fake
transport and isolated UserDefaults. The test scheme disables background syncing
so unit tests do not connect to a physical recorder. To check with hardware, pair
your recorder alone, restart with only a different recorder awake, then wake the
paired recorder and verify syncing resumes. Also check Forget Recorder during a
transfer and confirm Settings displays the newly paired serial afterwards.
