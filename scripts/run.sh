#!/bin/bash
# Install + launch the built app on the booted iPad simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/DerivedData/Build/Products/Debug-iphonesimulator/LearnPiano.app
UDID="${SIM_UDID:-$(xcrun simctl list devices booted | grep -o '[0-9A-F-]\{36\}' | head -1)}"
[ -n "$UDID" ] || { echo "no booted simulator"; exit 1; }
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch --terminate-running-process "$UDID" com.sajadabvi.LearnPiano
