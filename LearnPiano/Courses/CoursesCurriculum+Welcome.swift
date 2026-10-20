import Foundation

// MARK: - Course 1: Welcome to the Piano

extension CoursesCurriculum {
    static let welcomeCourse = Course(
        id: "welcome",
        title: "Welcome to the Piano",
        subtitle: "Find your way around the keys, meet middle C and play your first notes with both hands.",
        level: .beginner,
        symbol: "pianokeys",
        lessons: [welcomeKeyboardLayout, welcomeFingerNumbers, welcomeMiddleC, welcomeRightHandC, welcomeLeftHandC, welcomeBothHands]
    )

    static let welcomeKeyboardLayout = Lesson(
        id: "welcome-keyboard-layout",
        title: "The keyboard layout",
        summary: "Black-key groups of two and three, the musical alphabet, and how to find every C.",
        minutes: 5,
        blocks: [
            .text("""
            A piano keyboard looks like a long row of identical keys, but it is really one small pattern repeated over and over. Once you can see the pattern, you can find any note in seconds.

            Look at the **black keys**. They are not evenly spaced: they come in **groups of two** and **groups of three**, alternating all the way along the keyboard. These groups are your landmarks.
            """),
            .keyboardIllustration(pitches: [61, 63, 66, 68, 70], caption: "A group of two black keys, then a group of three. The pattern repeats along the whole keyboard."),
            .text("""
            The white keys are named with the first seven letters of the alphabet: **A B C D E F G**. After G the pattern starts again with A. There is no H.

            **C** is always the white key just to the **left of a group of two black keys**. Find every group of two on your keyboard and you have found every C.
            """),
            .keyboardIllustration(pitches: [48, 60, 72], caption: "Every C sits just to the left of a group of two black keys."),
            .text("""
            From C, the white keys go up the alphabet to the right: C D E F G A B, then the next C. Moving **right** always sounds **higher**; moving **left** sounds **lower**.

            The distance from one C to the next C is called an **octave**. Every octave has the same twelve keys: seven white and five black.
            """),
            .keyboardIllustration(pitches: [60, 62, 64, 65, 67, 69, 71, 72], caption: "C D E F G A B C: one octave of white keys."),
            .tip("Play every C on your piano from the bottom to the top, saying \"C\" each time. Then do the same with every F: the white key just left of a group of three black keys."),
            .glossary([
                ["White keys", "Named A to G, repeating up the keyboard"],
                ["Black keys", "Grouped in twos and threes; your landmarks"],
                ["C", "The white key just left of a group of two black keys"],
                ["F", "The white key just left of a group of three black keys"],
                ["Octave", "The distance from one note to the next note with the same name"],
            ]),
        ]
    )

    static let welcomeFingerNumbers = Lesson(
        id: "welcome-finger-numbers",
        title: "Finger numbers",
        summary: "Numbers 1 to 5 for each hand, a relaxed hand shape, and why fingering matters.",
        minutes: 5,
        blocks: [
            .text("""
            Piano music often shows small numbers next to the notes. These are **finger numbers**, and they tell you which finger to use. The numbering is the same for both hands, so you only learn it once.

            Your **thumb is 1** on both hands. Then count outwards: **index finger 2, middle finger 3, ring finger 4, little finger 5**. On the right hand the numbers rise from left to right; on the left hand they rise from right to left, because your hands are mirror images.
            """),
            .glossary([
                ["1", "Thumb"],
                ["2", "Index finger"],
                ["3", "Middle finger"],
                ["4", "Ring finger"],
                ["5", "Little finger (pinky)"],
            ]),
            .keyboardIllustration(pitches: [60, 62, 64, 65, 67], caption: "Right hand: fingers 1 2 3 4 5 on C D E F G."),
            .text("""
            Good fingering is not a rule for its own sake. It puts the right finger in the right place **before** you need it, so your hand moves less and your playing sounds smoother. For now, trust the numbers in the exercises; later you will choose your own.

            **Hand shape.** Let your arms hang loosely at your sides, then lift your hands to the keys without changing their shape. The fingers curve naturally, as if resting on a ball. Play on the pads of the fingertips and on the side tip of the thumb, with the wrists level with the keys.
            """),
            .tip("Tap finger numbers on a tabletop: call out a number and tap with that finger, first with the right hand, then the left. Try 1-3-5, 2-4 and 5-4-3-2-1 until you never have to think."),
        ]
    )

    static let welcomeMiddleC = Lesson(
        id: "welcome-middle-c",
        title: "Finding middle C",
        summary: "The most important landmark on the piano, how to sit, and your first exercise.",
        minutes: 8,
        blocks: [
            .text("""
            **Middle C** is the C closest to the middle of the piano, usually right in front of the brand name. It is where the two hands meet and the note that connects the two staves of piano music, so it is the most important landmark you will learn.

            On an 88-key piano, middle C is the **fourth C from the left**. On a smaller keyboard, find the group of two black keys nearest the centre and take the white key just to its left. Musicians also call it **C4**, and the on-screen keyboard marks it with a small dot.
            """),
            .keyboardIllustration(pitches: [60], caption: "Middle C (C4), just left of the central group of two black keys."),
            .text("""
            Sit facing middle C with your body centred on it. Sit far enough back that your elbows are slightly in front of your body when your fingers rest on the keys, and at a height where your forearms are roughly level with the keyboard. Keep both feet flat on the floor.

            In the exercise you play middle C with the **right thumb**, then with the **left thumb**, then the hands take turns. Each note lasts a number of counts: a **whole note** lasts 4, so count **1 2 3 4** aloud and keep the key down the whole time.
            """),
            .exercise(Exercise(
                id: "middle-c",
                title: "Middle C with each thumb",
                instructions: "Play middle C with your right thumb, then your left thumb, holding each note for its full value. When the hands take turns, lift exactly when the rest begins. Wait mode waits for you, so take your time.",
                scoreFileName: "ex-middle-c__beginner.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 3)
            )),
            .tip("Play from the side tip of the thumb, keeping the thumb gently curved. A flat thumb drags the whole hand down with it."),
        ]
    )

    static let welcomeRightHandC = Lesson(
        id: "welcome-rh-c-position",
        title: "Right-hand C position",
        summary: "One finger per key from middle C to G: steps, skips and reading direction.",
        minutes: 10,
        blocks: [
            .text("""
            A **hand position** is a place where your hand rests so that every finger has its own key. The first and most useful one is **C position**: right thumb on middle C, and fingers 2, 3, 4 and 5 on D, E, F and G.

            In C position you never have to search for a note, because the note **is** the finger: C is 1, D is 2, E is 3, F is 4 and G is 5. That leaves your eyes free to stay on the music.
            """),
            .keyboardIllustration(pitches: [60, 62, 64, 65, 67], caption: "Right-hand C position: C D E F G with fingers 1 2 3 4 5."),
            .text("""
            When a note moves to the neighbouring key it moves **by step**; when it jumps over a key it moves **by skip**. This exercise walks up and down by step, then adds small skips such as C to E and D to F. For a skip the hand stays still and simply a different finger plays.

            Watch the direction of the notes as well as the finger numbers. When the notes go **up** the staff, your fingers move **right** on the keyboard; when they go down, they move left.
            """),
            .exercise(Exercise(
                id: "c-position-rh",
                title: "Right hand in C position",
                instructions: "Right thumb on middle C, one finger per key up to G. Play the steps and skips without looking down, and hold the half and whole notes for their full value. The left hand rests.",
                scoreFileName: "ex-c-position-rh__beginner.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 3)
            )),
            .tip("Keep all five fingers resting lightly on their keys, even the ones that are not playing. Fingers that hover high above the keys are slow to land."),
        ]
    )

    static let welcomeLeftHandC = Lesson(
        id: "welcome-lh-c-position",
        title: "Left-hand C position",
        summary: "The mirror image: left thumb on middle C, fingers 2 to 5 on B, A, G and F.",
        minutes: 10,
        blocks: [
            .text("""
            The left hand mirrors the right. Put your **left thumb on middle C** and let fingers 2, 3, 4 and 5 fall on **B, A, G and F** below it. Now the finger numbers go up as the notes go **down**: C is 1, B is 2, A is 3, G is 4 and F is 5.
            """),
            .keyboardIllustration(pitches: [53, 55, 57, 59, 60], caption: "Left-hand position: F G A B C with fingers 5 4 3 2 1."),
            .text("""
            Left-hand notes are usually written on the lower staff, in the **bass clef**. You will learn to read it properly in the next course. For now, remember that middle C sits on a small line just **above** the bass staff, and each step down the staff is the next white key to the left.

            The left hand is often less practised than the right, so be patient with it. Your little finger (5) in particular should play from the knuckle, with a steady, relaxed wrist.
            """),
            .exercise(Exercise(
                id: "c-position-lh",
                title: "Left hand around middle C",
                instructions: "Left thumb on middle C, little finger on F. Play the steps and small skips with one finger per key; the right hand rests so you can watch the left hand alone.",
                scoreFileName: "ex-c-position-lh__beginner.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 3)
            )),
            .tip("Say the finger numbers aloud as you play. Saying \"1, 2, 3\" while the notes go C, B, A helps your brain accept that the left hand counts the other way."),
        ]
    )

    static let welcomeBothHands = Lesson(
        id: "welcome-both-hands",
        title: "Both hands together",
        summary: "Mirror-image motion around middle C, and the golden rule: hands separately first.",
        minutes: 12,
        blocks: [
            .text("""
            Now both hands share the middle of the keyboard. The right hand covers **C to G** above middle C and the left hand covers **F to C** below it. Both thumbs belong to middle C, so they take turns on that key and never play it together.

            Playing with two hands is a new skill, so this exercise makes it as easy as possible: the hands move in **mirror image**. When the right hand plays fingers 5-4-3-2, the left hand plays 5-4-3-2 too, so you only think of one finger number at a time.
            """),
            .keyboardIllustration(pitches: [53, 55, 57, 59, 60, 62, 64, 65, 67], caption: "Both hands around middle C: the left hand from F up to C, the right hand from C up to G."),
            .text("""
            Use the method every pianist uses for anything new: **hands separately first, then together slowly.** In the practice screen you can choose the right hand, the left hand or both, and lower the speed. In Wait mode the score only moves on when **both** notes of a pair are down, so you can never fall behind.
            """),
            .exercise(Exercise(
                id: "c-position-both",
                title: "Hands together in mirror motion",
                instructions: "Right thumb and left thumb share middle C. Play each line hands separately once, then together slowly. Say the finger numbers aloud: in most bars both hands use the same number at the same time.",
                scoreFileName: "ex-c-position-both__beginner.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 4)
            )),
            .tip("One moment in this exercise puts the right thumb on C against the left index finger on B, a deliberate, crunchy clash. Keep going; it resolves on the very next beat."),
            .glossary([
                ["Hands separately", "Practising each hand alone before combining them"],
                ["Contrary motion", "The hands move in opposite directions"],
                ["Parallel motion", "The hands move in the same direction"],
            ]),
        ]
    )
}
