# LearnPiano — Architecture and module contracts

LearnPiano is a native iPadOS 18+ SwiftUI app (single app target `LearnPiano`, Swift 5 language mode on the
Swift 6.2 toolchain, no third-party packages). It is an interactive piano tutor: a song library with
engraved sheet music, synchronized keyboard demonstration and synthesized audio, note recognition from a
MIDI keyboard or the microphone, Wait Mode / Just Play / looping / slow-motion / separate hands, a
structured course curriculum, and import of sheet music found online (MusicXML, MIDI, PDF or image).

This document is the contract between modules. Each module is a folder under `LearnPiano/` and is
implemented independently; **every module depends only on `Core/`**, except where the "wave 2" section
says otherwise. `App/` depends on everything and wires the modules together.

## 1. Module map

| Folder | Responsibility | Consumes | Provides (names are examples; prefix your types with the module noun) |
|---|---|---|---|
| `Core/` | Shared model: pitch/time/score/timeline, input events, practice settings and feedback types, import and validation types, catalog/progress/profile, curriculum. Foundation only. | — | everything below uses it |
| `Notation/` | Engraving (layout) and SwiftUI rendering of the two-staff score with Bravura; cursor, highlights, hand dimming, loop tint, measure selection; horizontal-scroll and page modes. | Core | `NotationLayout`, `NotationScoreView`, `NotationHighlightModel` |
| `Audio/` | Piano synth (AVAudioEngine), timeline player implementing `ScorePlaybackControlling`, metronome implementing `MetronomeControlling`, count-in. | Core | `AudioPianoSynth`, `AudioScorePlayer`, `AudioMetronome`, `AudioSessionConfigurator` |
| `Input/` | CoreMIDI source (USB + Bluetooth pairing), microphone pitch detection source, hub merging sources into `NoteInputEvent`s with held-note tracking. | Core | `InputMIDISource`, `InputMicrophoneSource`, `InputHub`, `InputBluetoothMIDIPairingView` |
| `Practice/` | Practice engine: Wait Mode and Just Play followers, transport, loop, speed, hands, count-in, stats; publishes `FeedbackSnapshot`. Foundation + Observation only. | Core (drives Audio through `ScorePlaybackControlling`/`MetronomeControlling`) | `PracticeSession`, `PracticeWaitFollower`, `PracticeJustPlayFollower` |
| `Keyboard/` | 88-key SwiftUI keyboard: feedback states, demo highlights, falling-note lanes (the "video" replacement), touch input. | Core | `KeyboardView`, `KeyboardLanesView`, `KeyboardRangeFitter` |
| `Parsers/` | MusicXML/MXL, Standard MIDI File, LPC compact JSON → `Score`; `Score` → MusicXML export. Foundation only. | Core | `ParsersMusicXMLImporter`, `ParsersMIDIImporter`, `ParsersCompactScoreImporter`, `ParsersMusicXMLExporter` |
| `Content/` (wave 2) | Loads bundled catalog fragments + MusicXML, the user library under Documents, and the course curriculum; caches parsed scores. | Core, Parsers | `ContentStore`, `ContentCourses` |
| `Library/` (wave 2) | Songs browser (categories, difficulty, search), song detail with arrangement picker, My Songs, progress persistence (`UserProfile` on disk). | Core, Content | `SongsBrowserView`, `MySongsView`, `LibraryProfileStore` |
| `Courses/` (wave 2) | Course list, lesson reader, exercise launcher; the curriculum content itself (text + exercises). | Core, Content, PracticeUI | `CoursesHomeView`, `CoursesLessonView` |
| `Import/` (wave 2) | Import screen: file picker / URL / share-in, PDF+image page rendering, `SheetTranscriptionProvider` via the Claude API, validation + repair loop, review screen, save to user library. | Core, Parsers, Content, Notation (preview) | `ImportHomeView`, `ImportClaudeTranscriptionProvider`, `ImportReviewView` |
| `PracticeUI/` (wave 2) | The practice screen: composes Notation + Keyboard + Practice + Audio + Input with the control bar (play/pause, mode, speed, loop, hands, metronome). | Core, Notation, Keyboard, Practice, Audio, Input | `PracticeScreen`, `PracticeControlBar` |
| `Settings/` (wave 2) | Input source choice, mic sensitivity and A4, Bluetooth MIDI pairing entry, Claude API key (Keychain), model choice, display options, reset progress. | Core, Input | `SettingsView`, `SettingsKeychain` |
| `App/` | `AppModel` navigation + `PracticeRequest`, `ProfileStore` (profile.json), `Theme` tokens. `App/Shell/` holds `LearnPianoApp` (creates and injects the stores) and `RootView` (tabs + practice `fullScreenCover`); only the integrator type-checks Shell. | all | `AppModel`, `PracticeRequest`, `ProfileStore`, `Theme`, `LearnPianoApp`, `RootView` |

Rules that apply to every module:

- One app target: all top-level type names must be unique across the project. Prefix module types with
  the module noun. Bare generic names (`Note`, `Score`, `Event`, `Player`, `Engine`, `Settings`, `Theme`,
  `Timeline`, `Pitch`, `Measure`, …) belong to Core or App and must not be redeclared.
- UI-facing state objects are `@MainActor` and `@Observable` (Observation framework). Heavy work
  (layout, parsing, pitch detection, synthesis) runs off the main thread; results hop back to the main actor.
- No force-unwraps in production paths, no `TODO` stubs, no silent `catch {}`.
- Verification without a full build: `scripts/typecheck.sh <Module> [<Module> …]` type-checks Core plus
  the given folders against the iOS simulator SDK. Foundation-only modules (Core, Parsers, Practice) are
  additionally exercised by macOS command-line harnesses under `scripts/`.
- Unit tests go in `LearnPianoTests/<Module>Tests.swift` (`@testable import LearnPiano`).

## 2. Core concepts every module relies on

**Ticks.** All musical time is integer ticks with `Ticks.perQuarter = 960`. Seconds come only from a
`TempoMap` (`seconds(at:speed:)`, `tick(atSeconds:speed:)`); `speed` is the practice multiplier
(0.25…1.0).

**Events, not notes.** A `MeasureEvent` is a chord (1+ `ChordNote`s) or a rest (no notes) in one
voice of one hand, with `onset` relative to its measure. A MusicXML `<chord/>` group is one event.
Ties are per note: `tieStart` / `tieStop`. Grace notes are dropped by importers.

**Score (notated order) → PlaybackTimeline (playback order).** `Score.makeTimeline()` expands repeats
and volta endings into `PlaybackSegment`s, places every event on an absolute tick axis
(`TimelineEvent`), builds the `TempoMap`, and groups attacks per tick into `TimelineStep`s. Two
fields matter most:

- `TimelineEvent.pitches` — everything sounding (for audio and demo highlights).
- `TimelineEvent.attackPitches` — what is struck at this onset; tie continuations are excluded. **The
  follower expects exactly `TimelineStep.attackPitches(for: hands)`**; rests and pure continuations
  never create a step.

`PlaybackTimeline.measurePosition(atTick:)` maps a playback tick back to the notated measure (and pass),
which is how the cursor is drawn on the notated score during repeats. Loop regions are
`MeasureRange`s over notated indices; `tickRange(of:)` gives the first-pass playback range.

**Hands.** `Hand.right` = staff 1 (treble), `Hand.left` = staff 2 (bass). `HandSelection` says which
hands the learner plays; `otherHands` are the ones the app plays for them when
`PracticeSettings.playOtherHands` is on.

**Input.** Every source produces `NoteInputEvent` (on/off, MIDI number, velocity 0…1, monotonic seconds,
source kind). Timing inside the practice engine comes from an injected `PracticeClock` so tests are
deterministic.

**Feedback.** The engine publishes a `FeedbackSnapshot`: per-key `NoteFeedbackState` for the keyboard,
per-`TimelineEvent.id` state for notation, the current step index, and missing pitches of the current
chord. Views render only that; they never compute musical logic.

**Persistence.** `UserProfile` (favorites, `SongProgress` per arrangement, `LessonProgress`,
`UserSettings`) is one JSON file: `Documents/profile.json`. Imported songs live in
`Documents/Library/<song-id>/` as `score.json` (Codable `Score`), an optional `score.musicxml` export, plus `song.json`
(`SongEntry` with `.user` storage). Bundled songs are the `Content/Songs/*.musicxml` files and their
`*.catalog.json` fragments (`CatalogFragment` → `SongEntry`).

## 3. Practice engine specification (Practice/)

State machine: `stopped → countingIn → playing ⇄ paused → finished` (`TransportState`). `restart`
returns to `stopped` then starts again. Loop end in any mode jumps to the loop start (no `finished`).

### Wait Mode
1. Material = `timeline.steps(for: settings.hands)`; the cursor sits on step *k*; expected set
   `E = step.attackPitches(for: hands)` (with octave tolerance, compare pitch classes).
2. On note-on `p` at time `t`: if `p ∈ E` and not yet satisfied → mark satisfied with time `t`; record
   `correct` feedback for the key and the event. If `p ∉ E` → wrong (feedback `wrong` for ~400 ms on the
   key; count a mistake for the step's measure; never advance). Keys held from a previous step that are
   also in `E` do NOT count: a note must be re-attacked (new note-on after the step became current),
   except tie continuations, which are already excluded from `E`.
3. The step completes when every pitch of `E` has been satisfied and all satisfactions fall within
   `chordWindowSeconds` of the first one; if the window is exceeded, keep the satisfied pitches but reset
   the window start to the latest press (lenient) — do not punish slow chords, just require them all.
4. On completion: emit a `PlayedRecord` (deltaSeconds = time since the step became current), sound the
   other hands' events of this step through `ScorePlaybackControlling.playImmediately` (if
   `playOtherHands`), advance the cursor to step *k+1*. Rests/gaps between steps: the cursor moves
   immediately but the UI may animate; the next step becomes current after
   `gapSeconds × waitModeRestScale` where `gapSeconds` is the tempo-map time between the two onsets at the
   current speed (so long rests still feel like rests). The other hands' events whose onsets lie in that
   gap (e.g. left-hand accompaniment between right-hand notes) are sounded at their scaled times.
5. Cursor tick for the views = current step's tick (interpolated towards the next during gaps).
6. Reaching the end of the material (or the loop end) → `finished` (or jump to loop start).

### Just Play
1. Audio player runs the timeline at `speed` with the learner's hands muted
   (`audibleHands = otherHands` when `playOtherHands`, else nil) and the metronome if enabled; count-in
   first if `countInMeasures > 0`.
2. For each step of the learner's hands, a note-on `p ∈ E` within `±timingWindowSeconds` of the step's
   scheduled time counts as `correct` (or `early`/`late` beyond ±timingWindow/2); unmatched steps become
   `missed` when the window closes; note-ons matching nothing are `wrong`.
3. Re-sync: if 3 consecutive learner attacks match the expected pitches of steps at a consistent offset
   (ahead or behind by more than the window), seek the player to that position.
4. Accuracy = correct / expected steps so far; the `FeedbackSnapshot` marks `upcoming` for the next 2
   steps and `demo` for keys the player is currently sounding.

### Listen
The player plays all hands; the engine only mirrors `onEventStarted` into `demo` key states and moves
the cursor; input is ignored.

### Statistics
Every mode produces a `PracticeSummary` on stop/finish (`stepsExpected`, `stepsCorrect`, `wrongNotes`,
`mistakesByMeasure`, `measuresCompleted`, `reachedEnd`, duration, mode, hands, speed). The Library
module folds it into `UserProfile.record(_:)`.

## 4. Notation specification (Notation/)

- Layout model: a `NotationLayout` computed once per (score, staff-space size, mode) off the main
  thread: systems → measures → columns (one column per distinct onset within the measure) with
  proportional spacing (`width ∝ √duration` with a minimum), fixed-width prefix for clef/key/time at
  the first measure and wherever they change, and extra room for accidentals and ledger lines.
- Drawn: brace, two staves, treble/bass clefs, key signature (accidental placement per clef), time
  signature, noteheads (whole/half/black), stems (up below the middle line, down at/above; for chords
  by the note farthest from the middle; in two-voice measures voice 1 up and voice 2 down), flags,
  beams for runs of 8th/16th/32nd inside one beat group (beat group = `TimeSignature.pulseTicks`),
  rests, accidentals with measure memory (an accidental is drawn when a note's alteration differs from
  the key signature or from an earlier accidental on the same letter+octave in the measure; a natural
  when it returns), dots, ledger lines, ties (curves between consecutive events of the same voice with
  `tieStart`/`tieStop`), tuplet numbers, fingerings, barlines (plain, repeat with dots, final),
  measure numbers at system starts, volta brackets.
- Bravura glyphs are drawn with `Text`/`CTFont` at font size = 4 staff spaces (SMuFL em). Codepoints
  are listed in the Notation brief; metrics in `docs/smufl/Bravura.json`.
- Modes: **scroll** (one long system; the view translates so the cursor tick is at ~35% of the width,
  smoothly) and **page** (systems wrapped to the width for reading).
- Interaction: tap a measure → `onSelectMeasure(index)`; drag across measures → `onSelectRange`.
- Highlights come from `FeedbackSnapshot.eventStates` keyed by `TimelineEvent.id`; the cursor from a
  fractional playback tick. Both change every frame without re-layout.

## 5. Input specification (Input/)

- MIDI: one `MIDIClient`, one input port connected to all sources, reconnect on
  `kMIDIMsgSetupChanged`; parse MIDI 1.0 with running status; note-on velocity 0 = off; emit
  `NoteInputEvent` with `time` from the host clock in seconds. Bluetooth pairing through
  `CABTMIDICentralViewController`.
- Microphone: `AVAudioEngine` input tap, 4096-sample Hann-windowed FFT (vDSP) with 1024 hop at the
  hardware rate; spectral peaks → harmonic-product/harmonic-subtraction scoring to find up to 4
  fundamentals in 27.5–4186 Hz; onset = spectral-flux peak; note-on when a fundamental is present at
  2 consecutive frames after an onset, note-off when it disappears for 4 frames; hysteresis so a
  sustained note is not re-triggered; A4 calibration and sensitivity (threshold) from `UserSettings`.
  Permission state exposed.
- Hub: merges sources, keeps `heldNotes: Set<Int>`, exposes `onEvent` plus an `AsyncStream`, and
  accepts injected events from the on-screen keyboard (`InputSourceKind.virtualKeyboard`).

## 6. Import specification (Import/ with Parsers/)

Pipeline: pick a source → bytes → `ScoreImporter` → `ImportResult` → `ScoreValidator.validate` (+
`repair`) → review screen (title, composer, difficulty, genre, listen with the Audio player, see the
notation, re-run transcription for low-confidence pages) → save to `Documents/Library/<id>/` as
MusicXML + `song.json` → appears in Songs and My Songs.

Sources: Files picker (MusicXML, MXL, MIDI, PDF, PNG/JPEG), paste a URL (download), "Open in
LearnPiano" from Safari/Mail (document types are registered in `project.yml`), paste an image.

PDF/image path: render each page to PNG (long edge 2576 px) → `SheetTranscriptionProvider`
(`ImportClaudeTranscriptionProvider`) sends each page to the Claude API exactly as described in
`docs/claude-api-notes.md`, asking for the LPC JSON in `docs/import-format.md` with structured
output → `ParsersCompactScoreImporter` → measure-numbered errors → up to two repair requests → pages
concatenated (measure numbers continue) → review. Confidence per measure is surfaced in the review
screen.

## 7. Threading and audio session

`AudioSessionConfigurator.configure()` (Audio) sets `.playAndRecord` with
`[.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]` once at app start; the microphone source and
the synth share the engine graph or run separate engines, but neither touches the session category.
Audio render callbacks are real-time safe (no locks, no allocation). All `ScorePlaybackControlling`
callbacks are delivered on the main actor.

## 8. Files you must not edit

Engineers of a module edit only `LearnPiano/<Module>/` and `LearnPianoTests/<Module>Tests.swift`.
`Core/`, `App/`, `project.yml`, `scripts/`, and `Content/Songs/` are owned by the integrator.
