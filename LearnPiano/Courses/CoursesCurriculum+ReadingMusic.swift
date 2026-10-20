import Foundation

// MARK: - Course 2: Reading Music

extension CoursesCurriculum {
    static let readingMusicCourse = Course(
        id: "reading-music",
        title: "Reading Music",
        subtitle: "Read notes on both staves, count rhythms, and play your first real song.",
        level: .beginner,
        symbol: "music.note.list",
        lessons: [readingStaff, readingTreble, readingBass, readingRhythmBasics, readingEighths, readingOdeToJoy]
    )

    // MARK: Illustrations

    static let readingMiddleCBothClefs = illustration(
        "Middle C in both clefs",
        right: [[play("C4", for: half), rest(half)]],
        left: [[rest(half), play("C4", for: half)]]
    )

    static let readingStepsFromMiddleC = illustration(
        "Steps up from middle C",
        right: [[play("C4", for: quarter), play("D4", for: quarter), play("E4", for: quarter), play("F4", for: quarter)],
                [play("G4", for: half), rest(half)]],
        fingering: [[[1], [2], [3], [4]], [[5]]]
    )

    static let readingTrebleLines = illustration(
        "Treble lines",
        right: [[play("E4", for: quarter), play("G4", for: quarter), play("B4", for: quarter), play("D5", for: quarter)],
                [play("F5", for: half), rest(half)]]
    )

    static let readingTrebleSpaces = illustration(
        "Treble spaces",
        right: [[play("F4", for: quarter), play("A4", for: quarter), play("C5", for: quarter), play("E5", for: quarter)]]
    )

    static let readingBassLines = illustration(
        "Bass lines",
        right: [],
        left: [[play("G2", for: quarter), play("B2", for: quarter), play("D3", for: quarter), play("F3", for: quarter)],
               [play("A3", for: half), rest(half)]]
    )

    static let readingBassSpaces = illustration(
        "Bass spaces",
        right: [],
        left: [[play("A2", for: quarter), play("C3", for: quarter), play("E3", for: quarter), play("G3", for: quarter)]]
    )

    static let readingGrandStaffLadder = illustration(
        "From bass to treble",
        right: [[rest(half), play("C4", for: quarter), play("D4", for: quarter)],
                [play("E4", for: half), rest(half)]],
        left: [[play("A3", for: quarter), play("B3", for: quarter), rest(half)],
               [rest(whole)]]
    )

    static let readingNoteValues = illustration(
        "Whole, half and quarter notes",
        right: [[play("C5", for: whole)],
                [play("C5", for: half), play("C5", for: half)],
                [play("C5", for: quarter), play("C5", for: quarter), play("C5", for: quarter), play("C5", for: quarter)]]
    )

    static let readingRests = illustration(
        "Rests",
        right: [[play("C5", for: quarter), rest(quarter), play("C5", for: quarter), rest(quarter)],
                [play("C5", for: half), rest(half)]]
    )

    static let readingEighthNotes = illustration(
        "Eighth notes",
        right: [[play("C5", for: quarter), play("C5", for: eighth), play("D5", for: eighth), play("C5", for: quarter), play("C5", for: eighth), play("D5", for: eighth)],
                [play("C5", for: eighth), play("D5", for: eighth), play("C5", for: eighth), play("D5", for: eighth),
                 play("C5", for: eighth), play("D5", for: eighth), play("C5", for: quarter)]]
    )

    // MARK: Lessons

    static let readingStaff = Lesson(
        id: "reading-staff-clefs",
        title: "The staff, clefs and middle C",
        summary: "Five lines and four spaces, the treble and bass clefs, and where middle C lives.",
        minutes: 8,
        blocks: [
            .text("""
            Music is written on a **staff**: five horizontal lines with four spaces between them. Every line and every space stands for one white key. The higher a note sits on the staff, the higher it sounds, and moving from a line to the next space is one step on the keyboard.

            Piano music uses two staves joined by a brace, together called the **grand staff**. The upper staff is usually for the right hand and the lower staff for the left.
            """),
            .text("""
            A **clef** at the start of each staff tells you which notes the lines stand for. The **treble clef** curls around the second line from the bottom, marking it as the G above middle C. The **bass clef** puts its two dots around the second line from the top, marking it as the F below middle C.

            Middle C does not fit on either staff, so it gets a short extra line of its own, a **ledger line**: just below the treble staff, or just above the bass staff. It is the same key either way. The two staves meet at middle C.
            """),
            .notationIllustration(score: readingMiddleCBothClefs, caption: "Middle C written twice: on a ledger line below the treble staff, then above the bass staff."),
            .notationIllustration(score: readingStepsFromMiddleC, caption: "From middle C, each step up the staff is the next white key: C D E F G."),
            .glossary([
                ["Staff", "Five lines and four spaces"],
                ["Grand staff", "Treble and bass staves joined by a brace"],
                ["Treble clef", "The G clef, usually for the right hand"],
                ["Bass clef", "The F clef, usually for the left hand"],
                ["Ledger line", "A short extra line for notes above or below the staff"],
                ["Bar line", "A vertical line that divides the music into bars (measures)"],
            ]),
            .tip("Open any song in the Songs tab and find the clefs, the brace and the bar lines. Spotting middle C on its ledger line is a great first reading habit."),
        ]
    )

    static let readingTreble = Lesson(
        id: "reading-treble-notes",
        title: "Notes on the treble staff",
        summary: "Lines E G B D F, spaces F A C E, and reading by landmarks.",
        minutes: 10,
        blocks: [
            .text("""
            The five lines of the treble staff, from bottom to top, are **E G B D F**. A popular way to remember them: **Every Good Boy Deserves Fruit**.
            """),
            .notationIllustration(score: readingTrebleLines, caption: "The treble lines: E G B D F."),
            .text("""
            The four spaces spell a word by themselves, from bottom to top: **F A C E**. Face is in the space.
            """),
            .notationIllustration(score: readingTrebleSpaces, caption: "The treble spaces: F A C E."),
            .text("""
            You do not need to recite the rhyme for every note. Instead, use **landmarks** and count steps from them. Good treble landmarks are **middle C** (on its ledger line below the staff), **G** (the line the clef curls around) and the **F** on the top line.

            A note one step above a landmark is the next letter of the alphabet; a note one step below is the previous letter. With a little practice you will recognise most notes at a glance.
            """),
            .glossary([
                ["Lines", "E G B D F: Every Good Boy Deserves Fruit"],
                ["Spaces", "F A C E"],
                ["Landmarks", "Middle C, treble G, top-line F"],
            ]),
            .tip("Read in short bursts: open a beginner song and name only the first note of every bar. Two minutes every day beats twenty minutes once a week."),
        ]
    )

    static let readingBass = Lesson(
        id: "reading-bass-notes",
        title: "Notes on the bass staff",
        summary: "Lines G B D F A, spaces A C E G, and how the two staves join at middle C.",
        minutes: 10,
        blocks: [
            .text("""
            The bass staff holds the lower notes, mostly played by the left hand. Its lines, from bottom to top, are **G B D F A**: **Good Boys Do Fine Always**.
            """),
            .notationIllustration(score: readingBassLines, caption: "The bass lines: G B D F A."),
            .text("""
            The spaces, from bottom to top, are **A C E G**: **All Cows Eat Grass**.
            """),
            .notationIllustration(score: readingBassSpaces, caption: "The bass spaces: A C E G."),
            .text("""
            Bass landmarks are **F** (the line between the clef's two dots), **middle C** (on its ledger line above the staff) and **low G** (the bottom line). Notice that the bass staff is not a copy of the treble staff: the same line means a different note, so read each clef on its own terms.

            The two staves fit together around middle C like one long ladder: the top line of the bass staff is A, then comes B, then middle C on its ledger line, then D, and the bottom line of the treble staff is E.
            """),
            .notationIllustration(score: readingGrandStaffLadder, caption: "A and B at the top of the bass staff, then middle C, D and E into the treble: one continuous ladder of white keys."),
            .glossary([
                ["Lines", "G B D F A: Good Boys Do Fine Always"],
                ["Spaces", "A C E G: All Cows Eat Grass"],
                ["Landmarks", "Bass F, middle C, low G"],
            ]),
            .tip("A very common mistake is reading the bass staff with treble names, which puts you two notes off. If a left-hand note sounds wrong, check which clef you are reading."),
        ]
    )

    static let readingRhythmBasics = Lesson(
        id: "reading-rhythm-basics",
        title: "Rhythm: quarter, half, whole and rests",
        summary: "The beat, note values, rests, bars and the 4/4 time signature.",
        minutes: 12,
        blocks: [
            .text("""
            Pitch tells you **which** key to play; rhythm tells you **when** and **for how long**. Music moves over a steady pulse called the **beat**, like the ticking of a clock, and the shape of each note tells you how many beats it lasts.
            """),
            .notationIllustration(score: readingNoteValues, caption: "A whole note (4 beats), two half notes (2 beats each) and four quarter notes (1 beat each)."),
            .text("""
            **Rests** are silences, and they count just as much as notes. A quarter rest looks like a little squiggle and lasts one beat; a half rest sits on top of a line and lasts two. During a rest, lift your finger and keep counting.

            Music is divided into **bars** (also called measures) by bar lines. The **time signature** at the start, such as **4/4**, says how many beats each bar holds: four quarter-note beats. Count **1 2 3 4** in every bar and always start a new bar on 1.
            """),
            .notationIllustration(score: readingRests, caption: "Quarter rests between quarter notes, then a half note followed by a half rest."),
            .glossary([
                ["Whole note", "Hollow, no stem: 4 beats"],
                ["Half note", "Hollow with a stem: 2 beats"],
                ["Quarter note", "Filled in with a stem: 1 beat"],
                ["Rest", "A silence of a set length"],
                ["Time signature", "Top number: beats per bar; 4/4 means four quarter-note beats"],
            ]),
            .exercise(Exercise(
                id: "rhythm-quarters-halves",
                title: "Counting quarters and halves",
                instructions: "Count \"1 2 3 4\" aloud in every bar. Quarter notes get one count and half notes two. The right hand plays E, then the left hand plays C, and at the end both hands play the same rhythm together. In Just Play the music keeps moving, so play on the beat.",
                scoreFileName: "ex-rhythm-quarters-halves__beginner.musicxml",
                hands: .both,
                mode: .justPlay,
                pass: ExercisePassCriteria(minimumAccuracy: 0.8, maxWrongNotes: 4)
            )),
            .tip("If keeping time is hard, switch to Wait mode first to learn the notes, then come back to Just Play. Turning on the metronome gives you a steady click to lean on."),
        ]
    )

    static let readingEighths = Lesson(
        id: "reading-eighth-notes",
        title: "Eighth notes",
        summary: "Two notes per beat, flags and beams, and counting \"1 and 2 and\".",
        minutes: 10,
        blocks: [
            .text("""
            An **eighth note** lasts half a beat, so two eighth notes fit into one beat. A single eighth note has a **flag** on its stem; two or more in a row are joined by a **beam**.
            """),
            .notationIllustration(score: readingEighthNotes, caption: "Quarter notes mixed with beamed pairs of eighth notes, then a full bar of eighths."),
            .text("""
            To count eighth notes, split every beat in two and say **\"1 and 2 and 3 and 4 and\"**, often written 1 + 2 + 3 + 4 +. Notes on the numbers fall on the beat; notes on the \"and\" fall exactly halfway between.

            Keep the beat steady and fit the eighths inside it, not the other way round. The most common mistake is rushing them. Tap your foot on the numbers and let your fingers fill in the \"ands\".
            """),
            .glossary([
                ["Eighth note", "Half a beat, drawn with a flag or a beam"],
                ["Beam", "A thick line joining eighth notes together"],
                ["1 + 2 +", "Counting eighths: numbers on the beat, \"and\" in between"],
            ]),
            .exercise(Exercise(
                id: "rhythm-eighths",
                title: "Even eighth notes",
                instructions: "The right hand alternates C and D with fingers 1 and 2. Count \"1 and 2 and\" and keep the eighths perfectly even. From bar 5 the left hand plays steady quarter notes on C: fit exactly two right-hand notes into each one.",
                scoreFileName: "ex-rhythm-eighths__beginner.musicxml",
                hands: .both,
                mode: .justPlay,
                pass: ExercisePassCriteria(minimumAccuracy: 0.8, maxWrongNotes: 4)
            )),
            .tip("Practise at 75% speed with the metronome on until the eighths feel easy, then go back to full speed."),
        ]
    )

    static let readingOdeToJoy = Lesson(
        id: "reading-ode-to-joy",
        title: "Your first song: Ode to Joy",
        summary: "Beethoven's famous melody in C position, right hand first, then hands together.",
        minutes: 15,
        blocks: [
            .text("""
            Time to put everything together. **Ode to Joy** is the famous melody from Beethoven's Ninth Symphony. This arrangement is in C major, so the right hand stays in **C position** for the whole song: thumb on middle C, one finger per key.

            The melody moves almost entirely **by step**, which makes it a perfect first song. Look out for the **dotted quarter followed by an eighth** at the end of the first two phrases (count \"1, 2 and, 3\": long, short), and for the third phrase, where the melody briefly drops to a low G that the left hand plays.
            """),
            .text("""
            Learn it in two steps. First play the **right hand alone** while the app plays the left hand for you. Then play **both hands**: the left hand plays long notes on C and G, with finger 5 on C and the thumb on G.
            """),
            .glossary([
                ["Dotted note", "A dot adds half the note's value: a dotted quarter lasts 1½ beats"],
                ["Phrase", "A musical sentence, often four bars long"],
            ]),
            .exercise(Exercise(
                id: "ode-to-joy-right",
                title: "Ode to Joy: right hand",
                instructions: "Right thumb on middle C. Play the melody while the app plays the left hand. Watch the long-short rhythm at the end of each phrase.",
                scoreFileName: "ode-to-joy__beginner.musicxml",
                hands: .right,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 4)
            )),
            .exercise(Exercise(
                id: "ode-to-joy-both",
                title: "Ode to Joy: both hands",
                instructions: "Now add the left hand: finger 5 on C below middle C, thumb on G. Go slowly; Wait mode holds each chord until both hands are down.",
                scoreFileName: "ode-to-joy__beginner.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 5)
            )),
            .tip("Practise the tricky third phrase (bars 9 to 12) on its own: in the practice screen, tap a bar to select it, or long-press and drag across several bars to loop them."),
        ]
    )
}
