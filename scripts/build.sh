#!/bin/bash
# Generate the Xcode project and build the app.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$ROOT"
xcodegen generate --quiet
build_log=$(mktemp)
trap 'rm -f "$build_log"' EXIT
status=0
xcodebuild -project SoundcorePull.xcodeproj -scheme SoundcorePull -destination 'platform=macOS' \
  -derivedDataPath build build "$@" > "$build_log" 2>&1 || status=$?
grep -E "error:|warning:|BUILD" "$build_log" || true
exit "$status"
