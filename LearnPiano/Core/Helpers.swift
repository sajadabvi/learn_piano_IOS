import Foundation

/// Small music-theory helpers used across modules.
public enum MusicHelpers {
    /// "C4", "F#3" for a MIDI number (sharps by default).
    public static func noteName(midi: Int, preferFlats: Bool = false) -> String { Pitch(midi: midi, preferFlats: preferFlats).name }

    /// Letter name without octave, e.g. "F#".
    public static func pitchClassName(midi: Int, preferFlats: Bool = false) -> String {
        let p = Pitch(midi: midi, preferFlats: preferFlats)
        return String(p.name.dropLast(String(p.octave).count))
    }

    /// Frequency in Hz for a MIDI number at the given A4 tuning.
    public static func frequency(midi: Double, a4: Double = 440) -> Double { a4 * pow(2, (midi - 69) / 12) }

    /// Fractional MIDI number for a frequency.
    public static func midi(frequency: Double, a4: Double = 440) -> Double { 69 + 12 * log2(frequency / a4) }

    /// Interval name for a semitone distance (0…24), e.g. "major 3rd".
    public static func intervalName(semitones: Int) -> String {
        let names = ["unison", "minor 2nd", "major 2nd", "minor 3rd", "major 3rd", "perfect 4th", "tritone", "perfect 5th", "minor 6th", "major 6th", "minor 7th", "major 7th", "octave"]
        let s = abs(semitones)
        if s <= 12 { return names[s] }
        if s == 24 { return "two octaves" }
        return "octave + " + names[s - 12]
    }

    /// Whether two MIDI numbers share a pitch class.
    public static func samePitchClass(_ a: Int, _ b: Int) -> Bool { ((a - b) % 12 + 12) % 12 == 0 }

    /// Finger names for 1…5.
    public static func fingerName(_ n: Int) -> String {
        ["", "thumb", "index", "middle", "ring", "little"][max(0, min(5, n))]
    }

    /// Major scale MIDI numbers starting at `root` for one octave (8 notes).
    public static func majorScale(root: Int) -> [Int] { [0, 2, 4, 5, 7, 9, 11, 12].map { root + $0 } }

    /// Natural minor scale for one octave.
    public static func naturalMinorScale(root: Int) -> [Int] { [0, 2, 3, 5, 7, 8, 10, 12].map { root + $0 } }

    /// Root-position triad MIDI numbers.
    public static func triad(root: Int, minor: Bool = false) -> [Int] { [root, root + (minor ? 3 : 4), root + 7] }

    /// Formats a duration in seconds as m:ss.
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Builds small scores in code (used by exercises, tests and previews).
public enum ScoreBuilder {
    /// A one-hand or two-hand score from parallel lists of (pitches, duration) per measure.
    /// `right`/`left` are arrays of measures; each measure is an array of events `(pitches: [String], ticks: Ticks)` with `[]` for a rest.
    public static func make(title: String, time: TimeSignature = .common, key: KeySignature = .cMajor, tempo: Double = 90,
                            right: [[(pitches: [String], ticks: Ticks)]], left: [[(pitches: [String], ticks: Ticks)]] = [],
                            fingering: [[[Int]]] = []) -> Score {
        let count = max(right.count, left.count)
        var measures: [Measure] = []
        for i in 0..<count {
            var events: [MeasureEvent] = []
            func add(_ list: [(pitches: [String], ticks: Ticks)], hand: Hand) {
                var onset: Ticks = 0
                for (j, item) in list.enumerated() {
                    let notes = item.pitches.compactMap { Pitch(name: $0) }.enumerated().map { (k, p) -> ChordNote in
                        let f = (hand == .right && fingering.indices.contains(i) && fingering[i].indices.contains(j) && fingering[i][j].indices.contains(k)) ? fingering[i][j][k] : nil
                        return ChordNote(pitch: p, fingering: f)
                    }
                    events.append(MeasureEvent(onset: onset, duration: item.ticks, notes: notes, hand: hand))
                    onset += item.ticks
                }
            }
            if right.indices.contains(i) { add(right[i], hand: .right) }
            if left.indices.contains(i) { add(left[i], hand: .left) }
            measures.append(Measure(number: i + 1, events: events, barline: i == count - 1 ? Barline(isFinal: true) : .plain))
        }
        return Score(metadata: ScoreMetadata(title: title, source: .exercise), initialTime: time, initialKey: key, initialTempoBPM: tempo, measures: measures)
    }
}
