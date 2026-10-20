import XCTest
@testable import LearnPiano

/// Unit tests for the Parsers module: MusicXML/MXL import, ZIP reading, Standard MIDI File import and quantization,
/// LPC validation, MusicXML export round trips and the shared duration splitter. All fixtures are built in memory.
final class ParsersTests: XCTestCase {

    // MARK: - MusicXML fixtures

    /// Wraps measures of a single two-staff piano part in a score-partwise document.
    private func pianoPart(_ measures: String, divisions: Int = 1, time: String = "<time><beats>4</beats><beat-type>4</beat-type></time>", key: Int = 0) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <work><work-title>Fixture</work-title></work>
          <identification><creator type="composer">Tester</creator></identification>
          <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
          <part id="P1">
          \(measures.replacingOccurrences(of: "{ATTR}", with: "<attributes><divisions>\(divisions)</divisions><key><fifths>\(key)</fifths></key>\(time)<staves>2</staves><clef number=\"1\"><sign>G</sign><line>2</line></clef><clef number=\"2\"><sign>F</sign><line>4</line></clef></attributes>"))
          </part>
        </score-partwise>
        """
    }

    private func note(_ step: String, _ octave: Int, alter: Int = 0, duration: Int, type: String, voice: Int = 1, staff: Int = 1, chord: Bool = false, extra: String = "", notations: String = "") -> String {
        let alterText = alter != 0 ? "<alter>\(alter)</alter>" : ""
        let notationsText = notations.isEmpty ? "" : "<notations>\(notations)</notations>"
        return "<note>\(chord ? "<chord/>" : "")<pitch><step>\(step)</step>\(alterText)<octave>\(octave)</octave></pitch><duration>\(duration)</duration>\(extra)<voice>\(voice)</voice><type>\(type)</type><staff>\(staff)</staff>\(notationsText)</note>"
    }

    private func rest(duration: Int, type: String, voice: Int = 1, staff: Int = 1) -> String {
        "<note><rest/><duration>\(duration)</duration><voice>\(voice)</voice><type>\(type)</type><staff>\(staff)</staff></note>"
    }

    private func importXML(_ xml: String) throws -> ImportResult {
        try ParsersMusicXMLImporter().importScore(data: Data(xml.utf8), fileName: "fixture.musicxml")
    }

    func testMusicXMLChordBecomesOneEvent() throws {
        let xml = pianoPart("""
        <measure number="1">{ATTR}
        \(note("C", 4, duration: 4, type: "whole"))\(note("E", 4, duration: 4, type: "whole", chord: true))\(note("G", 4, duration: 4, type: "whole", chord: true))
        <backup><duration>4</duration></backup>
        \(note("C", 3, duration: 4, type: "whole", voice: 5, staff: 2))
        </measure>
        """)
        let result = try importXML(xml)
        let score = result.score
        XCTAssertEqual(score.metadata.title, "Fixture")
        XCTAssertEqual(score.metadata.composer, "Tester")
        XCTAssertEqual(score.measures.count, 1)
        let rh = score.measures[0].events(for: .right)
        XCTAssertEqual(rh.count, 1)
        XCTAssertEqual(rh[0].midiPitches, [60, 64, 67])
        XCTAssertEqual(rh[0].duration, 3840)
        XCTAssertEqual(rh[0].notated, NoteDuration(value: .whole))
        let lh = score.measures[0].events(for: .left)
        XCTAssertEqual(lh.map { $0.midiPitches }, [[48]])
        XCTAssertEqual(lh[0].voice, 1, "voice 5 on the lower staff is the left hand's first voice")
        XCTAssertFalse(result.hasErrors)
    }

    func testMusicXMLTieAcrossBarline() throws {
        let xml = pianoPart("""
        <measure number="1">{ATTR}
        \(rest(duration: 2, type: "half"))\(note("C", 5, duration: 2, type: "half", extra: "<tie type=\"start\"/>", notations: "<tied type=\"start\"/>"))
        </measure>
        <measure number="2">
        \(note("C", 5, duration: 2, type: "half", extra: "<tie type=\"stop\"/>", notations: "<tied type=\"stop\"/>"))\(rest(duration: 2, type: "half"))
        </measure>
        """)
        let score = try importXML(xml).score
        let first = try XCTUnwrap(score.measures[0].events.first { !$0.isRest })
        let second = try XCTUnwrap(score.measures[1].events.first { !$0.isRest })
        XCTAssertTrue(first.notes[0].tieStart)
        XCTAssertFalse(first.notes[0].tieStop)
        XCTAssertTrue(second.notes[0].tieStop)
        let timeline = score.makeTimeline()
        XCTAssertEqual(timeline.steps.count, 1, "the tie continuation is not a new attack")
        XCTAssertEqual(timeline.steps.first?.tick, 1920)
        XCTAssertEqual(timeline.events(soundingAt: 3840 + 100).flatMap { $0.pitches }, [72])
    }

    func testMusicXMLTupletsAndDots() throws {
        let tm = "<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>"
        let xml = pianoPart("""
        <measure number="1">{ATTR}
        \(note("C", 5, duration: 9, type: "quarter", extra: "", notations: "").replacingOccurrences(of: "<type>quarter</type>", with: "<type>quarter</type><dot/>"))
        \(note("D", 5, duration: 3, type: "eighth"))
        <note><pitch><step>E</step><octave>5</octave></pitch><duration>2</duration><voice>1</voice><type>eighth</type>\(tm)<staff>1</staff><notations><tuplet type="start"/></notations></note>
        <note><pitch><step>F</step><octave>5</octave></pitch><duration>2</duration><voice>1</voice><type>eighth</type>\(tm)<staff>1</staff></note>
        <note><pitch><step>G</step><octave>5</octave></pitch><duration>2</duration><voice>1</voice><type>eighth</type>\(tm)<staff>1</staff><notations><tuplet type="stop"/></notations></note>
        \(note("A", 5, duration: 6, type: "half"))
        </measure>
        """, divisions: 6)
        let rh = try importXML(xml).score.measures[0].events(for: .right)
        XCTAssertEqual(rh.map { $0.onset }, [0, 1440, 1920, 2240, 2560, 2880])
        XCTAssertEqual(rh[0].notated, NoteDuration(value: .quarter, dots: 1))
        XCTAssertEqual(rh[2].duration, 320)
        XCTAssertEqual(rh[2].notated, NoteDuration(value: .eighth, tuplet: .triplet))
    }

    func testMusicXMLPickupMeasure() throws {
        let xml = pianoPart("""
        <measure number="0" implicit="yes">{ATTR}
        \(note("G", 4, duration: 1, type: "quarter"))
        </measure>
        <measure number="1">
        \(note("C", 5, duration: 3, type: "half").replacingOccurrences(of: "<type>half</type>", with: "<type>half</type><dot/>"))
        <backup><duration>3</duration></backup>
        \(note("C", 3, duration: 3, type: "half", voice: 5, staff: 2).replacingOccurrences(of: "<type>half</type>", with: "<type>half</type><dot/>"))
        </measure>
        """, time: "<time><beats>3</beats><beat-type>4</beat-type></time>")
        let score = try importXML(xml).score
        XCTAssertTrue(score.measures[0].isPickup)
        XCTAssertEqual(score.measures[0].number, 0)
        XCTAssertFalse(score.measures[1].isPickup)
        XCTAssertEqual(score.notatedMeasureStarts, [0, 960, 3840])
        XCTAssertEqual(score.initialTime, TimeSignature(beats: 3, beatType: 4))
    }

    func testMusicXMLTwoPartLayout() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="3.1">
          <part-list>
            <score-part id="RH"><part-name>Right</part-name></score-part>
            <score-part id="LH"><part-name>Left</part-name></score-part>
          </part-list>
          <part id="RH">
            <measure number="1">
              <attributes><divisions>2</divisions><key><fifths>-1</fifths><mode>minor</mode></key><time><beats>2</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
              <note><pitch><step>A</step><octave>4</octave></pitch><duration>2</duration><voice>1</voice><type>quarter</type></note>
              <note><pitch><step>B</step><alter>-1</alter><octave>4</octave></pitch><duration>2</duration><voice>1</voice><type>quarter</type><accidental>flat</accidental></note>
            </measure>
          </part>
          <part id="LH">
            <measure number="1">
              <attributes><divisions>1</divisions><clef><sign>F</sign><line>4</line></clef></attributes>
              <note><pitch><step>D</step><octave>3</octave></pitch><duration>2</duration><voice>1</voice><type>half</type></note>
            </measure>
          </part>
        </score-partwise>
        """
        let score = try importXML(xml).score
        XCTAssertEqual(score.initialKey, KeySignature(fifths: -1, mode: .minor))
        XCTAssertEqual(score.measures[0].events(for: .right).map { $0.midiPitches }, [[69], [70]])
        XCTAssertEqual(score.measures[0].events(for: .right)[1].notes[0].accidental, .flat)
        XCTAssertEqual(score.measures[0].events(for: .left).map { $0.midiPitches }, [[50]])
        XCTAssertEqual(score.measures[0].events(for: .left)[0].duration, 1920, "each part keeps its own divisions")
    }

    func testMusicXMLRepeatsAndEndings() throws {
        let whole = { (step: String) in self.note(step, 4, duration: 4, type: "whole") }
        let xml = pianoPart("""
        <measure number="1">{ATTR}<barline location="left"><bar-style>heavy-light</bar-style><repeat direction="forward"/></barline>\(whole("C"))</measure>
        <measure number="2"><barline location="left"><ending number="1" type="start"/></barline>\(whole("D"))<barline location="right"><bar-style>light-heavy</bar-style><ending number="1" type="stop"/><repeat direction="backward"/></barline></measure>
        <measure number="3"><barline location="left"><ending number="2" type="start"/></barline>\(whole("E"))<barline location="right"><ending number="2" type="discontinue"/></barline></measure>
        <measure number="4">\(whole("F"))<barline location="right"><bar-style>light-heavy</bar-style></barline></measure>
        """)
        let score = try importXML(xml).score
        XCTAssertTrue(score.measures[0].barline.repeatForward)
        XCTAssertEqual(score.measures[1].barline.endings, [1])
        XCTAssertEqual(score.measures[1].barline.repeatBackwardTimes, 2)
        XCTAssertEqual(score.measures[2].barline.endings, [2])
        XCTAssertEqual(score.measures[3].barline.endings, [])
        XCTAssertTrue(score.measures[3].barline.isFinal)
        XCTAssertEqual(score.playbackOrder().map { $0.measureIndex }, [0, 1, 0, 2, 3])
        XCTAssertEqual(score.makeTimeline().steps.map { $0.attackPitches(for: .both) }, [[60], [62], [60], [64], [65]])
    }

    func testMusicXMLCrossStaffKeepsHand() throws {
        // Mostly conventional numbering (voice 1 upper staff, voice 5 lower staff) with one voice-1 note on staff 2.
        let quarters = ["C", "D", "E", "F"].map { note($0, 5, duration: 1, type: "quarter") }.joined()
        let xml = pianoPart("""
        <measure number="1">{ATTR}
        \(note("C", 5, duration: 1, type: "quarter"))\(note("G", 3, duration: 1, type: "quarter", voice: 1, staff: 2))\(note("D", 5, duration: 2, type: "half"))
        <backup><duration>4</duration></backup>
        \(note("C", 3, duration: 4, type: "whole", voice: 5, staff: 2))
        </measure>
        <measure number="2">\(quarters)<backup><duration>4</duration></backup>\(note("C", 3, duration: 4, type: "whole", voice: 5, staff: 2))</measure>
        """)
        let score = try importXML(xml).score
        let rh = score.measures[0].events(for: .right)
        XCTAssertEqual(rh.map { $0.midiPitches }, [[72], [55], [74]])
        XCTAssertEqual(score.measures[0].events(for: .left).map { $0.midiPitches }, [[48]])
        XCTAssertFalse(rh[0].drawnOnOtherStaff)
        XCTAssertTrue(rh[1].drawnOnOtherStaff, "voice 1 written on staff 2 is right-hand cross-staff writing")
        XCTAssertEqual(rh[1].drawnStaff, .left)
    }

    func testMusicXMLVoiceTwoOnLowerStaffWithSparseLeftHand() throws {
        // Four right-hand quarters in voice 1 and one left-hand whole note in voice 2 per measure: most notes agree with
        // the 1–4 / 5–8 convention, but the lower staff does not use it, so the staff must decide the hand.
        let quarters = ["C", "D", "E", "F"].map { note($0, 5, duration: 1, type: "quarter") }.joined()
        let xml = pianoPart("""
        <measure number="1">{ATTR}\(quarters)<backup><duration>4</duration></backup>\(note("C", 3, duration: 4, type: "whole", voice: 2, staff: 2))</measure>
        <measure number="2">\(quarters)<backup><duration>4</duration></backup>\(note("G", 2, duration: 4, type: "whole", voice: 2, staff: 2))</measure>
        """)
        let result = try importXML(xml)
        let score = result.score
        for (i, low) in [48, 43].enumerated() {
            let lh = score.measures[i].events(for: .left)
            XCTAssertEqual(lh.map { $0.midiPitches }, [[low]], "measure \(i + 1): the lower staff is the left hand")
            XCTAssertEqual(lh.first?.voice, 1)
            XCTAssertEqual(lh.first?.drawnOnOtherStaff, false)
            let rh = score.measures[i].events(for: .right)
            XCTAssertEqual(rh.map { $0.midiPitches }, [[72], [74], [76], [77]])
            XCTAssertTrue(rh.allSatisfy { !$0.drawnOnOtherStaff })
        }
        XCTAssertFalse(result.hasErrors)
        XCTAssertFalse(ScoreValidator.validate(score).contains { $0.severity == .error })
        // The rule itself: per-staff agreement, at least one lower-staff note in voices 5–8.
        func raw(_ voice: String, staff: Int) -> ParsersMusicXMLRawNote {
            var n = ParsersMusicXMLRawNote()
            n.step = "C"; n.octave = 4; n.duration = 1; n.voice = voice; n.staff = staff
            return n
        }
        let rhHeavy = Array(repeating: raw("1", staff: 1), count: 8)
        XCTAssertFalse(ParsersMusicXMLScoreBuilder.usesConventionalVoices(rhHeavy + [raw("2", staff: 2)]))
        XCTAssertTrue(ParsersMusicXMLScoreBuilder.usesConventionalVoices(rhHeavy + [raw("5", staff: 2)]))
        XCTAssertTrue(ParsersMusicXMLScoreBuilder.usesConventionalVoices([raw("1", staff: 1), raw("1", staff: 2), raw("5", staff: 2)]), "half the lower staff is enough")
        XCTAssertFalse(ParsersMusicXMLScoreBuilder.usesConventionalVoices([raw("1", staff: 1), raw("1", staff: 2), raw("1", staff: 2), raw("5", staff: 2)]))
        XCTAssertFalse(ParsersMusicXMLScoreBuilder.usesConventionalVoices(rhHeavy), "no lower-staff note in voices 5–8")
    }

    /// A score-partwise document with the given (id, name, measures) parts.
    private func parts(_ list: [(id: String, name: String, measures: String)]) -> String {
        let partList = list.map { "<score-part id=\"\($0.id)\"><part-name>\($0.name)</part-name></score-part>" }.joined()
        let bodies = list.map { "<part id=\"\($0.id)\">\($0.measures)</part>" }.joined(separator: "\n")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><score-partwise version=\"4.0\"><part-list>\(partList)</part-list>\(bodies)</score-partwise>"
    }

    private func singleStaffAttributes(clef: String) -> String {
        let sign = clef == "bass" ? "<sign>F</sign><line>4</line>" : "<sign>G</sign><line>2</line>"
        return "<attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef>\(sign)</clef></attributes>"
    }

    private func singleStaffNote(_ step: String, _ octave: Int, duration: Int, type: String) -> String {
        "<note><pitch><step>\(step)</step><octave>\(octave)</octave></pitch><duration>\(duration)</duration><voice>1</voice><type>\(type)</type></note>"
    }

    func testMusicXMLMelodyPlusGrandStaffGetsSeparateVoices() throws {
        let attr = "<attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><staves>2</staves><clef number=\"1\"><sign>G</sign><line>2</line></clef><clef number=\"2\"><sign>F</sign><line>4</line></clef></attributes>"
        let melody = "<measure number=\"1\">\(singleStaffAttributes(clef: "treble"))\(singleStaffNote("E", 5, duration: 2, type: "half"))\(singleStaffNote("D", 5, duration: 2, type: "half"))</measure>"
        let piano = "<measure number=\"1\">\(attr)\(note("C", 5, duration: 4, type: "whole"))<backup><duration>4</duration></backup>\(note("C", 3, duration: 4, type: "whole", voice: 5, staff: 2))</measure>"
        // The piano part listed first is the usual "piano + melody" order too; both orders must keep the parts apart.
        for order in [[("P1", "Voice", melody), ("P2", "Piano", piano)], [("P2", "Piano", piano), ("P1", "Voice", melody)]] {
            let result = try importXML(parts(order.map { (id: $0.0, name: $0.1, measures: $0.2) }))
            let score = result.score
            let rh = score.measures[0].events(for: .right)
            XCTAssertEqual(rh.map { $0.midiPitches }.sorted { $0[0] < $1[0] }, [[72], [74], [76]], "the treble melody joins the right hand")
            let melodyVoices = Set(rh.filter { $0.midiPitches != [72] }.map { $0.voice })
            let pianoVoices = Set(rh.filter { $0.midiPitches == [72] }.map { $0.voice })
            XCTAssertEqual(melodyVoices.count, 1)
            XCTAssertTrue(melodyVoices.isDisjoint(with: pianoVoices), "the two parts never share a right-hand voice")
            XCTAssertEqual(score.measures[0].events(for: .left).map { $0.midiPitches }, [[48]])
            XCTAssertEqual(score.measures[0].events(for: .left).first?.voice, 1)
            XCTAssertFalse(ScoreValidator.validate(score).contains { $0.message.contains("Overlapping") })
            XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("Voice") && $0.message.contains("Piano") })
        }
    }

    func testMusicXMLThreePartsGetDisjointVoices() throws {
        let m = { (clef: String, a: (String, Int), b: (String, Int)) in
            "<measure number=\"1\">\(self.singleStaffAttributes(clef: clef))\(self.singleStaffNote(a.0, a.1, duration: 2, type: "half"))\(self.singleStaffNote(b.0, b.1, duration: 2, type: "half"))</measure>"
        }
        let xml = parts([
            (id: "P1", name: "Flute", measures: m("treble", ("E", 5), ("D", 5))),
            (id: "P2", name: "Cello", measures: m("bass", ("C", 3), ("G", 2))),
            (id: "P3", name: "Bassoon", measures: m("bass", ("E", 3), ("B", 2))),
        ])
        let result = try importXML(xml)
        let score = result.score
        XCTAssertEqual(score.measures[0].events(for: .right).map { $0.voice }, [1, 1])
        let lh = score.measures[0].events(for: .left)
        XCTAssertEqual(lh.filter { $0.voice == 1 }.map { $0.midiPitches }, [[48], [43]], "second part = left hand voice 1")
        XCTAssertEqual(lh.filter { $0.voice == 2 }.map { $0.midiPitches }, [[52], [47]], "third part = left hand voice 2")
        XCTAssertFalse(ScoreValidator.validate(score).contains { $0.severity == .error })
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("Cello") && $0.message.contains("Bassoon") })
    }

    func testMusicXMLClefChangeIsReported() throws {
        let xml = pianoPart("""
        <measure number="1">{ATTR}\(note("C", 5, duration: 4, type: "whole"))<backup><duration>4</duration></backup>\(note("C", 3, duration: 4, type: "whole", voice: 5, staff: 2))</measure>
        <measure number="2"><attributes><clef number="2"><sign>G</sign><line>2</line></clef></attributes>\(note("D", 5, duration: 4, type: "whole"))<backup><duration>4</duration></backup>\(note("G", 4, duration: 4, type: "whole", voice: 5, staff: 2))</measure>
        """)
        let result = try importXML(xml)
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .info && $0.measureIndex == 1 && $0.message.contains("clef") })
        XCTAssertEqual(result.score.measures[1].events(for: .left).map { $0.midiPitches }, [[67]], "the notes keep their hand")
    }

    func testMusicXMLTempoFromDottedMetronome() throws {
        let xml = pianoPart("""
        <measure number="1">{ATTR}<direction><direction-type><metronome><beat-unit>quarter</beat-unit><beat-unit-dot/><per-minute>60</per-minute></metronome></direction-type></direction>
        \(note("C", 5, duration: 6, type: "half").replacingOccurrences(of: "<type>half</type>", with: "<type>half</type><dot/>"))
        </measure>
        """, divisions: 2, time: "<time><beats>6</beats><beat-type>8</beat-type></time>")
        let score = try importXML(xml).score
        XCTAssertEqual(score.initialTempoBPM, 90, accuracy: 0.001)
        XCTAssertEqual(score.initialTime, TimeSignature(beats: 6, beatType: 8))
    }

    func testMusicXMLDiagnosticsAreMeasureNumbered() throws {
        let xml = pianoPart("""
        <measure number="1">{ATTR}\(note("C", 5, duration: 4, type: "whole"))</measure>
        <measure number="2">\(note("D", 5, duration: 4, type: "whole"))\(note("E", 5, duration: 2, type: "half"))</measure>
        <measure number="3"><note><grace/><pitch><step>F</step><octave>5</octave></pitch><voice>1</voice><type>eighth</type><staff>1</staff></note>\(note("G", 5, duration: 4, type: "whole"))</measure>
        """)
        let result = try importXML(xml)
        let overfull = result.diagnostics.filter { $0.severity == .error }
        XCTAssertEqual(overfull.count, 1)
        XCTAssertEqual(overfull.first?.measureIndex, 1)
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .info && $0.message.contains("grace") })
        XCTAssertEqual(result.score.measures[2].events.map { $0.midiPitches }, [[79]], "grace notes are dropped")
    }

    func testMusicXMLRejectsBrokenInput() {
        XCTAssertThrowsError(try importXML("<score-partwise><part id=\"P1\">")) { error in
            guard case ImportError.malformed = error else { return XCTFail("expected malformed, got \(error)") }
        }
        XCTAssertThrowsError(try importXML("<?xml version=\"1.0\"?><html><body/></html>")) { error in
            guard case ImportError.unsupportedFormat = error else { return XCTFail("expected unsupportedFormat, got \(error)") }
        }
        XCTAssertThrowsError(try importXML(pianoPart("<measure number=\"1\">{ATTR}</measure>"))) { error in
            XCTAssertEqual(error as? ImportError, .empty)
        }
    }

    // MARK: - MXL / ZIP

    /// Builds a ZIP with stored entries byte by byte (independent of `ParsersZipArchive.build`).
    private func storedZip(_ entries: [(String, Data)]) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        for (name, data) in entries {
            let bytes = [UInt8](data)
            let crc = ParsersZipArchive.crc32(bytes)
            let nameBytes = Array(name.utf8)
            let offset = out.count
            let size = UInt32(bytes.count)
            let local: [[UInt8]] = [le32(0x0403_4b50), le16(20), le16(0), le16(0), le16(0), le16(0),
                                    le32(crc), le32(size), le32(size), le16(nameBytes.count), le16(0), nameBytes, bytes]
            out += local.flatMap { $0 }
            let directory: [[UInt8]] = [le32(0x0201_4b50), le16(20), le16(20), le16(0), le16(0), le16(0), le16(0),
                                        le32(crc), le32(size), le32(size), le16(nameBytes.count), le16(0), le16(0),
                                        le16(0), le16(0), le32(0), le32(UInt32(offset)), nameBytes]
            central += directory.flatMap { $0 }
        }
        let cdOffset = out.count
        out += central
        let end: [[UInt8]] = [le32(0x0605_4b50), le16(0), le16(0), le16(entries.count), le16(entries.count),
                              le32(UInt32(central.count)), le32(UInt32(cdOffset)), le16(0)]
        out += end.flatMap { $0 }
        return Data(out)
    }

    private var containerXML: Data {
        Data("<?xml version=\"1.0\"?><container><rootfiles><rootfile full-path=\"music/song.xml\"/></rootfiles></container>".utf8)
    }

    func testMXLStoredEntriesHandBuiltZip() throws {
        let xml = pianoPart("<measure number=\"1\">{ATTR}\(note("E", 4, duration: 4, type: "whole"))</measure>")
        let zip = storedZip([("mimetype", Data("application/vnd.recordare.musicxml".utf8)), ("META-INF/container.xml", containerXML), ("music/song.xml", Data(xml.utf8))])
        let archive = try ParsersZipArchive(data: zip)
        XCTAssertEqual(archive.entries.map { $0.name }, ["mimetype", "META-INF/container.xml", "music/song.xml"])
        XCTAssertEqual(try archive.contents(named: "music/song.xml"), Data(xml.utf8))
        let score = try ParsersMusicXMLImporter().importScore(data: zip, fileName: "song.mxl").score
        XCTAssertEqual(score.allEvents.flatMap { $0.midiPitches }, [64])
    }

    func testMXLDeflatedEntries() throws {
        let xml = pianoPart("""
        <measure number="1">{ATTR}\(note("G", 4, duration: 2, type: "half"))\(note("A", 4, duration: 2, type: "half"))</measure>
        <measure number="2">\(note("B", 4, duration: 4, type: "whole"))</measure>
        """)
        let zip = ParsersZipArchive.build(entries: [("META-INF/container.xml", containerXML), ("music/song.xml", Data(xml.utf8))], deflate: true)
        let archive = try ParsersZipArchive(data: zip)
        XCTAssertEqual(archive.entry(named: "music/song.xml")?.method, 8, "the entry is really deflated")
        let viaZip = try ParsersMusicXMLImporter().importScore(data: zip, fileName: "song.mxl").score
        let direct = try importXML(xml).score
        XCTAssertEqual(viaZip.makeTimeline().steps.map { $0.attackPitches(for: .both) }, direct.makeTimeline().steps.map { $0.attackPitches(for: .both) })
    }

    func testZipChecksumMismatchIsDetected() throws {
        var bytes = [UInt8](storedZip([("a.xml", Data("hello world".utf8))]))
        // Corrupt one payload byte (local header is 30 bytes + 5-byte name).
        bytes[30 + 5] ^= 0xFF
        let archive = try ParsersZipArchive(data: Data(bytes))
        XCTAssertThrowsError(try archive.contents(named: "a.xml")) { error in
            XCTAssertEqual(error as? ParsersZipError, .checksumMismatch(entry: "a.xml"))
        }
        XCTAssertThrowsError(try ParsersZipArchive(data: Data("not a zip at all, sorry".utf8)))
    }

    func testInflateIsCappedAndChecksDeclaredSize() throws {
        let big = Data(repeating: 0x41, count: 3 * 1024 * 1024)
        let zip = ParsersZipArchive.build(entries: [("a.xml", big)], deflate: true)
        let entry = try XCTUnwrap(try ParsersZipArchive(data: zip).entries.first)
        XCTAssertEqual(entry.method, 8)
        let start = 30 + 5 // local header + name
        let payload = Array([UInt8](zip)[start ..< start + entry.compressedSize])
        XCTAssertThrowsError(try ParsersZipArchive.inflate(payload, expectedSize: nil, entryName: "a.xml", limit: 1024 * 1024)) { error in
            XCTAssertEqual(error as? ParsersZipError, .tooLarge(entry: "a.xml", limit: 1024 * 1024), "a zip bomb stops at the cap")
        }
        XCTAssertThrowsError(try ParsersZipArchive.inflate(payload, expectedSize: 1000, entryName: "a.xml")) { error in
            XCTAssertEqual(error as? ParsersZipError, .inflateFailed(entry: "a.xml"), "output beyond the declared size stops early")
        }
        XCTAssertThrowsError(try ParsersZipArchive.inflate(payload, expectedSize: Int(UInt32.max), entryName: "a.xml")) { error in
            XCTAssertEqual(error as? ParsersZipError, .tooLarge(entry: "a.xml", limit: ParsersZipArchive.maxEntrySize), "a huge declared size is refused, not allocated")
        }
        XCTAssertEqual(try ParsersZipArchive.inflate(payload, expectedSize: big.count, entryName: "a.xml").count, big.count)
    }

    func testZip64MarkersAreRejected() throws {
        let xml = pianoPart("<measure number=\"1\">{ATTR}\(note("E", 4, duration: 4, type: "whole"))</measure>")
        var bytes = [UInt8](storedZip([("music/song.xml", Data(xml.utf8))]))
        // Central directory header: signature PK\u{01}\u{02}; the uncompressed size is at offset 24.
        let central = try XCTUnwrap((0 ..< bytes.count - 4).first { bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x01 && bytes[$0 + 3] == 0x02 })
        for k in 0..<4 { bytes[central + 24 + k] = 0xFF }
        XCTAssertThrowsError(try ParsersZipArchive(data: Data(bytes))) { error in
            XCTAssertEqual(error as? ParsersZipError, .zip64Unsupported)
        }
        XCTAssertThrowsError(try ParsersMusicXMLImporter().importScore(data: Data(bytes), fileName: "song.mxl")) { error in
            guard case ImportError.malformed = error else { return XCTFail("expected malformed, got \(error)") }
        }
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(ParsersZipArchive.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: - Standard MIDI File

    private func vlq(_ value: Int) -> [UInt8] {
        var v = value
        var out = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { out.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return out
    }

    private func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        return Array(id.utf8) + [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + body
    }

    /// Type-1 file, 480 ticks per quarter: conductor (120 BPM, 3/4, G major), right hand C5 D5 E5 quarters written with
    /// running status and note-on velocity 0 as note-off, left hand G3 dotted half on channel 2.
    private func handBuiltSMF() -> Data {
        let header = chunk("MThd", [0, 1, 0, 3, 0x01, 0xE0])
        var meta: [UInt8] = [0x00, 0xFF, 0x03, 0x04]
        meta += Array("Song".utf8)
        meta += [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]       // 500000 µs per quarter = 120 BPM
        meta += [0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08] // 3/4
        meta += [0x00, 0xFF, 0x59, 0x02, 0x01, 0x00]             // G major
        meta += [0x00, 0xFF, 0x2F, 0x00]
        let conductor = chunk("MTrk", meta)
        var rh: [UInt8] = [0x00, 0x90, 72, 90]
        rh += vlq(480)
        rh += [72, 0, 0x00, 74, 90]   // running status; velocity 0 = note-off
        rh += vlq(480)
        rh += [74, 0, 0x00, 76, 90]
        rh += vlq(480)
        rh += [76, 0, 0x00, 0xFF, 0x2F, 0x00]
        var lh: [UInt8] = [0x00, 0x91, 55, 70]
        lh += vlq(1440)
        lh += [0x81, 55, 0, 0x00, 0xFF, 0x2F, 0x00]
        var file = header
        file += conductor
        file += chunk("MTrk", rh)
        file += chunk("MTrk", lh)
        return Data(file)
    }

    func testSMFHandBuiltFile() throws {
        let result = try ParsersMIDIImporter().importScore(data: handBuiltSMF(), fileName: "song.mid")
        let score = result.score
        XCTAssertEqual(score.metadata.title, "Song")
        XCTAssertEqual(score.metadata.source, .midi)
        XCTAssertEqual(score.initialTime, TimeSignature(beats: 3, beatType: 4))
        XCTAssertEqual(score.initialKey, KeySignature(fifths: 1))
        XCTAssertEqual(score.initialTempoBPM, 120, accuracy: 0.01)
        XCTAssertEqual(score.measures.count, 1)
        let rh = score.measures[0].events(for: .right)
        XCTAssertEqual(rh.map { $0.midiPitches }, [[72], [74], [76]])
        XCTAssertEqual(rh.map { $0.onset }, [0, 960, 1920])
        let lh = score.measures[0].events(for: .left)
        XCTAssertEqual(lh.map { $0.midiPitches }, [[55]])
        XCTAssertEqual(lh.first?.duration, 2880)
        XCTAssertEqual(lh.first?.notated, NoteDuration(value: .half, dots: 1))
        XCTAssertFalse(result.hasErrors)
    }

    func testSMFReaderRawContent() throws {
        var log = ParsersDiagnosticLog()
        let content = try ParsersMIDIFileReader.read(handBuiltSMF(), log: &log)
        XCTAssertEqual(content.format, 1)
        XCTAssertEqual(content.ticksPerQuarter, 480)
        XCTAssertEqual(content.trackCount, 3)
        XCTAssertEqual(content.notes.count, 4)
        XCTAssertEqual(content.tempos.first?.bpm ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(content.meters.first.map { [$0.numerator, $0.denominator] }, [3, 4])
        XCTAssertEqual(content.keys.first?.fifths, 1)
        XCTAssertEqual(content.notes.first { $0.pitch == 55 }?.channel, 1)
    }

    func testVariableLengthQuantities() {
        var p = 0
        XCTAssertEqual(ParsersMIDIFileReader.readVLQ([0x00], &p, limit: 1), 0)
        p = 0
        XCTAssertEqual(ParsersMIDIFileReader.readVLQ([0x81, 0x00], &p, limit: 2), 128)
        XCTAssertEqual(p, 2)
        p = 0
        XCTAssertEqual(ParsersMIDIFileReader.readVLQ([0xFF, 0xFF, 0xFF, 0x7F], &p, limit: 4), 0x0FFF_FFFF)
        p = 0
        XCTAssertNil(ParsersMIDIFileReader.readVLQ([0x81, 0x80], &p, limit: 2), "truncated quantity")
    }

    func testSMFErrors() throws {
        XCTAssertThrowsError(try ParsersMIDIImporter().importScore(data: Data("hello".utf8), fileName: "x.mid"))
        // A track cut off in the middle keeps what was read and reports it.
        var bytes = [UInt8](handBuiltSMF())
        bytes.removeLast(6)
        let result = try ParsersMIDIImporter().importScore(data: Data(bytes), fileName: "x.mid")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning })
        XCTAssertEqual(result.score.measures[0].events(for: .right).filter { !$0.isRest }.count, 3)
    }

    func testSMFPickupFromShortFirstMeter() throws {
        // 1/4 for one measure, then 4/4: the first measure becomes a pickup.
        let header = chunk("MThd", [0, 0, 0, 1, 0x01, 0xE0])
        var track: [UInt8] = [0x00, 0xFF, 0x58, 0x04, 0x01, 0x02, 0x18, 0x08]
        track += [0x00, 0x90, 67, 80]
        track += vlq(480)
        track += [0x80, 67, 0, 0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08, 0x00, 0x90, 72, 80]
        track += vlq(1920)
        track += [0x80, 72, 0, 0x00, 0xFF, 0x2F, 0x00]
        var file = header
        file += chunk("MTrk", track)
        let score = try ParsersMIDIImporter().importScore(data: Data(file), fileName: "pickup.mid").score
        XCTAssertTrue(score.measures[0].isPickup)
        XCTAssertEqual(score.initialTime, .common)
        XCTAssertEqual(score.notatedMeasureStarts.prefix(2), [0, 960])
        XCTAssertEqual(score.makeTimeline().steps.map { $0.tick }, [0, 960])
    }

    // MARK: - Quantization and hands

    func testGridChoice() {
        XCTAssertEqual(ParsersMIDIImporter.chooseGrid(onsets: [0, 240, 480, 720, 960]), 240)
        XCTAssertEqual(ParsersMIDIImporter.chooseGrid(onsets: [0, 320, 640, 960, 1280, 1600]), 80, "eighth triplets")
        XCTAssertEqual(ParsersMIDIImporter.chooseGrid(onsets: [0, 120, 240, 360, 480]), 120, "32nds")
        XCTAssertEqual(ParsersMIDIImporter.chooseGrid(onsets: [0, 120, 320, 640, 960]), 40, "32nds mixed with triplets")
        // A loosely played straight rhythm stays on the 16th grid.
        XCTAssertEqual(ParsersMIDIImporter.chooseGrid(onsets: [5, 250, 470, 735, 955, 1210, 1430, 1675]), 240)
        XCTAssertEqual(ParsersMIDIImporter.meanGridError(onsets: [0, 120], step: 240), 60)
    }

    func testQuantizeSnapsAndCleansOverlaps() {
        let notes = [
            ParsersMIDINote(onset: 13, end: 470, midi: 60, stream: 0),
            ParsersMIDINote(onset: 470, end: 500, midi: 62, stream: 0),     // too short: keeps one grid step
            ParsersMIDINote(onset: 950, end: 2000, midi: 64, stream: 0),
            ParsersMIDINote(onset: 1440, end: 1900, midi: 64, stream: 0),   // re-attack cuts the earlier E
            ParsersMIDINote(onset: 950, end: 1440, midi: 64, stream: 1),    // unison in the other hand survives
            ParsersMIDINote(onset: 5, end: 300, midi: 60, stream: 0),       // duplicate attack, shorter: dropped
        ]
        let q = ParsersMIDIImporter.quantize(notes, step: 240)
        XCTAssertEqual(q.map { [$0.onset, $0.end, $0.midi, $0.stream] }, [
            [0, 480, 60, 0],
            [480, 720, 62, 0],
            [960, 1440, 64, 0],
            [960, 1440, 64, 1],
            [1440, 1920, 64, 0],
        ])
    }

    func testHandSplitSingleStream() {
        let notes = [
            ParsersMIDINote(onset: 0, end: 960, midi: 67, stream: 0),
            ParsersMIDINote(onset: 0, end: 960, midi: 48, stream: 0),     // low: left
            ParsersMIDINote(onset: 960, end: 1920, midi: 64, stream: 0),
            ParsersMIDINote(onset: 960, end: 1920, midi: 57, stream: 0),  // below C4 but the right hand is busy: left
            ParsersMIDINote(onset: 1920, end: 2880, midi: 59, stream: 0), // right hand idle, within a 6th of it: right
            ParsersMIDINote(onset: 2880, end: 3840, midi: 43, stream: 0), // right hand idle but far below: left
        ]
        let hands = ParsersMIDIImporter.assignHands(notes, streamCount: 1)
        XCTAssertEqual(hands, [.right, .left, .right, .left, .right, .left])
    }

    func testHandSplitTwoStreamsAndTrackNames() {
        let notes = [
            ParsersMIDINote(onset: 0, end: 960, midi: 50, stream: 0),
            ParsersMIDINote(onset: 0, end: 960, midi: 72, stream: 1),
            ParsersMIDINote(onset: 960, end: 1920, midi: 62, stream: 0),
        ]
        XCTAssertEqual(ParsersMIDIImporter.assignHands(notes, streamCount: 2), [.left, .right, .left])
        XCTAssertEqual(ParsersMIDIImporter.assignHands(notes, streamCount: 2, streamHands: [0: .right, 1: .left]), [.right, .left, .right])
        XCTAssertEqual(ParsersMIDIImporter.hand(forTrackName: "Piano LH"), .left)
        XCTAssertEqual(ParsersMIDIImporter.hand(forTrackName: "Right Hand"), .right)
        XCTAssertNil(ParsersMIDIImporter.hand(forTrackName: "Acoustic Grand"))
        XCTAssertEqual(ParsersMIDIImporter.hand(forTrackName: "Piano L.H."), .left)
        XCTAssertEqual(ParsersMIDIImporter.hand(forTrackName: "Bass"), .left)
        XCTAssertEqual(ParsersMIDIImporter.hand(forTrackName: "Treble staff"), .right)
        XCTAssertEqual(ParsersMIDIImporter.hand(forTrackName: "Rechte Hand"), .right)
        // Names are matched by whole word only.
        XCTAssertNil(ParsersMIDIImporter.hand(forTrackName: "Bright Acoustic Piano"))
        XCTAssertNil(ParsersMIDIImporter.hand(forTrackName: "Copyright 2021"))
        XCTAssertNil(ParsersMIDIImporter.hand(forTrackName: "Bassoon"))
        XCTAssertNil(ParsersMIDIImporter.hand(forTrackName: "Contrabass"))
        XCTAssertEqual(ParsersMIDIImporter.hand(forTrackName: "cleft"), nil)
        XCTAssertNil(ParsersMIDIImporter.hand(forTrackName: "Left + Right"), "a name naming both hands decides nothing")
    }

    func testSingleNamedStreamIsStillSplitByPitch() {
        // One track called "Bright Acoustic Piano" (or even "Right Hand") holding both hands.
        let pitches = [48, 72, 43, 74, 45, 76, 41, 77]
        let notes = pitches.enumerated().map { i, midi in ParsersMIDINote(onset: (i / 2) * 960, end: (i / 2) * 960 + 960, midi: midi, stream: 0) }
        let expected: [Hand] = [.left, .right, .left, .right, .left, .right, .left, .right]
        XCTAssertEqual(ParsersMIDIImporter.assignHands(notes, streamCount: 1, streamHands: [0: .right]), expected)
        XCTAssertEqual(ParsersMIDIImporter.assignHands(notes, streamCount: 1), expected)
        // Two streams named for the same hand do not decide either: the average-pitch rule applies.
        let two = [ParsersMIDINote(onset: 0, end: 960, midi: 50, stream: 0), ParsersMIDINote(onset: 0, end: 960, midi: 72, stream: 1)]
        XCTAssertEqual(ParsersMIDIImporter.assignHands(two, streamCount: 2, streamHands: [0: .right, 1: .right]), [.left, .right])
    }

    func testKeyEstimation() {
        var cMajor = [Double](repeating: 0, count: 12)
        for pc in [0, 2, 4, 5, 7, 9, 11] { cMajor[pc] = 1 }
        cMajor[0] = 3; cMajor[7] = 2; cMajor[4] = 2
        XCTAssertEqual(ParsersMIDIImporter.estimateKey(histogram: cMajor), KeySignature(fifths: 0, mode: .major))

        var dMajor = [Double](repeating: 0, count: 12)
        for pc in [2, 4, 6, 7, 9, 11, 1] { dMajor[pc] = 1 }
        dMajor[2] = 3; dMajor[9] = 2; dMajor[6] = 2
        XCTAssertEqual(ParsersMIDIImporter.estimateKey(histogram: dMajor), KeySignature(fifths: 2, mode: .major))

        var aMinor = [Double](repeating: 0, count: 12)
        aMinor[9] = 10; aMinor[0] = 6; aMinor[4] = 8; aMinor[8] = 3; aMinor[11] = 2; aMinor[2] = 2; aMinor[5] = 2
        XCTAssertEqual(ParsersMIDIImporter.estimateKey(histogram: aMinor), KeySignature(fifths: 0, mode: .minor))

        XCTAssertNil(ParsersMIDIImporter.estimateKey(histogram: [Double](repeating: 0, count: 12)))
    }

    func testVoiceSlicingTiesAcrossBarlineAndFillsRests() {
        let slots = [
            ParsersMIDIScoreBuilder.MeasureSlot(start: 0, length: 3840, time: .common),
            ParsersMIDIScoreBuilder.MeasureSlot(start: 3840, length: 3840, time: .common),
        ]
        // A half note starting on beat 4 of measure 1: quarter tied over the barline to a quarter.
        let notes = [ParsersMIDINote(onset: 2880, end: 4800, midi: 65, stream: 0)]
        let events = ParsersMIDIScoreBuilder.voiceEvents(notes, hand: .right, voice: 1, slots: slots, keyAt: { _ in .cMajor }, keepRestMeasures: true)
        XCTAssertEqual(events[0].map { [$0.onset, $0.duration, $0.notes.count] }, [[0, 2880, 0], [2880, 960, 1]])
        XCTAssertEqual(events[0][0].notated, NoteDuration(value: .half, dots: 1))
        XCTAssertTrue(events[0][1].notes[0].tieStart)
        XCTAssertEqual(events[1].map { [$0.onset, $0.duration, $0.notes.count] }, [[0, 960, 1], [960, 2880, 0]])
        XCTAssertTrue(events[1][0].notes[0].tieStop)
        XCTAssertFalse(events[1][0].notes[0].tieStart)
    }

    func testHeldNoteMovesToSecondVoice() {
        let notes = [
            ParsersMIDINote(onset: 0, end: 3840, midi: 48, stream: 0),
            ParsersMIDINote(onset: 0, end: 960, midi: 55, stream: 0),
            ParsersMIDINote(onset: 960, end: 1920, midi: 52, stream: 0),
            ParsersMIDINote(onset: 1920, end: 2880, midi: 55, stream: 0),
            ParsersMIDINote(onset: 2880, end: 3840, midi: 52, stream: 0),
        ]
        let (v1, v2) = ParsersMIDIScoreBuilder.separateVoices(notes, step: 240)
        XCTAssertEqual(v2.map { $0.midi }, [48])
        XCTAssertEqual(v1.map { $0.midi }, [55, 52, 55, 52])
        let trimmed = ParsersMIDIScoreBuilder.trimLegato([
            ParsersMIDINote(onset: 0, end: 1000, midi: 60, stream: 0),
            ParsersMIDINote(onset: 960, end: 1920, midi: 62, stream: 0),
        ], step: 240)
        XCTAssertEqual(trimmed.map { $0.end }, [960, 1920], "a 40-tick legato overlap is removed")
    }

    // MARK: - Duration splitting

    func testDurationSplitter() {
        XCTAssertEqual(ParsersDurationSplitter.split(ticks: 1440).map { $0.notated }, [NoteDuration(value: .quarter, dots: 1)])
        XCTAssertEqual(ParsersDurationSplitter.split(ticks: 1200, onset: 0).map { $0.ticks }, [960, 240])
        XCTAssertEqual(ParsersDurationSplitter.split(ticks: 1200, onset: 240).map { $0.ticks }, [240, 960], "off the beat: short first")
        let fiveTwelfths = ParsersDurationSplitter.split(ticks: 400)
        XCTAssertEqual(fiveTwelfths.count, 2, "two tied values, never five small ones")
        XCTAssertEqual(fiveTwelfths.reduce(0) { $0 + $1.ticks }, 400)
        XCTAssertTrue(fiveTwelfths.allSatisfy { $0.notated?.ticks == $0.ticks })
        XCTAssertEqual(ParsersDurationSplitter.split(ticks: 4800).map { $0.ticks }, [3840, 960])
        XCTAssertEqual(ParsersDurationSplitter.split(ticks: 4800).reduce(0) { $0 + $1.ticks }, 4800)
        let odd = ParsersDurationSplitter.split(ticks: 965)
        XCTAssertEqual(odd.reduce(0) { $0 + $1.ticks }, 965)
        XCTAssertNil(odd.last?.notated, "an inexpressible remainder is kept without a notated value")
    }

    // MARK: - LPC

    private let minuet = """
    {
      "format": "lpc-1", "title": "Minuet in G", "composer": "Christian Petzold",
      "divisions": 4, "time": "3/4", "key": 1, "tempo": 112, "pickup": false,
      "measures": [
        { "n": 1,
          "rh": [ { "p": ["D5"], "d": 4, "f": [5] }, { "p": ["G4"], "d": 2 }, { "p": ["A4"], "d": 2 }, { "p": ["B4"], "d": 2 }, { "p": ["C5"], "d": 2 } ],
          "lh": [ { "p": ["G3", "B3"], "d": 8 }, { "p": ["A3"], "d": 4 } ],
          "confidence": 0.95 }
      ]
    }
    """

    func testLPCHandAuthoredForm() throws {
        let parsed = try ParsersCompactScoreImporter().parse(json: minuet)
        XCTAssertTrue(parsed.isValid, parsed.issues.map { $0.description }.joined(separator: "\n"))
        let score = parsed.importResult.score
        XCTAssertEqual(score.metadata.title, "Minuet in G")
        XCTAssertEqual(score.metadata.source, .compactJSON)
        XCTAssertEqual(score.initialKey, KeySignature(fifths: 1))
        XCTAssertEqual(score.initialTempoBPM, 112)
        XCTAssertEqual(score.initialTime, TimeSignature(beats: 3, beatType: 4))
        let rh = score.measures[0].events(for: .right)
        XCTAssertEqual(rh.map { $0.onset }, [0, 960, 1440, 1920, 2400])
        XCTAssertEqual(rh[0].notes[0].fingering, 5)
        XCTAssertEqual(rh[0].notated, NoteDuration(value: .quarter))
        XCTAssertEqual(score.measures[0].events(for: .left).map { $0.midiPitches }, [[55, 59], [57]])
        XCTAssertEqual(parsed.confidence, [0.95])
    }

    func testLPCSchemaForm() throws {
        let json = """
        {"format":"lpc-1","title":"","composer":"","divisions":12,"time":"2/4","key":-2,"tempo":90,"pickup":true,"measures":[
          {"n":1,"time":"","key":-2,"tempo":90,"confidence":1,
           "rh":[{"p":["Bb4"],"d":12,"tie":"","t":[],"f":[],"s":""}],
           "lh":[{"p":[],"d":12,"tie":"","t":[],"f":[],"s":""}],"rh2":[],"lh2":[]},
          {"n":2,"time":"","key":-2,"tempo":90,"confidence":0.5,
           "rh":[{"p":["C5"],"d":4,"tie":"","t":[3,2],"f":[],"s":""},{"p":["D5"],"d":4,"tie":"","t":[3,2],"f":[],"s":""},{"p":["Eb5"],"d":4,"tie":"start","t":[3,2],"f":[],"s":""},{"p":["Eb5"],"d":12,"tie":"stop","t":[],"f":[],"s":""}],
           "lh":[{"p":["Bb2"],"d":24,"tie":"","t":[],"f":[],"s":""}],
           "rh2":[],"lh2":[{"p":["F3"],"d":12,"tie":"","t":[],"f":[],"s":"up"},{"p":[],"d":12,"tie":"","t":[],"f":[],"s":""}]}
        ]}
        """
        let parsed = try ParsersCompactScoreImporter().parse(json: json, fileName: "page1.json")
        XCTAssertTrue(parsed.isValid, parsed.issues.map { $0.description }.joined(separator: "\n"))
        let score = parsed.importResult.score
        XCTAssertEqual(score.metadata.title, "page1")
        XCTAssertTrue(score.measures[0].isPickup)
        XCTAssertEqual(score.notatedMeasureStarts, [0, 960, 2880])
        let rh = score.measures[1].events(for: .right)
        XCTAssertEqual(rh[0].notated, NoteDuration(value: .eighth, tuplet: .triplet))
        XCTAssertEqual(rh[0].duration, 320)
        XCTAssertTrue(rh[2].notes[0].tieStart)
        XCTAssertTrue(rh[3].notes[0].tieStop)
        let lh2 = score.measures[1].events.filter { $0.hand == .left && $0.voice == 2 }
        XCTAssertTrue(lh2[0].drawnOnOtherStaff)
        XCTAssertEqual(score.measures[1].tempoBPM, nil, "repeating the current tempo is not a change")
        XCTAssertEqual(parsed.confidence, [1, 0.5])
    }

    func testLPCValidationErrorsAreMeasureNumbered() throws {
        let json = """
        {"format":"lpc-1","title":"Broken","composer":"","divisions":4,"time":"4/4","key":0,"tempo":100,"pickup":false,"measures":[
          {"n":1,"rh":[{"p":["C4"],"d":8},{"p":["H4"],"d":4},{"p":["C4","C4"],"d":2}],"lh":[{"p":["C3"],"d":16}]},
          {"n":3,"rh":[{"p":["C9"],"d":16}],"lh":[{"p":["C3"],"d":16,"tie":"start"}]},
          {"n":3,"rh":[{"p":["E4"],"d":16,"t":[3],"f":[6]}],"lh":[{"p":["D3"],"d":16}]},
          {"n":4,"rh":[{"p":["G4"],"d":16,"f":[1,2]}],"lh":[]}
        ]}
        """
        let parsed = try ParsersCompactScoreImporter().parse(json: json)
        XCTAssertFalse(parsed.isValid)
        func has(_ measure: Int?, _ voice: String, _ fragment: String) -> Bool {
            parsed.errors.contains { $0.measure == measure && $0.voice == voice && $0.message.contains(fragment) }
        }
        XCTAssertTrue(has(1, "rh", "H4"), "bad pitch name")
        XCTAssertTrue(has(1, "rh", "twice"), "duplicate pitch in a chord")
        XCTAssertTrue(has(1, "rh", "lasts 14 divisions"), "voice sum (the bad pitch's duration still counts)")
        XCTAssertTrue(has(2, "", "Measure number is 3 but 2 was expected"))
        XCTAssertTrue(has(2, "rh", "outside the piano range"))
        XCTAssertTrue(has(2, "lh", "starts a tie"))
        XCTAssertTrue(has(3, "rh", "\"t\" must be two positive integers"))
        XCTAssertTrue(has(3, "rh", "fingering 6"))
        XCTAssertTrue(has(4, "rh", "\"f\" may not be longer"))
        XCTAssertTrue(has(4, "lh", "is empty"))
        // Core diagnostics mirror the issues with 0-based measure indices and hands.
        XCTAssertTrue(parsed.importResult.diagnostics.contains { $0.severity == .error && $0.measureIndex == 3 && $0.hand == .left && $0.voice == 1 })
        XCTAssertTrue(parsed.importResult.hasErrors)

        // Machine-readable JSON: an array of {measure, voice, message}.
        let decoded = try JSONSerialization.jsonObject(with: Data(parsed.errorsJSON.utf8)) as? [[String: Any]]
        let first = try XCTUnwrap(decoded?.first)
        XCTAssertEqual(Set(first.keys), ["measure", "voice", "message"])
        XCTAssertEqual(decoded?.count, parsed.errors.count)
    }

    func testLPCHeaderErrors() throws {
        let json = """
        {"format":"lpc-2","divisions":0,"time":"four","key":9,"tempo":500,"measures":[]}
        """
        let parsed = try ParsersCompactScoreImporter().parse(json: json)
        let messages = parsed.errors.map { $0.message }
        XCTAssertTrue(parsed.errors.allSatisfy { $0.measure == nil })
        XCTAssertTrue(messages.contains { $0.contains("\"format\"") })
        XCTAssertTrue(messages.contains { $0.contains("\"divisions\"") })
        XCTAssertTrue(messages.contains { $0.contains("\"time\"") })
        XCTAssertTrue(messages.contains { $0.contains("\"key\"") })
        XCTAssertTrue(messages.contains { $0.contains("\"tempo\"") })
        XCTAssertTrue(messages.contains { $0.contains("\"measures\" is empty") })
        XCTAssertTrue(parsed.errorsJSON.contains("\"measure\":null"))
    }

    func testLPCShortMeasuresAndWrappers() throws {
        // With a pickup, the final measure may be short (it completes the pickup); a middle one may not.
        // Text around the JSON (a code fence) is tolerated.
        let json = """
        ```json
        {"format":"lpc-1","title":"T","composer":"","divisions":1,"time":"3/4","key":0,"tempo":80,"pickup":true,"measures":[
          {"n":1,"rh":[{"p":["E4"],"d":1}],"lh":[{"p":[],"d":1}]},
          {"n":2,"rh":[{"p":["F4"],"d":2}],"lh":[{"p":[],"d":3}]},
          {"n":3,"rh":[{"p":["G4"],"d":2}],"lh":[{"p":[],"d":2}]}
        ]}
        ```
        """
        let parsed = try ParsersCompactScoreImporter().parse(json: json)
        XCTAssertEqual(parsed.errors.map { $0.measure }, [2])
        XCTAssertEqual(parsed.errors.first?.voice, "rh")
        // Without a pickup the final measure must be complete too.
        let noPickup = json.replacingOccurrences(of: "\"pickup\":true", with: "\"pickup\":false")
            .replacingOccurrences(of: "\"d\":1}]", with: "\"d\":3}]")
        let strict = try ParsersCompactScoreImporter().parse(json: noPickup)
        XCTAssertEqual(Set(strict.errors.compactMap { $0.measure }), [2, 3])
        XCTAssertThrowsError(try ParsersCompactScoreImporter().parse(json: "[1, 2, 3]"))
        XCTAssertThrowsError(try ParsersCompactScoreImporter().parse(json: "not json"))
    }

    func testLPCPageFlowShortLastMeasure() throws {
        // A later page (measures 5–6) whose last measure is short.
        let page = """
        {"format":"lpc-1","title":"T","composer":"","divisions":4,"time":"4/4","key":0,"tempo":100,"pickup":false,"measures":[
          {"n":5,"rh":[{"p":["C4"],"d":16}],"lh":[{"p":[],"d":16}]},
          {"n":6,"rh":[{"p":["C4"],"d":4}],"lh":[{"p":[],"d":16}]}
        ]}
        """
        let middle = try ParsersCompactScoreImporter(firstMeasureNumber: 5, isFinalPage: false, pieceHasPickup: true).parse(json: page)
        XCTAssertFalse(middle.isValid, "the end of a page is not the end of the piece")
        XCTAssertEqual(middle.errors.map { $0.measure }, [6])
        XCTAssertEqual(middle.errors.first?.voice, "rh")
        XCTAssertNotEqual(middle.errorsJSON, "[]")

        let lastWithoutPickup = try ParsersCompactScoreImporter(firstMeasureNumber: 5, isFinalPage: true, pieceHasPickup: false).parse(json: page)
        XCTAssertEqual(lastWithoutPickup.errors.map { $0.measure }, [6], "only a pickup lets the final measure be short")

        let lastWithPickup = try ParsersCompactScoreImporter(firstMeasureNumber: 5, isFinalPage: true, pieceHasPickup: true).parse(json: page)
        XCTAssertTrue(lastWithPickup.isValid, lastWithPickup.issues.map { $0.description }.joined(separator: "\n"))
        XCTAssertFalse(lastWithPickup.importResult.score.measures[0].isPickup, "page 1 holds the pickup, not this page")
    }

    func testLPCFirstMeasureChangesBecomeInitialValues() throws {
        let json = """
        {"format":"lpc-1","title":"T","composer":"","divisions":1,"time":"4/4","key":0,"tempo":100,"pickup":false,"measures":[
          {"n":1,"time":"3/4","key":2,"tempo":60,"rh":[{"p":["D4"],"d":3}],"lh":[{"p":[],"d":3}]},
          {"n":2,"time":"3/4","key":2,"tempo":60,"rh":[{"p":["E4"],"d":3}],"lh":[{"p":[],"d":3}]}
        ]}
        """
        let parsed = try ParsersCompactScoreImporter().parse(json: json)
        XCTAssertTrue(parsed.isValid, parsed.issues.map { $0.description }.joined(separator: "\n"))
        let score = parsed.importResult.score
        XCTAssertEqual(score.initialTime, TimeSignature(beats: 3, beatType: 4))
        XCTAssertEqual(score.initialKey, KeySignature(fifths: 2))
        XCTAssertEqual(score.initialTempoBPM, 60)
        XCTAssertNil(score.measures[0].timeSignature)
        XCTAssertNil(score.measures[0].keySignature)
        XCTAssertNil(score.measures[0].tempoBPM)
        XCTAssertNil(score.measures[1].timeSignature, "repeating the value in force is not a change")
    }

    func testLPCIssueConversionFromValidator() {
        let diagnostics = [ScoreDiagnostic(.error, measureIndex: 2, hand: .left, voice: 2, message: "Overlap")]
        let issues = ParsersCompactScoreIssue.from(diagnostics, measureNumbers: [5, 6, 7])
        XCTAssertEqual(issues, [ParsersCompactScoreIssue(measure: 7, voice: "lh2", message: "Overlap")])
    }

    // MARK: - Export round trip

    /// A score with a pickup, ties across a barline, a triplet, a chord with fingering, cross-staff writing, a second
    /// voice, a key and tempo change, and a repeat with volta endings.
    private func richScore() -> Score {
        let triplet = NoteDuration(value: .eighth, tuplet: .triplet)
        func p(_ s: String) -> Pitch { Pitch(name: s) ?? Pitch(step: .C, octave: 4) }
        let m0 = Measure(number: 0, isPickup: true, events: [
            MeasureEvent(onset: 0, duration: 960, notes: [ChordNote(pitch: p("G4"), fingering: 1)], hand: .right),
        ], barline: Barline(repeatForward: true))
        let m1 = Measure(number: 1, events: [
            MeasureEvent(onset: 0, duration: 320, notated: triplet, notes: [ChordNote(pitch: p("C5"))], hand: .right),
            MeasureEvent(onset: 320, duration: 320, notated: triplet, notes: [ChordNote(pitch: p("D5"))], hand: .right),
            MeasureEvent(onset: 640, duration: 320, notated: triplet, notes: [ChordNote(pitch: p("E5"))], hand: .right),
            MeasureEvent(onset: 960, duration: 1920, notes: [ChordNote(pitch: p("F#5"))], hand: .right),
            MeasureEvent(onset: 0, duration: 2880, notes: [ChordNote(pitch: p("C3")), ChordNote(pitch: p("G3"), fingering: 1)], hand: .left),
            MeasureEvent(onset: 0, duration: 1920, notes: [ChordNote(pitch: p("E3"))], hand: .left, voice: 2),
            MeasureEvent(onset: 1920, duration: 960, notes: [], hand: .left, voice: 2),
        ], barline: Barline(endings: [1]))
        let m1b = Measure(number: 2, events: [
            MeasureEvent(onset: 0, duration: 2880, notes: [ChordNote(pitch: p("B4"), tieStart: true)], hand: .right),
            MeasureEvent(onset: 0, duration: 2880, notes: [ChordNote(pitch: p("D4"))], hand: .left, drawnOnOtherStaff: true),
        ], barline: Barline(repeatBackwardTimes: 2, endings: [1]))
        let m2 = Measure(number: 3, keySignature: KeySignature(fifths: -1), tempoBPM: 72, events: [
            MeasureEvent(onset: 0, duration: 960, notes: [ChordNote(pitch: p("B4"), tieStop: true)], hand: .right),
            MeasureEvent(onset: 960, duration: 1920, notes: [ChordNote(pitch: p("Bb4"))], hand: .right),
            MeasureEvent(onset: 0, duration: 2880, notes: [ChordNote(pitch: p("G2"))], hand: .left),
        ], barline: Barline(endings: [2], isFinal: true))
        var metadata = ScoreMetadata(title: "Rich & <Strange>", composer: "Tester", arrangementLabel: "Easy", difficulty: .intermediate, genre: "Waltz", source: .compactJSON)
        metadata.notes = "Exported for sharing"
        return Score(metadata: metadata, initialTime: TimeSignature(beats: 3, beatType: 4), initialKey: KeySignature(fifths: 1), initialTempoBPM: 96, measures: [m0, m1, m1b, m2])
    }

    func testExportRoundTripPreservesTimeline() throws {
        let score = richScore()
        let xml = ParsersMusicXMLExporter().exportString(score)
        XCTAssertTrue(xml.contains("<work-title>Rich &amp; &lt;Strange&gt;</work-title>"))
        XCTAssertTrue(xml.contains("<repeat direction=\"backward\"/>"))
        XCTAssertTrue(xml.contains("<ending number=\"1\" type=\"start\"/>"))
        XCTAssertTrue(xml.contains("implicit=\"yes\""))

        let result = try ParsersMusicXMLImporter().importScore(data: Data(xml.utf8), fileName: "shared.musicxml")
        XCTAssertFalse(result.hasErrors, result.diagnostics.map { $0.description }.joined(separator: "\n"))
        let again = result.score
        XCTAssertEqual(again.metadata.title, "Rich & <Strange>")
        XCTAssertEqual(again.metadata.difficulty, .intermediate)
        XCTAssertEqual(again.metadata.arrangementLabel, "Easy")
        XCTAssertEqual(again.metadata.genre, "Waltz")
        XCTAssertEqual(again.metadata.notes, "Exported for sharing")
        XCTAssertEqual(again.initialKey, score.initialKey)
        XCTAssertEqual(again.initialTime, score.initialTime)
        XCTAssertEqual(again.initialTempoBPM, 96)
        XCTAssertEqual(again.measures.map { $0.isPickup }, score.measures.map { $0.isPickup })
        XCTAssertEqual(again.measures.map { $0.barline }, score.measures.map { $0.barline })
        XCTAssertEqual(again.measures[3].keySignature, KeySignature(fifths: -1))
        XCTAssertEqual(again.measures[3].tempoBPM, 72)

        func signature(_ t: PlaybackTimeline) -> [String] {
            t.events.map { e in
                let notes = e.notes.map { "\($0.pitch.name)\($0.tieStart ? "~" : "")\($0.tieStop ? "^" : "")\($0.fingering.map { "f\($0)" } ?? "")" }
                return "\(e.tick) \(e.duration) \(e.hand.rawValue) v\(e.voice) \(notes) \(e.attackPitches)"
            }.sorted()
        }
        let a = score.makeTimeline(), b = again.makeTimeline()
        XCTAssertEqual(signature(a), signature(b))
        XCTAssertEqual(a.segments.map { $0.measureIndex }, [0, 1, 2, 0, 3])
        XCTAssertEqual(b.segments.map { $0.measureIndex }, a.segments.map { $0.measureIndex })
        XCTAssertEqual(a.tempoMap, b.tempoMap)
        let crossStaff = again.measures[2].events.first { $0.hand == .left }
        XCTAssertEqual(crossStaff?.drawnOnOtherStaff, true)
        let triplet = again.measures[1].events.first { $0.hand == .right }
        XCTAssertEqual(triplet?.notated, NoteDuration(value: .eighth, tuplet: .triplet))
    }

    func testExportKeepsMeasureZeroOverrides() throws {
        // Score-level 4/4 at 100 BPM, but the first measure itself says 3/4 at 60 BPM in D major (Core honours the
        // measure's values from tick 0).
        let score = Score(metadata: ScoreMetadata(title: "Override"), initialTime: .common, initialKey: .cMajor, initialTempoBPM: 100, measures: [
            Measure(number: 1, timeSignature: TimeSignature(beats: 3, beatType: 4), keySignature: KeySignature(fifths: 2), tempoBPM: 60, events: [
                MeasureEvent(onset: 0, duration: 2880, notes: [ChordNote(pitch: Pitch(step: .D, octave: 4))], hand: .right),
            ]),
            Measure(number: 2, events: [
                MeasureEvent(onset: 0, duration: 2880, notes: [ChordNote(pitch: Pitch(step: .F, alter: 1, octave: 4))], hand: .right),
            ]),
        ])
        let again = try ParsersMusicXMLImporter().importScore(data: ParsersMusicXMLExporter().exportData(score), fileName: "x.musicxml").score
        XCTAssertEqual(again.timeSignature(atMeasure: 1), TimeSignature(beats: 3, beatType: 4))
        XCTAssertEqual(again.keySignature(atMeasure: 1), KeySignature(fifths: 2))
        XCTAssertEqual(again.tempoBPM(atMeasure: 1), 60)
        XCTAssertEqual(again.makeTimeline().totalSeconds(), score.makeTimeline().totalSeconds(), accuracy: 1e-9)
        XCTAssertEqual(score.makeTimeline().totalSeconds(), 6.0, accuracy: 1e-9)
        XCTAssertEqual(again.notatedMeasureStarts, score.notatedMeasureStarts)
    }

    func testExportIsDeterministicAndWritesAccidentals() {
        let score = richScore()
        XCTAssertEqual(ParsersMusicXMLExporter().exportString(score), ParsersMusicXMLExporter().exportString(score))
        var memory = ParsersAccidentalMemory(key: .cMajor)
        let fSharp = ChordNote(pitch: Pitch(step: .F, alter: 1, octave: 4))
        XCTAssertEqual(memory.display(for: fSharp, staff: .right), .sharp)
        XCTAssertNil(memory.display(for: fSharp, staff: .right), "measure memory")
        XCTAssertEqual(memory.display(for: ChordNote(pitch: Pitch(step: .F, octave: 4)), staff: .right), .natural)
        XCTAssertEqual(memory.display(for: fSharp, staff: .left), .sharp, "memory is per staff")
        var gMajor = ParsersAccidentalMemory(key: KeySignature(fifths: 1))
        XCTAssertNil(gMajor.display(for: fSharp, staff: .right))
        XCTAssertEqual(gMajor.display(for: ChordNote(pitch: Pitch(step: .F, octave: 5)), staff: .right), .natural)
    }

    func testTupletBracketGrouping() {
        let t = NoteDuration(value: .eighth, tuplet: .triplet)
        let events = (0..<6).map { MeasureEvent(onset: $0 * 320, duration: 320, notated: t, notes: [], hand: .right) }
            + [MeasureEvent(onset: 1920, duration: 960, notes: [], hand: .right)]
        XCTAssertEqual(ParsersMusicXMLExporter.tupletBrackets(events), [.start, .none, .stop, .start, .none, .stop, .none])
        XCTAssertEqual(ParsersMusicXMLExporter.format(72), "72")
        XCTAssertEqual(ParsersMusicXMLExporter.format(72.5), "72.5")
    }

    func testExportedMIDIAndLPCScoresSurviveExport() throws {
        // Scores coming from the other importers are saved through the exporter; they must re-import unchanged.
        let midi = try ParsersMIDIImporter().importScore(data: handBuiltSMF(), fileName: "song.mid").score
        let lpc = try ParsersCompactScoreImporter().parse(json: minuet).importResult.score
        for score in [midi, lpc] {
            let again = try ParsersMusicXMLImporter().importScore(data: ParsersMusicXMLExporter().exportData(score), fileName: "x.musicxml").score
            XCTAssertEqual(again.makeTimeline().steps.map { "\($0.tick):\($0.attackPitches(for: .both))" },
                           score.makeTimeline().steps.map { "\($0.tick):\($0.attackPitches(for: .both))" })
            XCTAssertEqual(again.makeTimeline().totalTicks, score.makeTimeline().totalTicks)
        }
    }
}
