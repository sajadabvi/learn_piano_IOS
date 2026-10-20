#!/bin/bash
# Runs the app's microphone pitch detector (Input module, platform-neutral part) over a WAV file on macOS.
# Usage: scripts/pitchcheck.sh [file.wav]   (default: generates piano-like test notes and chords)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/learnpiano-pitchcheck"; mkdir -p "$OUT"
WAV="${1:-$OUT/test_notes.wav}"
[ -n "${1:-}" ] || python3 -I scripts/pitchcheck/make_tones.py "$WAV"
FILES=(LearnPiano/Input/InputClock.swift LearnPiano/Input/InputNoteTracker.swift LearnPiano/Input/InputPitchDetector.swift \
       LearnPiano/Input/InputPitchPipeline.swift LearnPiano/Input/InputSpectrumAnalyzer.swift)
xcrun swiftc -swift-version 5 -parse-as-library -O -o "$OUT/pitchcheck" LearnPiano/Core/*.swift "${FILES[@]}" scripts/pitchcheck/main.swift
"$OUT/pitchcheck" "$WAV"
