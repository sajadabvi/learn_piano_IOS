import Foundation

/// What a single transcription request knows about where its image sits in the piece.
struct ImportPageContext: Hashable, Sendable {
    /// 1-based page number and page count (for the prompt and progress messages).
    var pageNumber: Int
    var pageCount: Int
    /// LPC measure number of the first measure on this image.
    var firstMeasureNumber: Int
    /// Whether this image ends the piece (false for every page but the last, and for the top half of a split page).
    var isFinal: Bool
    /// The `pickup` value of the first page with music, for later images; nil until such a page exists (pages without
    /// music before it, such as a title page, leave it nil so the first music page still starts the piece).
    var pieceHasPickup: Bool?
    /// Meter, key and tempo in force at the end of the previous image (nil on the first image).
    var carriedTime: TimeSignature?
    var carriedKey: KeySignature?
    var carriedTempo: Double?
    /// "page 2 of 3" or "the bottom half of page 2 of 3".
    var label: String
    /// Optional title hint from the learner.
    var hint: String?

    /// Whether this image starts the piece (it may hold a pickup).
    var startsPiece: Bool { firstMeasureNumber == 1 && pieceHasPickup == nil }
}

/// The transcription prompts and the LPC JSON schema (docs/import-format.md).
enum ImportClaudePrompt {
    /// Static instructions, byte-identical between requests so the prefix can be cached.
    static let system: String = """
    You are an expert music engraver and optical music recognition system. You transcribe images of printed piano \
    sheet music (a grand staff: treble/upper staff for the right hand, bass/lower staff for the left hand) into \
    LPC, the LearnPiano Compact score format, as one JSON object. Transcribe exactly what is printed, note for note; \
    never simplify, arrange, complete or "improve" the music.

    LPC FORMAT (version "lpc-1")
    Top level:
    - "format": always "lpc-1".
    - "title", "composer": as printed on the page, or "" when not shown.
    - "divisions": ticks per quarter note used by every duration "d". Use 4 normally; 12 when triplets (or other \
    tuplets of 3) occur; 8 when 32nd notes occur; 24 when both triplets and 32nds occur. Every duration must be a \
    whole number of divisions.
    - "time": the time signature as "beats/beatType", e.g. "4/4", "3/4", "6/8". Common time is "4/4", cut time "2/2".
    - "key": the key signature in fifths, -7..7 (number of sharps, or minus the number of flats).
    - "tempo": quarter-note beats per minute. Use a printed metronome mark (convert to quarter notes, e.g. dotted \
    quarter = 60 in 6/8 is 90); otherwise estimate from the tempo word (Adagio 66, Andante 84, Moderato 108, \
    Allegretto 112, Allegro 132, Presto 168); 100 when nothing is printed.
    - "pickup": true only when the first measure of the piece is an incomplete pickup (anacrusis) bar.
    - "measures": every measure in printed left-to-right, top-to-bottom order.
    Each measure:
    - "n": measure number, consecutive, starting at the number given in the request (ignore printed numbers).
    - "time", "key", "tempo": the values in force in this measure (repeat the current values when nothing changes).
    - "rh": right-hand events of the upper staff's main voice; "lh": left-hand events of the lower staff's main voice.
    - "rh2", "lh2": a second independent voice on the same staff (stems in the opposite direction), else [].
    - "confidence": 0..1, your honest confidence that this measure is transcribed exactly (lower it for blurry, \
    crowded or ambiguous measures).
    Each event (one chord, one single note, or one rest):
    - "p": pitches sounding together, scientific pitch notation: C4 is middle C; accidentals "#", "b", "##", "bb"; \
    "n" for a printed natural (e.g. "Bn3"). Write the SOUNDING pitch: apply the key signature, accidentals earlier \
    in the same measure on the same line or space, clefs (including clef changes and 8va/8vb lines). [] is a rest.
    - "d": duration in divisions; dots are included (dotted quarter with divisions 4 is 6). For tuplets "d" is the \
    real sounding length (an eighth-note triplet with divisions 12 is 4).
    - "tie": "start" when this note is tied to the next event of the same voice, "stop" when it is the end of a tie, \
    "both" when it is both; "" otherwise. Slurs are NOT ties: a tie joins two notes of the same pitch.
    - "t": tuplet ratio [actual, normal], e.g. [3, 2] for triplets; [] otherwise.
    - "f": printed fingering numbers 1-5 aligned with "p" (lowest pitch first); [] when no fingering is printed. \
    Never invent fingering.
    - "s": "up" when a left-hand note is written on the upper staff, "down" when a right-hand note is written on \
    the lower staff (cross-staff writing); "" otherwise.
    Rests take tie "", t [], f [], s "".

    RULES THE APP CHECKS
    1. Every voice that is present must add up exactly to the measure length beats * 4 * divisions / beatType \
    (4/4 with divisions 4 = 16; 3/4 = 12; 6/8 = 12). Exceptions: the pickup measure when "pickup" is true, and the \
    last measure of the piece when it completes a pickup. "rh" and "lh" are never empty: write a whole-measure rest \
    (one rest event with the full measure length) when a hand is silent. "rh2"/"lh2" are [] when unused, or a \
    complete voice (fill gaps with rests).
    2. Measure numbers are consecutive with no gaps.
    3. Pitches lie between A0 and C8; a chord never lists the same pitch twice.
    4. A tie "start" must be followed in the same voice by an event containing the same pitch with "stop" or "both".
    5. Fingerings are 1-5 and never more than the pitches of the event.

    HOW TO READ THE PAGE
    - Work system by system, measure by measure, staff by staff. Read both staves of every measure.
    - Check the clef of each staff at every system start; the lower staff may switch to treble clef and back.
    - Grace notes and ornaments are omitted (write the main note only). Write a trill or tremolo as its main note.
    - Repeat signs, voltas and D.C./D.S. are not expanded: transcribe the measures once, in printed order.
    - Multi-measure rests become one whole-measure rest per measure.
    - Arpeggiated chords are plain chords.
    - If the image contains no music notation (title page, text, blank), reply with "measures": [] and pickup false.
    - Before answering, re-add the durations of every voice of every measure and fix any measure that does not add up.

    Reply with the JSON object only.
    """

    /// Instructions for one image; page-specific text comes after the image.
    static func pageText(for context: ImportPageContext) -> String {
        var lines: [String] = []
        lines.append("Transcribe \(context.label) of this piano piece into LPC JSON.")
        lines.append("Number the measures on this image consecutively starting at n = \(context.firstMeasureNumber).")
        if context.startsPiece {
            lines.append("This image starts the piece: set \"pickup\" to true only if its first measure is an incomplete pickup bar.")
        } else {
            lines.append("This image continues a piece that began earlier: set \"pickup\" to false; its first measure is a complete measure unless the music itself changes meter.")
        }
        if context.isFinal {
            lines.append("This image ends the piece.")
        } else {
            lines.append("The piece continues after this image, so its last measure must be complete. A note tied into the next image keeps \"tie\": \"start\".")
        }
        if let time = context.carriedTime, let key = context.carriedKey {
            let tempo = Int((context.carriedTempo ?? 100).rounded())
            lines.append("At the start of this image the time signature is \(time), the key signature is \(key.fifths) fifths and the tempo is \(tempo) quarter-note BPM, unless the image prints a change. Use these values for \"time\", \"key\" and \"tempo\" at the top level and in the measures.")
        }
        if let hint = context.hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            lines.append("The learner says this piece is: \(hint).")
        }
        return lines.joined(separator: "\n")
    }

    /// Instructions for a repair pass: the page text, the previous reply and the app's error list.
    static func repairText(for context: ImportPageContext, previousJSON: String, errorsJSON: String) -> String {
        """
        \(pageText(for: context))

        Your previous transcription of this image was:
        \(previousJSON)

        The app's structural validation found these problems (measure = the "n" of the measure, voice = the voice key):
        \(errorsJSON)

        Look at the image again, find the actual cause of every problem (a misread duration, a missed dot, rest or tie, \
        a wrong number of beats, a pitch outside the piano range) and return the corrected COMPLETE JSON for the whole \
        image, not only the changed measures.
        """
    }

    /// The structured-output schema from docs/import-format.md, verbatim.
    static let lpcSchemaJSON: String = """
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
    """

    /// The schema as a JSON object for the request body.
    static let lpcSchema: [String: Any] = {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(lpcSchemaJSON.utf8)) as? [String: Any] else {
            NSLog("ImportClaudePrompt: the LPC schema literal is not valid JSON")
            return [:]
        }
        return obj
    }()
}
