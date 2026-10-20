#!/bin/bash
# Build the app for the iPad Air 13-inch simulator. Usage: scripts/build.sh [extra xcodebuild args]
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${SIM_DEST:-platform=iOS Simulator,id=70782AF7-0BCC-4E46-B02B-227EE8F4F026}"
xcodebuild -project LearnPiano.xcodeproj -scheme LearnPiano -configuration Debug \
  -destination "$DEST" -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build "$@" 2>&1 | tee build/last_build.log | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" || true
tail -n 1 build/last_build.log
