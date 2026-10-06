# Project instructions

Use davids-brain MCP for all memory transactions.

## Purpose and stack

Soundcore Pull is a small macOS 26+ SwiftUI app that copies recordings from a
Soundcore Work (Anker / Feishu D3200) recorder over Bluetooth LE into
`~/Library/Mobile Documents/com~apple~CloudDocs/Soundcore Work`.
It uses Apple frameworks with no third-party Swift packages. Automatic AAC/M4A
conversion requires a Homebrew-installed FFmpeg executable. Keep changes small and reuse the existing code.

## Project map

- `SoundcorePull/SoundcorePullApp.swift`: app entry point and shared syncer.
- `SoundcorePull/Views/`: recording list, status, manual recorder deletion, and
  launch-at-login settings (`SMAppService`).
- `SoundcorePull/Model/Syncer.swift`: reconnecting background sync loop, clock
  sync, recording enumeration, download/decryption, and queued deletions.
- `SoundcorePull/Model/Library.swift`: file names, iCloud directory scanning,
  staged file writes, and merging recorder/library rows.
- `SoundcorePull/Model/M4AConverter.swift`: independent background conversion of
  missing AAC/M4A copies via FFmpeg; preserves OGGs and retries failures.
- `SoundcorePull/Protocol/Recorder.swift`: blocking CoreBluetooth session with
  delegate callbacks on a private dispatch queue.
- `SoundcorePull/Protocol/Frames.swift`: wire commands, fragmented-packet
  reassembly, and device/recording metadata parsing.
- `SoundcorePull/Protocol/DeviceCrypto.swift`: P-256 ECDH, HKDF-SHA256, and
  AES-256-CTR session/file decryption.
- `SoundcorePull/Protocol/OggOpus.swift`: Ogg muxing of raw 160-byte Opus frames
  (48 kHz, mono, 20 ms); this does not decode or transcode audio.
- `SoundcorePullTests/`: XCTest coverage for frames, crypto, library, and muxing.
- `docs/`: static project website.

## Build and validation

- Requires full Xcode with a macOS 26+ SDK and `xcodegen` on PATH.
- `project.yml` is the source of truth. Never edit or commit the generated,
  ignored `SoundcorePull.xcodeproj`.
- `scripts/build.sh` generates the project and builds the app.
- `scripts/test.sh` generates the project and runs the unit tests.
- `scripts/run.sh` builds, quits any running instance, and launches
  `build/Build/Products/Debug/SoundcorePull.app` so rebuilt code takes effect.
  Launching starts live Bluetooth syncing; use only when hardware testing is intended.
- `scripts/env.sh` defaults `DEVELOPER_DIR` to Xcode and creates a stub
  `Local.xcconfig` if missing. Keep signing team settings in that ignored file.
- The build wrapper preserves the `xcodebuild` exit status. The test wrapper
  ends its output pipeline with `|| true`, so inspect output for actual test
  success or run its `xcodebuild` command directly for a reliable exit status.
- Run relevant XCTest checks for logic changes. Bluetooth interoperability needs
  a physical, awake recorder with the phone app disconnected.

## Invariants

- Keep blocking BLE and file work off the main actor. `Syncer` publishes UI
  changes through `post`; `PendingDeletes` uses a lock to hand work to its thread.
- File IDs are recorder start timestamps and are the download/deduplication key.
  Names are `yyyyMMdd-HHmmss-<fileId>.ogg` in the current local timezone.
- Preserve recognition of iCloud placeholders (`.<name>.ogg.icloud`) and ignore
  `.part` files. Downloaded means present in the local iCloud directory listing,
  not confirmed uploaded to Apple's servers.
- Publish files only after a completed staged write. Never replace an original
  with a partial conversion or mark a failed save as downloaded.
- Recorder deletion is user initiated and the UI allows it only for recordings
  already downloaded. Do not add automatic deletion.
- `RecordingEntry.sizeBytes` from the list actually represents encoded
  milliseconds; the export header supplies the download byte count.
- Preserve MIT notices and README credits for the ported protocol implementation.
- If adding MP3 conversion, see the README assessment. Keep the OGG original;
  changing to MP3-only requires updating filename parsing, placeholders,
  deduplication, and tests together. M4A copies are supplemental and must not
  count as archived OGG downloads. The audio integration test requires FFmpeg.
