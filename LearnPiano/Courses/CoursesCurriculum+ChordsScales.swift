import Foundation

// MARK: - Course 3: Chords and Scales

extension CoursesCurriculum {
    static let chordsAndScalesCourse = Course(
        id: "chords-scales",
        title: "Chords and Scales",
        subtitle: "Triads, the C and G major scales, your first key signature and the I–IV–V progression.",
        level: .intermediate,
        symbol: "square.stack.3d.up",
        lessons: [chordsTriads, chordsCMajorScale, chordsGMajorScale, chordsProgression, chordsIntervals]
    )

    // MARK: Illustrations

    static let chordsTriadsOverRoots = illustration(
        "C, F and G triads",
        right: [[play("C4", "E4", "G4", for: half), play("F4", "A4", "C5", for: half)],
                [play("G4", "B4", "D5", for: half), play("C4", "E4", "G4", for: half)]],
        left: [[play("C3", for: half), play("F3", for: half)],
               [play("G3", for: half), play("C3", for: half)]]
    )

    static let chordsCScaleFingering = illustration(
        "C major scale fingering",
        right: [[play("C4", for: quarter), play("D4", for: quarter), play("E4", for: quarter), play("F4", for: quarter)],
                [play("G4", for: quarter), play("A4", for: quarter), play("B4", for: quarter), play("C5", for: quarter)]],
        fingering: [[[1], [2], [3], [1]], [[2], [3], [4], [5]]]
    )

    static let chordsGScale = illustration(
        "G major scale",
        key: KeySignature(fifths: 1),
        right: [[play("G4", for: quarter), play("A4", for: quarter), play("B4", for: quarter), play("C5", for: quarter)],
                [play("D5", for: quarter), play("E5", for: quarter), play("F#5", for: quarter), play("G5", for: quarter)]],
        fingering: [[[1], [2], [3], [1]], [[2], [3], [4], [5]]]
    )

    static let chordsSmoothProgression = illustration(
        "I–IV–V–I with inversions",
        right: [[play("C4", "E4", "G4", for: half), play("C4", "F4", "A4", for: half)],
                [play("B3", "D4", "G4", for: half), play("C4", "E4", "G4", for: half)]],
        left: [[play("C3", for: half), play("F3", for: half)],
               [play("G3", for: half), play("C3", for: half)]]
    )

    static let chordsMelodicHarmonic = illustration(
        "Melodic and harmonic intervals",
        right: [[play("C4", for: quarter), play("E4", for: quarter), play("C4", "E4", for: half)],
                [play("C4", for: quarter), play("G4", for: quarter), play("C4", "G4", for: half)]]
    )

    // MARK: Lessons

    static let chordsTriads = Lesson(
        id: "chords-triads-c-f-g",
        title: "Triads: C, F and G",
        summary: "Build a triad from any white key and meet the three most important chords in C major.",
        minutes: 12,
        blocks: [
            .text("""
            A **chord** is three or more notes played together. The most basic chord is the **triad**: a root, the note a third above it and the note a fifth above it. On the white keys that simply means **every other key**: play one, skip one, play one, skip one, play one.

            In the right hand, use fingers **1, 3 and 5**. The beautiful thing about triads is that the shape never changes. Build it on C and you get **C E G**; slide the same shape up to F and you have **F A C**; slide it to G and you have **G B D**.
            """),
            .keyboardIllustration(pitches: [60, 64, 67], caption: "C major triad: C E G."),
            .keyboardIllustration(pitches: [65, 69, 72], caption: "F major triad: F A C."),
            .keyboardIllustration(pitches: [67, 71, 74], caption: "G major triad: G B D."),
            .text("""
            In C major these three are the most important chords of all: C is built on the 1st note of the scale, F on the 4th and G on the 5th. Between them they can accompany thousands of songs.

            In the exercise the left hand plays only the **root** of each chord, the note the chord is named after: C with finger 5, F with finger 2 and G with the thumb, so the left hand never has to move.
            """),
            .notationIllustration(score: chordsTriadsOverRoots, caption: "C, F, G and C triads in the right hand over their roots in the left."),
            .glossary([
                ["Chord", "Three or more notes sounding together"],
                ["Triad", "Root + third + fifth"],
                ["Root", "The note a chord is built on and named after"],
                ["Major triad", "A bright-sounding triad, such as C E G"],
            ]),
            .exercise(Exercise(
                id: "triads-c-f-g",
                title: "C, F and G triads",
                instructions: "Right hand plays C-E-G, F-A-C and G-B-D with fingers 1-3-5; the left hand plays each chord's root. Press all three notes at exactly the same moment, and prepare the next shape while the current chord sounds.",
                scoreFileName: "ex-triads-c-f-g__beginner.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 4)
            )),
            .tip("Listen for one single sound when you play a chord, not a quick roll from bottom to top. If the notes arrive one by one, drop the whole hand onto the keys from a little higher."),
        ]
    )

    static let chordsCMajorScale = Lesson(
        id: "chords-c-major-scale",
        title: "The C major scale and fingering",
        summary: "Eight notes with five fingers: thumb-under, cross-over and the whole/half-step pattern.",
        minutes: 12,
        blocks: [
            .text("""
            A **scale** is a set of notes in order, from a starting note (the root) up to the next note with the same name. The **C major scale** is all the white keys from C to C: **C D E F G A B C**. Scales are the alphabet of music; most melodies are built from them.
            """),
            .keyboardIllustration(pitches: [60, 62, 64, 65, 67, 69, 71, 72], caption: "The C major scale: every white key from C to C."),
            .text("""
            That is eight notes but only five fingers, so the hand must shift without breaking the line. Going up in the right hand, play C D E with **1 2 3**, then pass the **thumb under** to F and carry on with 1 2 3 4 5. The full fingering is **1 2 3 1 2 3 4 5**. Coming down, finger 3 **crosses over** the thumb from F to E.

            The left hand plays **5 4 3 2 1** from C up to G, then finger 3 **crosses over** the thumb to A: **5 4 3 2 1 3 2 1**. Coming down, the thumb tucks under after A.
            """),
            .notationIllustration(score: chordsCScaleFingering, caption: "Right-hand fingering: 1 2 3, thumb under, then 1 2 3 4 5."),
            .text("""
            Every major scale follows the same pattern of **whole steps** (two keys apart) and **half steps** (neighbouring keys, black or white): whole, whole, half, whole, whole, whole, half. In C major the half steps fall between E and F and between B and C, exactly where there is no black key.
            """),
            .glossary([
                ["Scale", "Notes in order from a root up to its octave"],
                ["Thumb under", "The thumb passes beneath the hand to reach the next key"],
                ["Cross over", "A finger reaches over the thumb to the next key"],
                ["Half step", "Two neighbouring keys, black or white"],
                ["Whole step", "Two half steps"],
            ]),
            .exercise(Exercise(
                id: "c-major-scale",
                title: "C major scale, hands separately",
                instructions: "Each hand plays alone, first in quarter notes and then in eighths. Right hand 1-2-3-1-2-3-4-5, left hand 5-4-3-2-1-3-2-1. Start moving the crossing finger early so the scale never bumps.",
                scoreFileName: "ex-c-major-scale__intermediate.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 4)
            )),
            .tip("Practise only the crossing: E-F-E-F in the right hand with fingers 3-1-3-1, slowly, until the thumb slides under without the wrist twisting."),
        ]
    )

    static let chordsGMajorScale = Lesson(
        id: "chords-g-major-scale",
        title: "G major and the sharp",
        summary: "Why G major needs F sharp, what sharps, flats and naturals do, and your first key signature.",
        minutes: 10,
        blocks: [
            .text("""
            Start the major-scale pattern on G and something interesting happens. To keep the half step between the 7th and 8th notes, F must be raised to **F sharp** (F♯), the black key just to its right. The G major scale is **G A B C D E F♯ G**.
            """),
            .keyboardIllustration(pitches: [67, 69, 71, 72, 74, 76, 78, 79], caption: "The G major scale, with F♯ as its only black key."),
            .text("""
            A **sharp** (♯) raises a note by a half step, to the very next key on the right. A **flat** (♭) lowers it by a half step, to the next key on the left. A **natural** (♮) cancels either one.

            Instead of writing a sharp before every F, music in G major places one sharp at the start of every line, on the F line. This is the **key signature**, and it means \"every F is F♯\", in every octave, for the whole piece, unless a natural sign says otherwise.
            """),
            .notationIllustration(score: chordsGScale, caption: "The G major scale. The sharp in the key signature turns every F into F♯."),
            .text("""
            The fingering is the same as C major: right hand **1 2 3 1 2 3 4 5**, left hand **5 4 3 2 1 3 2 1**. In the right hand, finger 4 lands on the F♯, so keep your hand slightly further forward on the keys to reach the black key comfortably.
            """),
            .glossary([
                ["Sharp ♯", "Raises a note by a half step"],
                ["Flat ♭", "Lowers a note by a half step"],
                ["Natural ♮", "Cancels a sharp or flat"],
                ["Key signature", "Sharps or flats at the start of each line that apply to the whole piece"],
            ]),
            .exercise(Exercise(
                id: "g-major-scale",
                title: "G major scale, hands separately",
                instructions: "Same fingering as C major. Remember the key signature: every F is F♯, the black key. Quarter notes first, then eighths; listen for the F♯ pulling up to the top G.",
                scoreFileName: "ex-g-major-scale__intermediate.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 4)
            )),
            .tip("Before you play, find and touch every F♯ on the keyboard. Forgetting the key signature is the most common sight-reading mistake of all."),
        ]
    )

    static let chordsProgression = Lesson(
        id: "chords-progression-i-iv-v",
        title: "Chord progressions: I–IV–V",
        summary: "Roman numerals, tonic, subdominant and dominant, and smooth voice-leading with inversions.",
        minutes: 12,
        blocks: [
            .text("""
            Chords rarely appear alone; they move in **progressions**. Musicians number chords with Roman numerals according to the scale note they are built on. In C major, **I is C**, **IV is F** and **V is G**. The progression **I–IV–V–I** is the backbone of folk, rock, blues and classical music alike.
            """),
            .glossary([
                ["I (tonic)", "C major: home, restful"],
                ["IV (subdominant)", "F major: moving away from home"],
                ["V (dominant)", "G major: tension that wants to return to I"],
                ["Inversion", "A chord with a note other than the root at the bottom"],
            ]),
            .text("""
            Jumping the whole hand from C E G to F A C to G B D works, but it sounds bumpy. Pianists use **inversions** instead: the same notes rearranged so the hand barely moves. Keep C at the bottom and F becomes **C F A**; bring B and D close to C and G becomes **B D G**. At each change only one or two fingers move.
            """),
            .keyboardIllustration(pitches: [60, 65, 69], caption: "IV as C F A: the F chord with C at the bottom (second inversion)."),
            .keyboardIllustration(pitches: [59, 62, 67], caption: "V as B D G: the G chord with B at the bottom (first inversion)."),
            .notationIllustration(score: chordsSmoothProgression, caption: "I–IV–V–I with smooth inversions in the right hand over the roots in the left."),
            .text("""
            In the exercise, bars 1 to 4 use root-position chords; bars 5 to 8 switch to the smooth inversions and then change chord on every beat. Say the numerals aloud as you play: \"one, four, five, one\".
            """),
            .exercise(Exercise(
                id: "chord-progression-i-iv-v",
                title: "I–IV–V–I in C major",
                instructions: "Root-position chords first, then smooth inversions with the thumb staying on or near C. The left hand plays the roots C, F and G. When the chords change every beat, the bass note and the chord must move together.",
                scoreFileName: "ex-chord-progression-i-iv-v__intermediate.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 4)
            )),
            .tip("Listen to the V chord: it sounds unfinished, like a question, and the return to I answers it. Training your ear to hear that pull is as valuable as training your fingers."),
        ]
    )

    static let chordsIntervals = Lesson(
        id: "chords-intervals",
        title: "Intervals",
        summary: "Measure the distance between two notes on the keyboard, on the staff and by ear.",
        minutes: 8,
        blocks: [
            .text("""
            An **interval** is the distance between two notes. Count it by letter names, **including both ends**: C to D is a **2nd** (C-D), C to E is a **3rd** (C-D-E), C to F is a **4th** and C to G is a **5th**.
            """),
            .keyboardIllustration(pitches: [60, 64], caption: "A 3rd: C to E, skipping D."),
            .keyboardIllustration(pitches: [60, 67], caption: "A 5th: C to G, the outer fingers of C position."),
            .text("""
            On the staff, intervals are easy to see. A **2nd** goes from a line to the neighbouring space, a **3rd** from a line to the next line (or a space to the next space), and a **5th** skips over two lines or spaces. Read the shape and you know the distance without naming every note.

            Intervals played one after the other are **melodic**; played together they are **harmonic**. Each one has its own sound: 2nds clash, 3rds are sweet, and 4ths and 5ths sound open and hollow. In C position with the thumb on C, the finger number equals the interval number.
            """),
            .notationIllustration(score: chordsMelodicHarmonic, caption: "A 3rd and a 5th from middle C, first melodic (one note after the other), then harmonic (together)."),
            .glossary([
                ["2nd", "Neighbouring letters: C to D"],
                ["3rd", "Skip one letter: C to E"],
                ["4th", "C to F"],
                ["5th", "C to G"],
                ["Octave", "The 8th: C to the next C"],
            ]),
            .exercise(Exercise(
                id: "intervals",
                title: "2nds, 3rds, 4ths and 5ths",
                instructions: "Right hand first: thumb on middle C, measure each interval upward, one note at a time and then together. Then the left hand does the same downward from middle C. The finger number always equals the interval.",
                scoreFileName: "ex-intervals__beginner.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 3)
            )),
            .tip("Train your ear: run the exercise in Listen mode with your eyes closed and try to name each interval before you look."),
        ]
    )
}
