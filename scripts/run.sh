#!/bin/bash
# Build, then launch the app.
set -euo pipefail
source "$(dirname "$0")/env.sh"
"$ROOT/scripts/build.sh"
# `open` otherwise reuses the old process even after rebuilding its executable.
osascript <<'APPLESCRIPT'
if application id "com.krisnorthfield.SoundcorePull" is running then
  tell application id "com.krisnorthfield.SoundcorePull" to quit
  repeat with attempt from 1 to 100
    if not (application id "com.krisnorthfield.SoundcorePull" is running) then exit repeat
    delay 0.1
  end repeat
  if application id "com.krisnorthfield.SoundcorePull" is running then error "Soundcore Pull did not quit; close it and rerun this script."
end if
APPLESCRIPT
open -n "$APP_PATH"
