#!/bin/bash
# Fast type-check of Core plus one or more module folders without building the app.
# Usage: scripts/typecheck.sh Notation Audio
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(LearnPiano/Core/*.swift)
for m in "$@"; do FILES+=(LearnPiano/"$m"/*.swift); done
xcrun swiftc -typecheck -swift-version 5 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios18.0-simulator "${FILES[@]}"
echo "typecheck OK: Core ${*:-}"
