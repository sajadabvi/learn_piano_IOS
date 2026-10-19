#!/bin/bash
# Compiles Core for macOS together with scripts/corecheck/main.swift and runs the self-checks.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/learnpiano-corecheck"
xcrun swiftc -swift-version 5 -O -o "$OUT" LearnPiano/Core/*.swift scripts/corecheck/main.swift
"$OUT"
