#!/bin/bash
# Regenerate LearnPiano.xcodeproj from project.yml (run after adding/removing files).
set -euo pipefail
cd "$(dirname "$0")/.."
XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo "$HOME/.local/tools/xcodegen-dl/extracted/xcodegen/bin/xcodegen")}"
"$XCODEGEN" generate --quiet
