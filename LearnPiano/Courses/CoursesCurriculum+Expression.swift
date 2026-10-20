import Foundation

// MARK: - Course 4: Playing with Expression and Improvising

extension CoursesCurriculum {
    static let expressionCourse = Course(
        id: "expression-improvising",
        title: "Playing with Expression and Improvising",
        subtitle: "Dynamics and phrasing, a 12-bar blues to improvise over, and how to practise a hard piece.",
        level: .advanced,
        symbol: "waveform.path",
        lessons: [expressionDynamics, expressionBlues, expressionHardPiece]
    )

    static let expressionDynamics = Lesson(
        id: "expression-dynamics-phrasing",
        title: "Dynamics and phrasing",
        summary: "Loud and soft, connected and detached, and shaping music into sentences.",
        minutes: 12,
        blocks: [
            .text("""
            Playing the right notes is only half of music. The other half is **how** you play them: loud or soft, connected or detached, pressing forward or relaxing. These choices are called **expression**, and they are what make a performance move people.

            **Dynamics** are volume markings, written below the staff as Italian abbreviations. On the piano, volume comes from the **speed** of the key, not from force: a slow key stroke is soft and a fast one is loud. Let the weight of a relaxed arm do the work rather than pushing with the fingers.
            """),
            .glossary([
                ["pp (pianissimo)", "Very soft"],
                ["p (piano)", "Soft"],
                ["mp (mezzo-piano)", "Moderately soft"],
                ["mf (mezzo-forte)", "Moderately loud"],
                ["f (forte)", "Loud"],
                ["ff (fortissimo)", "Very loud"],
                ["Crescendo", "Gradually getting louder"],
                ["Diminuendo", "Gradually getting softer"],
                ["Legato", "Smoothly connected notes"],
                ["Staccato", "Short, detached notes"],
            ]),
            .text("""
            **Phrasing** means shaping the music into sentences. A phrase usually grows towards its high point and relaxes at its end, just like a spoken sentence. Play **legato** by not lifting one finger until the next key is down, and at the end of a phrase let the hand breathe with a soft, unhurried lift.

            Now listen to Erik Satie's **Gymnopédie No. 1**. The whole piece stays soft, and its magic lies in tiny shadings: a gentle lean on the first beat of each bar, the slow sway of the left hand, and long melody notes that seem to float. Follow the score and notice where you would take a breath.
            """),
            .exercise(Exercise(
                id: "gymnopedie-listen",
                title: "Listen: Gymnopédie No. 1",
                instructions: "Just listen and follow the cursor. Notice the left hand's pattern of a low bass note followed by a soft chord, and where each melody phrase begins and ends. The exercise is complete when you have listened to the end.",
                scoreFileName: "gymnopedie-1__intermediate.musicxml",
                hands: .both,
                mode: .listen,
                pass: ExercisePassCriteria(minimumAccuracy: 0, maxWrongNotes: 0)
            )),
            .tip("Afterwards, try the left hand of the Gymnopédie on its own from the Songs tab. Play each chord as softly as you can while still making every note sound."),
        ]
    )

    static let expressionBlues = Lesson(
        id: "expression-12-bar-blues",
        title: "12-bar blues improvisation",
        summary: "A walking left-hand blues and the C blues scale for making up your own right-hand melodies.",
        minutes: 15,
        blocks: [
            .text("""
            **Improvising** means making up music as you play. It is less mysterious than it sounds: all you need is a steady foundation in one hand and a small set of safe notes for the other. The **12-bar blues** gives you both.

            The 12-bar blues is a chord pattern that repeats again and again. In C it goes: **four bars of C, two of F, two of C, then one bar of G, one of F and two of C**. The left hand plays a walking line on each chord, root, 3rd, 5th and 6th (for C that is **C E G A**), with fingers 5 3 2 1.
            """),
            .glossary([
                ["Bars 1–4", "C (I)"],
                ["Bars 5–6", "F (IV)"],
                ["Bars 7–8", "C (I)"],
                ["Bar 9", "G (V)"],
                ["Bar 10", "F (IV)"],
                ["Bars 11–12", "C (I)"],
            ]),
            .keyboardIllustration(pitches: [60, 63, 65, 66, 67, 70, 72], caption: "The C blues scale: C E♭ F F♯ G B♭ C."),
            .text("""
            For the right hand, use the **C blues scale**: **C E♭ F F♯ G B♭ C**. Every note of it sounds good over every chord of the blues, so there are no wrong notes, only choices. Start with just **C, E♭ and G**, and leave plenty of space: play a short idea, rest, then answer yourself.

            Work in steps. First **listen** to the left-hand part all the way through and count the bars, so you feel where the chords change. Then **play the left hand** in Wait mode until it runs by itself. Finally, switch to Just Play with the left hand only, keep the walking bass going and let your right hand improvise on the empty treble staff. Extra right-hand notes will be shown as wrong; that is fine here, because they are yours.
            """),
            .exercise(Exercise(
                id: "blues-listen",
                title: "Listen: the 12-bar walking bass",
                instructions: "Listen to the whole 12-bar form and count the bars out loud. Notice the change to F in bar 5, the return to C in bar 7, and the G, F, C turnaround in bars 9 to 12.",
                scoreFileName: "ex-blues-improv-base__intermediate.musicxml",
                hands: .both,
                mode: .listen,
                pass: ExercisePassCriteria(minimumAccuracy: 0, maxWrongNotes: 0)
            )),
            .exercise(Exercise(
                id: "blues-left-hand",
                title: "Play the walking bass",
                instructions: "Left hand only: root, 3rd, 5th, 6th on each chord with fingers 5-3-2-1 (C-E-G-A, F-A-C-D, G-B-D-E). The right-hand staff is empty on purpose; it is your space to improvise once the left hand feels easy.",
                scoreFileName: "ex-blues-improv-base__intermediate.musicxml",
                hands: .left,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 4)
            )),
            .tip("A simple recipe for a solo: play a two- or three-note idea, rest for a bar, then play it again with one note changed. Repetition with variation is the secret of every good improviser."),
        ]
    )

    static let expressionHardPiece = Lesson(
        id: "expression-hard-piece",
        title: "Practising a hard piece",
        summary: "Divide, slow down, hands separately, connect: the four tools, applied to Für Elise.",
        minutes: 15,
        blocks: [
            .text("""
            Sooner or later every pianist meets a piece that feels too hard. The answer is not to play it more often but to practise it **smarter**. Professionals rely on the same few tools, and the practice screen has every one of them.

            **1. Divide it.** Never practise a hard piece only from the beginning. Find the difficult spots, often just one or two bars, and work on them alone. In the practice screen, **tap a bar** to select it, or **long-press and drag** across several bars to set a **loop**.
            """),
            .text("""
            **2. Slow it down.** Play at a speed where you make no mistakes, even if that is 50% or 25%. Mistakes repeated at speed become habits; correct notes repeated slowly become reflexes. Raise the speed only when the passage feels easy.

            **3. Hands separately.** Learn each hand's notes and fingering alone, then put them together slowly. Wait mode is ideal for this: the music waits for you, so you have time to think.

            **4. Connect.** Once the hard bars are fixed, loop a slightly larger section that includes the bar before and the bar after, so the trouble spot joins the music around it. Then play the whole piece through.
            """),
            .text("""
            Try it with Beethoven's **Für Elise**. Its classic trouble spots are the rocking E–D♯ figure, the drop of a seventh in bars 9 to 12, and bars 13 and 14 with the octave leap to the high E. A good plan: loop bars 13 and 14 at 50% speed with the right hand alone, then hands together, then widen the loop, and finally play the whole section.
            """),
            .glossary([
                ["Loop", "Repeat a selected passage automatically"],
                ["Speed", "Practise at 25–75% of the written tempo, then build up"],
                ["Trouble spot", "A bar where mistakes cluster; the app remembers these for you"],
            ]),
            .exercise(Exercise(
                id: "fur-elise-practice",
                title: "Für Elise: practise, then play through",
                instructions: "Use the loop: select bars 13 and 14 (or whichever bars trip you up), lower the speed and repeat them until they are clean. To pass, clear the loop and play the whole section from start to finish with no more than 5 wrong notes.",
                scoreFileName: "fur-elise__intermediate.musicxml",
                hands: .both,
                mode: .wait,
                pass: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 5)
            )),
            .tip("Stop a practice session while it is still going well. Ending on a success makes the next session much easier to start."),
        ]
    )
}
