# Soundcore Pull

Small macOS app that copies recordings off a Soundcore Work (Anker / Feishu D3200) AI voice
recorder over Bluetooth LE into iCloud Drive › Soundcore Work. No phone, no account, no cloud
service. Originals are saved as Ogg/Opus, a lossless copy of what the device stores.
The app also creates AAC `.m4a` copies for dragging into Talat.

SwiftUI, macOS 26+, no third-party packages. The Xcode GUI is never opened.

Website: https://knorthfield.github.io/soundcore-pull/

## What it does

Leave the app open. When the recorder is awake and not held by the phone, the app connects,
lists its recordings, and pulls anything not already in the iCloud folder. It re-checks every
15 seconds. The toolbar has Show in Finder and Delete from Recorder (only for recordings that are
already in iCloud).

Files are named `yyyyMMdd-HHmmss-<fileId>.ogg`, with matching `.m4a` copies. The file id is the recording's start time as a
Unix timestamp, and it is what marks a recording as already downloaded.

## Build and run

- `project.yml` is the source of truth; `SoundcorePull.xcodeproj` is generated and git-ignored.
- `scripts/build.sh` — xcodegen + build.
- `scripts/run.sh` — build, then restart the app so the new code takes effect.
- `scripts/test.sh` — unit tests.
- `Local.xcconfig` (git-ignored) holds `DEVELOPMENT_TEAM`; `scripts/env.sh` creates a stub.

First launch asks for Bluetooth permission. Signing asks for the keychain password for the
Apple Development key; choose Always Allow once.

Settings (⌘,) has Launch at login. It points at the app where it was last registered, so after
cleaning `build/` turn it off and on again.

## M4A copies for Talat

Install [FFmpeg](https://ffmpeg.org/) with Homebrew:

```sh
brew install ffmpeg
```

While the app is open, a separate background worker checks every 15 seconds for OGG
recordings missing M4A copies, including older downloads. It converts them to 96 kbps
AAC in an M4A container, which [Talat accepts](https://talat.app/blog/how-to-transcribe-an-audio-file).
Use **Show in Finder**, then drag the `.m4a` recording into Talat.

The OGG original is kept unchanged. M4A conversion decodes and re-encodes the audio, so
it adds some quality loss; 96 kbps is a starting point for mono speech. Conversion runs
independently of Bluetooth and works even when the recorder is disconnected. Files are
converted one at a time and published only after FFmpeg succeeds. Existing M4A files
and their iCloud placeholders are skipped; evicted OGG originals are requested from
iCloud before conversion. Failures appear in the app and are retried on later passes.

The app looks for FFmpeg at `/opt/homebrew/bin/ffmpeg` (Apple Silicon) or
`/usr/local/bin/ffmpeg` (Intel), so Finder and launch-at-login do not need a shell PATH.
FFmpeg is an external requirement, not bundled into the app. The equivalent manual command is:

```sh
ffmpeg -nostdin -n -i "recording.ogg" -c:a aac -b:a 96k "recording.m4a"
```

The converter's integration test generates synthetic 48 kHz mono Ogg/Opus audio and
checks that the M4A output decodes, originals and existing copies are preserved, failed
conversions leave no partial output, and repaired inputs are retried. It requires FFmpeg
with `libopus` and `aac` encoders. Verify sound quality and Talat import with a real recording.

MP3 is also possible with FFmpeg's `libmp3lame` encoder if needed. macOS's built-in
`afconvert` failed Ogg/Opus decoding and MP3 encoding on the inspected installation;
FFmpeg is the verified conversion route here.

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
