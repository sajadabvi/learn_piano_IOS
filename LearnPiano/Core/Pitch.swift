import Foundation

// MARK: - Pitch

/// The seven letter names of the diatonic scale.
public enum Step: Int, Codable, CaseIterable, Hashable, Sendable {
    case C = 0, D, E, F, G, A, B

    /// Semitones above C for the natural step.
    public var semitones: Int { [0, 2, 4, 5, 7, 9, 11][rawValue] }

    public var name: String { ["C", "D", "E", "F", "G", "A", "B"][rawValue] }

    public init?(name: String) {
        guard let s = Step.allCases.first(where: { $0.name == name.uppercased() }) else { return nil }
        self = s
    }

    /// Diatonic steps from C in the same octave (0...6) – used for staff positions.
    public var diatonicIndex: Int { rawValue }
}

/// A displayed accidental.
public enum Accidental: Int, Codable, Hashable, Sendable {
    case doubleFlat = -2, flat = -1, natural = 0, sharp = 1, doubleSharp = 2

    public var symbol: String {
        switch self {
        case .doubleFlat: return "bb"
        case .flat: return "b"
        case .natural: return "n"
        case .sharp: return "#"
        case .doubleSharp: return "##"
        }
    }

    public init?(symbol: String) {
        switch symbol {
        case "bb": self = .doubleFlat
        case "b": self = .flat
        case "n", "": self = .natural
        case "#": self = .sharp
        case "##", "x": self = .doubleSharp
        default: return nil
        }
    }
}

/// A spelled pitch: letter + alteration + octave (scientific pitch notation, C4 = middle C = MIDI 60).
public struct Pitch: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var step: Step
    /// Chromatic alteration in semitones (−2…2).
    public var alter: Int
    /// Scientific octave number; octave 4 contains middle C.
    public var octave: Int

    public init(step: Step, alter: Int = 0, octave: Int) {
        self.step = step
        self.alter = alter
        self.octave = octave
    }

    /// MIDI note number (A0 = 21, C4 = 60, C8 = 108).
    public var midi: Int { 12 * (octave + 1) + step.semitones + alter }

    /// Builds a spelled pitch from a MIDI number. Black keys are spelled as sharps unless `preferFlats`.
    public init(midi: Int, preferFlats: Bool = false) {
        let octave = midi / 12 - 1
        let pc = ((midi % 12) + 12) % 12
        let sharpSpelling: [(Step, Int)] = [(.C, 0), (.C, 1), (.D, 0), (.D, 1), (.E, 0), (.F, 0), (.F, 1), (.G, 0), (.G, 1), (.A, 0), (.A, 1), (.B, 0)]
        let flatSpelling: [(Step, Int)] = [(.C, 0), (.D, -1), (.D, 0), (.E, -1), (.E, 0), (.F, 0), (.G, -1), (.G, 0), (.A, -1), (.A, 0), (.B, -1), (.B, 0)]
        let (s, a) = preferFlats ? flatSpelling[pc] : sharpSpelling[pc]
        self.init(step: s, alter: a, octave: octave)
    }

    /// Spells a MIDI number according to a key signature (flats keys spell flats).
    public init(midi: Int, in key: KeySignature) {
        self.init(midi: midi, preferFlats: key.fifths < 0)
    }

    /// Parses "C4", "F#3", "Bb2", "Bn3", "C##5". Returns nil on malformed input.
    public init?(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, let step = Step(name: String(first)) else { return nil }
        var rest = String(trimmed.dropFirst())
        var alter = 0
        if rest.hasPrefix("##") || rest.hasPrefix("x") { alter = 2; rest.removeFirst(rest.hasPrefix("##") ? 2 : 1) }
        else if rest.hasPrefix("bb") { alter = -2; rest.removeFirst(2) }
        else if rest.hasPrefix("#") { alter = 1; rest.removeFirst() }
        else if rest.hasPrefix("b") { alter = -1; rest.removeFirst() }
        else if rest.hasPrefix("n") { alter = 0; rest.removeFirst() }
        guard let octave = Int(rest) else { return nil }
        self.init(step: step, alter: alter, octave: octave)
    }

    /// "C4", "F#3", "Bb2".
    public var name: String {
        let acc: String
        switch alter {
        case -2: acc = "bb"
        case -1: acc = "b"
        case 1: acc = "#"
        case 2: acc = "##"
        default: acc = ""
        }
        return "\(step.name)\(acc)\(octave)"
    }

    public var description: String { name }

    /// Absolute diatonic step index (C0 = 0, D0 = 1 … C4 = 28). Used for staff-line positions.
    public var diatonicNumber: Int { octave * 7 + step.diatonicIndex }

    public static func < (lhs: Pitch, rhs: Pitch) -> Bool {
        lhs.midi != rhs.midi ? lhs.midi < rhs.midi : lhs.diatonicNumber < rhs.diatonicNumber
    }

    /// Whether this MIDI number is a black key.
    public static func isBlackKey(midi: Int) -> Bool { [1, 3, 6, 8, 10].contains(((midi % 12) + 12) % 12) }

    /// Lowest and highest keys of an 88-key piano.
    public static let pianoRange: ClosedRange<Int> = 21...108
}

// MARK: - Key & time signatures

/// Key signature expressed in fifths (−7 = 7 flats … 7 = 7 sharps) with a mode.
public struct KeySignature: Hashable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case major, minor }
    public var fifths: Int
    public var mode: Mode

    public init(fifths: Int, mode: Mode = .major) {
        self.fifths = max(-7, min(7, fifths))
        self.mode = mode
    }

    public static let cMajor = KeySignature(fifths: 0)

    /// Order in which sharps appear: F C G D A E B. Flats: B E A D G C F.
    public static let sharpOrder: [Step] = [.F, .C, .G, .D, .A, .E, .B]
    public static let flatOrder: [Step] = [.B, .E, .A, .D, .G, .C, .F]

    /// Steps altered by this key signature and their alteration (+1 sharp / −1 flat).
    public var alteredSteps: [(step: Step, alter: Int)] {
        if fifths > 0 { return KeySignature.sharpOrder.prefix(fifths).map { ($0, 1) } }
        if fifths < 0 { return KeySignature.flatOrder.prefix(-fifths).map { ($0, -1) } }
        return []
    }

    /// The alteration the key signature applies to a step (0 when unaltered).
    public func alteration(of step: Step) -> Int {
        alteredSteps.first(where: { $0.step == step })?.alter ?? 0
    }

    /// Tonic pitch class name, e.g. "G" for 1 sharp major, "E" for 1 sharp minor.
    public var tonicName: String {
        let majors = ["Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#"]
        let minors = ["Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#", "G#", "D#", "A#"]
        return (mode == .major ? majors : minors)[fifths + 7]
    }

    /// "G major", "E minor".
    public var displayName: String { "\(tonicName) \(mode.rawValue)" }
}

/// Meter: `beats` over `beatType` (4/4, 3/4, 6/8 …).
public struct TimeSignature: Hashable, Codable, Sendable, CustomStringConvertible {
    public var beats: Int
    public var beatType: Int

    public init(beats: Int, beatType: Int) {
        self.beats = max(1, beats)
        self.beatType = max(1, beatType)
    }

    public static let common = TimeSignature(beats: 4, beatType: 4)

    /// Parses "3/4". Returns nil on malformed input.
    public init?(string: String) {
        let parts = string.split(separator: "/")
        guard parts.count == 2, let b = Int(parts[0]), let t = Int(parts[1]), b > 0, t > 0 else { return nil }
        self.init(beats: b, beatType: t)
    }

    public var description: String { "\(beats)/\(beatType)" }

    /// Length of one full measure in ticks.
    public var measureTicks: Ticks { beats * Ticks.perQuarter * 4 / beatType }

    /// Length of one notated beat in ticks (a quarter in x/4, an eighth in x/8).
    public var beatTicks: Ticks { Ticks.perQuarter * 4 / beatType }

    /// Whether the meter is compound (6/8, 9/8, 12/8): beats group in threes.
    public var isCompound: Bool { beatType == 8 && beats % 3 == 0 && beats >= 6 }

    /// Ticks per felt pulse (dotted quarter in compound meters), used by the metronome.
    public var pulseTicks: Ticks { isCompound ? beatTicks * 3 : beatTicks }

    /// Number of felt pulses per measure.
    public var pulsesPerMeasure: Int { isCompound ? beats / 3 : beats }
}
