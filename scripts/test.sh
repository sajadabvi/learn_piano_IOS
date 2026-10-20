#!/bin/bash
# Run unit tests on the iPad Air 13-inch simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${SIM_DEST:-platform=iOS Simulator,id=70782AF7-0BCC-4E46-B02B-227EE8F4F026}"
xcodebuild -project LearnPiano.xcodeproj -scheme LearnPiano -destination "$DEST" \
  -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test "$@" 2>&1 | tee build/last_test.log | grep -E "error:|Test Case.*(passed|failed)|Executed|TEST (SUCCEEDED|FAILED)" || true
