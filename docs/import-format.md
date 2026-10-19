# LPC — LearnPiano Compact score format (version `lpc-1`)

A small JSON score format with two purposes:

1. It is what the vision model emits when transcribing a sheet-music image (it is far shorter and
   more robust than asking a model to write MusicXML).
2. It is an easy hand-authoring format for exercises.

`Parsers/CompactScoreParser.swift` converts LPC → `Score` (Core) and reports measure-numbered
structural errors that the Import module feeds back to the model for repair.

## Shape

```json
{
  "format": "lpc-1",
  "title": "Minuet in G",
  "composer": "Christian Petzold",
  "divisions": 4,
  "time": "3/4",
  "key": 1,
  "tempo": 112,
  "pickup": false,
  "measures": [
    {
      "n": 1,
      "rh": [ { "p": ["D5"], "d": 4, "f": [5] }, { "p": ["G4"], "d": 2 }, { "p": ["A4"], "d": 2 }, { "p": ["B4"], "d": 2 }, { "p": ["C5"], "d": 2 } ],
      "lh": [ { "p": ["G3", "B3"], "d": 8 }, { "p": ["A3"], "d": 4 } ],
      "confidence": 0.95
    }
  ]
}
```

### Top level

| field | type | meaning |
|---|---|---|
| `format` | string | always `"lpc-1"` |
| `title`, `composer` | string | may be empty strings when unknown |
| `divisions` | int | ticks per quarter note used by every `d` (4 normally; 12 when triplets occur; 8 when 32nds occur) |
| `time` | string | `"beats/beatType"`, e.g. `"4/4"`, `"6/8"` |
| `key` | int | key signature in fifths, −7…7 (negative = flats) |
| `tempo` | int | quarter-note beats per minute |
| `pickup` | bool | true when measure 1 is an incomplete pickup bar |
| `measures` | array | in notated order |

### Measure

| field | type | meaning |
|---|---|---|
| `n` | int | 1-based measure number |
| `rh` | array of events | right-hand (upper staff) main voice |
| `lh` | array of events | left-hand (lower staff) main voice |
| `rh2`, `lh2` | array of events | optional second voice on the same staff (empty array when unused) |
| `time`, `key`, `tempo` | as top level | optional change taking effect at this measure (omit or repeat the current value) |
| `confidence` | number 0…1 | transcription confidence for this measure (1 for hand-authored files) |

Every voice that is present must sum exactly to the measure length `beats * 4 * divisions / beatType`,
except measure 1 when `pickup` is true and the final measure (which may be short to complete a pickup).
A voice array may be empty only for `rh2`/`lh2`.

### Event

| field | type | meaning |
|---|---|---|
| `p` | array of strings | pitches sounding together (a chord), scientific pitch with accidentals: `C4` is middle C (MIDI 60); accidentals `#`, `b`, `##`, `bb`; `n` for an explicit natural (`Bn3`). Empty array = rest |
| `d` | int | duration in `divisions` ticks. Dots are folded in (dotted quarter with divisions 4 = 6) |
| `tie` | string | optional: `"start"`, `"stop"`, or `"both"` — applies to every pitch in `p` that also appears in the partner event |
| `t` | array of 2 ints | optional tuplet `[actual, normal]`, e.g. `[3, 2]` for triplets; `d` is the real sounding duration in ticks |
| `f` | array of ints | optional fingerings 1…5, aligned with `p` |
| `s` | string | optional staff override: `"up"` places an LH event on the upper staff, `"down"` an RH event on the lower (cross-staff writing) |

Rests do not take `tie`, `f`, or `s`.

## JSON schema for structured output

Used verbatim as `output_config.format.schema` (every object has `additionalProperties: false` and
all properties listed in `required`; optional fields are expressed as empty arrays / empty strings).

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["format", "title", "composer", "divisions", "time", "key", "tempo", "pickup", "measures"],
  "properties": {
    "format": { "type": "string" },
    "title": { "type": "string" },
    "composer": { "type": "string" },
    "divisions": { "type": "integer" },
    "time": { "type": "string" },
    "key": { "type": "integer" },
    "tempo": { "type": "integer" },
    "pickup": { "type": "boolean" },
    "measures": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["n", "time", "key", "tempo", "rh", "lh", "rh2", "lh2", "confidence"],
        "properties": {
          "n": { "type": "integer" },
          "time": { "type": "string" },
          "key": { "type": "integer" },
          "tempo": { "type": "integer" },
          "confidence": { "type": "number" },
          "rh":  { "$ref": "#/$defs/voice" },
          "lh":  { "$ref": "#/$defs/voice" },
          "rh2": { "$ref": "#/$defs/voice" },
          "lh2": { "$ref": "#/$defs/voice" }
        }
      }
    }
  },
  "$defs": {
    "voice": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["p", "d", "tie", "t", "f", "s"],
        "properties": {
          "p": { "type": "array", "items": { "type": "string" } },
          "d": { "type": "integer" },
          "tie": { "type": "string", "enum": ["", "start", "stop", "both"] },
          "t": { "type": "array", "items": { "type": "integer" } },
          "f": { "type": "array", "items": { "type": "integer" } },
          "s": { "type": "string", "enum": ["", "up", "down"] }
        }
      }
    }
  }
}
```

In the schema form every measure repeats `time`/`key`/`tempo` (the current values) and every event
carries all keys, with `""` / `[]` meaning "absent". The parser accepts both the schema form and the
hand-authoring form where optional keys are omitted.

## Validation rules the parser enforces (errors are measure-numbered)

1. `format == "lpc-1"`, `divisions` in 1…96, `time` parses, `key` in −7…7, `tempo` in 20…300.
2. Measure numbers are 1…N in order with no gaps.
3. Each present voice sums to the measure length (pickup/final exceptions above).
4. Pitches parse and lie in MIDI 21…108; a chord has no duplicate pitches.
5. `tie: start` has a following event in the same voice containing the same pitch with `stop`/`both`.
6. Tuplet `t` has two positive ints; `d` is a positive int; fingerings are 1…5 and `f.count <= p.count`.
7. A hand's chord span does not exceed a 10th (warning, not error).
