import Foundation
import CoreGraphics

/// Entry point of the engraver: turns a `Score` (notated order) into a `NotationLayout`.
///
/// The engine is pure and synchronous; callers run it off the main thread (see `NotationLayoutCache`).
enum NotationLayoutEngine {
    /// Engraves a score for the given options.
    static func layout(score: Score, options: NotationLayoutOptions) -> NotationLayout {
        guard !score.measures.isEmpty else { return .empty(options: options) }
        var engraver = NotationEngraver(score: score, options: options)
        return engraver.run()
    }

    /// The notated value used to draw an event: its `notated` duration, an exact match for its length, or
    /// (for lengths no single symbol can express) the largest value of the tied chain that would spell it.
    static func displayDuration(of event: MeasureEvent) -> NoteDuration {
        if let notated = event.notated { return notated }
        if let exact = NoteDuration.exact(ticks: event.duration) { return exact }
        return NoteDuration.tiedChain(ticks: event.duration).first ?? NoteDuration(value: .thirtySecond)
    }
}

/// Stateful worker behind `NotationLayoutEngine`. Coordinates are produced per system with the treble top line
/// at y = 0 ("local" space) and translated into place once every system's vertical extent is known.
struct NotationEngraver {
    // MARK: Prepared data

    /// One chord note with its staff position and accidental decisions.
    struct PreparedNote {
        var chordNote: ChordNote
        var step: Int
        var displaced: Bool = false
        /// Head origin x relative to the column origin.
        var headX: CGFloat = 0
        var accidental: Accidental?
        /// Accidental glyph origin x relative to the column origin.
        var accidentalX: CGFloat = 0
    }

    /// One event with everything that does not depend on its horizontal position.
    struct PreparedEvent {
        var event: MeasureEvent
        var staff: Hand
        var duration: NoteDuration
        /// Low to high.
        var notes: [PreparedNote]
        var stemUp: Bool = false
        var hasStem: Bool
        var flags: Int
        var headCodepoint: UInt32
        var headWidth: CGFloat
        var isMeasureRest: Bool
        /// Staff step of a rest glyph origin.
        var restStep: Int = 4
        var columnIndex: Int = 0
        /// Extra x offset (second voice collisions).
        var shiftX: CGFloat = 0
        var beamGroup: Int?
        /// Room needed left / right of the column origin.
        var left: CGFloat = 0
        var right: CGFloat = 0

        var isRest: Bool { event.isRest }
    }

    /// One measure with its columns and natural widths.
    struct PreparedMeasure {
        var index: Int
        var measure: Measure
        var time: TimeSignature
        var key: KeySignature
        var previousKey: KeySignature
        var length: Ticks
        var notatedStart: Ticks
        var beatOffset: Ticks
        var showsTime: Bool
        var keyChanged: Bool
        var events: [PreparedEvent]
        /// Item indices per beam group, with the group's stem direction.
        var beamGroups: [(items: [Int], stemUp: Bool)]
        var columnTicks: [Ticks]
        var columnLeft: [CGFloat]
        var columnRight: [CGFloat]
        /// Natural distance from each column origin to the next (last: to the content end).
        var columnAdvance: [CGFloat]
        /// Staves that have no events at all in this measure (they get a whole-measure rest).
        var emptyStaves: [Hand]
        var multiVoiceStaves: Set<Hand>

        var flexibleWidth: CGFloat { columnAdvance.reduce(0, +) }
    }

    let score: Score
    let options: NotationLayoutOptions

    private var glyphs: [NotationGlyph] = []
    private var rects: [NotationRect] = []
    private var beams: [NotationBeam] = []
    private var ties: [NotationTie] = []
    private var texts: [NotationTextItem] = []
    private var events: [NotationEventLayout] = []
    private var beamGroupLayouts: [NotationBeamGroup] = []
    private var measureLayouts: [NotationMeasureLayout] = []

    init(score: Score, options: NotationLayoutOptions) {
        self.score = score
        self.options = options
    }

    // MARK: Constants

    private static let staffHeight: CGFloat = 4
    private static let grandStaffHeight: CGFloat = NotationEngraving.staffDistance + 4
    private static let clefWidth: CGFloat = 0.8 + 2.75 + 0.8
    private static let forwardRepeatWidth: CGFloat = 2.0
    private static let blackHeadWidth = NotationSMuFL.boundingBox(NotationSMuFL.noteheadBlack).width
    private static let stemThickness = NotationEngraving.stemThickness

    private func staffTop(_ staff: Hand) -> CGFloat { staff == .right ? 0 : NotationEngraving.staffDistance }
    private func y(step: Int, staff: Hand) -> CGFloat { staffTop(staff) + NotationStaffGeometry.yOffset(forStep: step) }

    // MARK: Run

    /// Performs preparation, system breaking, emission and vertical placement.
    mutating func run() -> NotationLayout {
        let prepared = prepareMeasures()
        let systemsOfMeasures = breakIntoSystems(prepared)
        var measureSystem = Array(repeating: 0, count: prepared.count)

        for (systemIndex, range) in systemsOfMeasures.enumerated() {
            let factor = stretchFactor(for: range, prepared: prepared, isLast: systemIndex == systemsOfMeasures.count - 1)
            var x = NotationEngraving.systemLeftInset
            for i in range {
                measureSystem[i] = systemIndex
                let nextOpensRepeat = i + 1 < range.upperBound && prepared[i + 1].measure.barline.repeatForward
                x = emitMeasure(prepared[i], startX: x, isFirstInSystem: i == range.lowerBound, isFirstSystem: systemIndex == 0,
                                systemIndex: systemIndex, factor: factor, omitsClosingBarline: nextOpensRepeat)
            }
            emitVoltas(range: range)
        }
        emitTies(systemsOfMeasures: systemsOfMeasures, measureSystem: measureSystem)
        return place(systemsOfMeasures: systemsOfMeasures, measureSystem: measureSystem)
    }

    // MARK: Preparation

    /// Builds the position-independent data for every measure.
    private func prepareMeasures() -> [PreparedMeasure] {
        var result: [PreparedMeasure] = []
        let starts = score.notatedMeasureStarts
        var previousTime = score.initialTime
        for (i, m) in score.measures.enumerated() {
            let time = score.timeSignature(atMeasure: i)
            let key = score.keySignature(atMeasure: i)
            let previousKey = i > 0 ? score.keySignature(atMeasure: i - 1) : key
            let length = score.measureLength(at: i)
            let showsTime = i == 0 || (m.timeSignature != nil && time != previousTime)
            previousTime = time
            let beatOffset = m.isPickup ? max(0, time.measureTicks - length) : 0

            var items = m.events.map { prepareEvent($0, in: m, length: length) }
            let multiVoice = Set(Hand.allCases.filter { staff in Set(items.filter { $0.staff == staff }.map { $0.event.voice }).count > 1 })
            let minVoice: [Hand: Int] = Dictionary(uniqueKeysWithValues: Hand.allCases.map { staff in
                (staff, items.filter { $0.staff == staff }.map { $0.event.voice }.min() ?? 1)
            })

            applyAccidentalMemory(&items, key: key)

            // Beam groups per hand+voice+staff chain.
            var groups: [(items: [Int], stemUp: Bool)] = []
            let chains = Dictionary(grouping: items.indices, by: { "\(items[$0].event.hand.rawValue)-\(items[$0].event.voice)-\(items[$0].staff.rawValue)" })
            for key in chains.keys.sorted() {
                guard let chain = chains[key]?.sorted(by: { items[$0].event.onset < items[$1].event.onset }) else { continue }
                let candidates = chain.map { idx in
                    NotationStaffGeometry.BeamCandidate(onset: items[idx].event.onset, duration: items[idx].event.duration,
                                                        flags: items[idx].hasStem ? items[idx].flags : 0, isRest: items[idx].isRest)
                }
                for g in NotationStaffGeometry.beamGroups(candidates, pulse: time.pulseTicks, beatOffset: beatOffset) {
                    let members = g.map { chain[$0] }
                    let staff = items[members[0]].staff
                    let up: Bool
                    if multiVoice.contains(staff) {
                        up = items[members[0]].event.voice == (minVoice[staff] ?? 1)
                    } else {
                        up = NotationStaffGeometry.stemUp(forSteps: members.flatMap { items[$0].notes.map { $0.step } })
                    }
                    for idx in members { items[idx].beamGroup = groups.count }
                    groups.append((members, up))
                }
            }

            // Stem directions, second displacement, accidental columns, extents.
            for idx in items.indices {
                let staff = items[idx].staff
                if let g = items[idx].beamGroup {
                    items[idx].stemUp = groups[g].stemUp
                } else if multiVoice.contains(staff) {
                    items[idx].stemUp = items[idx].event.voice == (minVoice[staff] ?? 1)
                } else {
                    items[idx].stemUp = NotationStaffGeometry.stemUp(forSteps: items[idx].notes.map { $0.step })
                }
                if items[idx].isRest {
                    var step = items[idx].isMeasureRest || items[idx].duration.value.rawValue <= NoteValue.whole.rawValue ? 2 : 4
                    if multiVoice.contains(staff) { step += items[idx].stemUp ? -4 : 4 }
                    items[idx].restStep = step
                }
                arrangeHeads(&items[idx])
            }

            resolveVoiceCollisions(&items, multiVoice: multiVoice)

            // Columns shared by both staves.
            var tickSet = Set(items.filter { !$0.isMeasureRest }.map { $0.event.onset })
            tickSet.insert(0)
            let columnTicks = tickSet.filter { $0 < max(1, length) || $0 == 0 }.sorted()
            var left = Array(repeating: CGFloat(0), count: columnTicks.count)
            var right = Array(repeating: Self.blackHeadWidth, count: columnTicks.count)
            for idx in items.indices {
                let c = columnTicks.lastIndex(where: { $0 <= items[idx].event.onset }) ?? 0
                items[idx].columnIndex = c
                guard !items[idx].isMeasureRest else { continue }
                left[c] = max(left[c], items[idx].left - items[idx].shiftX)
                right[c] = max(right[c], items[idx].right + items[idx].shiftX)
            }
            var advance: [CGFloat] = []
            for c in columnTicks.indices {
                let end = c + 1 < columnTicks.count ? columnTicks[c + 1] : max(length, columnTicks[c] + 1)
                let proportional = NotationStaffGeometry.proportionalWidth(ticks: end - columnTicks[c])
                let clearance = right[c] + (c + 1 < columnTicks.count ? left[c + 1] : 0) + 0.5
                advance.append(max(proportional, clearance))
            }

            let occupied = Set(items.map { $0.staff })
            result.append(PreparedMeasure(
                index: i, measure: m, time: time, key: key, previousKey: previousKey, length: length,
                notatedStart: starts.indices.contains(i) ? starts[i] : 0, beatOffset: beatOffset,
                showsTime: showsTime, keyChanged: i > 0 && key.fifths != previousKey.fifths,
                events: items, beamGroups: groups, columnTicks: columnTicks,
                columnLeft: left, columnRight: right, columnAdvance: advance,
                emptyStaves: Hand.allCases.filter { !occupied.contains($0) }, multiVoiceStaves: multiVoice))
        }
        return result
    }

    /// Position-independent preparation of one event.
    private func prepareEvent(_ e: MeasureEvent, in m: Measure, length: Ticks) -> PreparedEvent {
        let duration = NotationLayoutEngine.displayDuration(of: e)
        let staff = e.drawnStaff
        let notes = e.notes.map { PreparedNote(chordNote: $0, step: NotationStaffGeometry.staffStep(of: $0.pitch, on: staff)) }
        let sameVoice = m.events.filter { $0.hand == e.hand && $0.voice == e.voice }
        let isMeasureRest = e.isRest && !m.isPickup && sameVoice.count == 1 && e.onset == 0 && e.duration >= length
        let head = NotationSMuFL.notehead(for: duration.value)
        return PreparedEvent(
            event: e, staff: staff, duration: duration, notes: notes,
            hasStem: !e.isRest && duration.value.hasStem, flags: e.isRest ? 0 : duration.value.flags,
            headCodepoint: head, headWidth: NotationSMuFL.boundingBox(head).width, isMeasureRest: isMeasureRest)
    }

    /// Applies per-measure, per-staff accidental memory in onset order.
    private func applyAccidentalMemory(_ items: inout [PreparedEvent], key: KeySignature) {
        var memory: [Hand: NotationStaffGeometry.AccidentalMemory] = [.right: .init(key: key), .left: .init(key: key)]
        let order = items.indices.sorted { (items[$0].event.onset, items[$0].event.voice) < (items[$1].event.onset, items[$1].event.voice) }
        for idx in order {
            let staff = items[idx].staff
            for n in items[idx].notes.indices {
                let note = items[idx].notes[n].chordNote
                items[idx].notes[n].accidental = memory[staff]?.accidental(for: note.pitch, isTieContinuation: note.tieStop)
            }
        }
    }

    /// Second-interval displacement, accidental stacking and the horizontal extents of an event.
    private func arrangeHeads(_ item: inout PreparedEvent) {
        if item.isRest {
            let restGlyph = item.isMeasureRest ? NotationSMuFL.restWhole : NotationSMuFL.rest(for: item.duration.value)
            let width = NotationSMuFL.boundingBox(restGlyph).width
            item.left = 0
            item.right = width + (item.duration.dots > 0 ? 0.35 + CGFloat(item.duration.dots) * 0.5 : 0)
            return
        }
        let steps = item.notes.map { $0.step }
        let stemUpForDisplacement = item.hasStem ? item.stemUp : true
        let displaced = NotationStaffGeometry.displacedNotes(stepsLowToHigh: steps, stemUp: stemUpForDisplacement)
        let offset = item.headWidth - (item.hasStem ? Self.stemThickness : 0)
        for n in item.notes.indices {
            item.notes[n].displaced = displaced[n]
            item.notes[n].headX = displaced[n] ? (stemUpForDisplacement ? offset : -offset) : 0
        }
        let leftmostHead = item.notes.map { $0.headX }.min() ?? 0
        let rightmostHead = (item.notes.map { $0.headX }.max() ?? 0) + item.headWidth

        // Accidentals: stack top to bottom into columns, right-aligned per column.
        let withAccidental = item.notes.indices.filter { item.notes[$0].accidental != nil }.sorted { item.notes[$0].step < item.notes[$1].step }
        var minX = leftmostHead
        if !withAccidental.isEmpty {
            let columnOf = NotationStaffGeometry.accidentalColumns(stepsTopToBottom: withAccidental.map { item.notes[$0].step })
            let columnCount = (columnOf.max() ?? 0) + 1
            var widths = Array(repeating: CGFloat(0), count: columnCount)
            for (k, n) in withAccidental.enumerated() {
                if let acc = item.notes[n].accidental {
                    widths[columnOf[k]] = max(widths[columnOf[k]], NotationSMuFL.boundingBox(NotationSMuFL.accidental(acc)).width)
                }
            }
            var rightEdges: [CGFloat] = []
            var edge = leftmostHead - NotationEngraving.accidentalGap
            for c in 0..<columnCount {
                rightEdges.append(edge)
                edge -= widths[c] + NotationEngraving.accidentalColumnGap
            }
            for (k, n) in withAccidental.enumerated() {
                guard let acc = item.notes[n].accidental else { continue }
                let w = NotationSMuFL.boundingBox(NotationSMuFL.accidental(acc)).width
                item.notes[n].accidentalX = rightEdges[columnOf[k]] - w
                minX = min(minX, item.notes[n].accidentalX)
            }
        }
        var right = rightmostHead
        if item.duration.dots > 0 { right += 0.35 + CGFloat(item.duration.dots) * 0.5 }
        if item.hasStem, item.stemUp, item.flags > 0, item.beamGroup == nil {
            right = max(right, item.headWidth + NotationSMuFL.boundingBox(NotationSMuFL.flag8thUp).width)
        }
        item.left = max(0, -minX)
        item.right = right
    }

    /// Shifts the up-stem voice right when two voices on one staff meet at a second or unison in the same column.
    private func resolveVoiceCollisions(_ items: inout [PreparedEvent], multiVoice: Set<Hand>) {
        for staff in multiVoice {
            let onStaff = items.indices.filter { items[$0].staff == staff && !items[$0].isRest }
            let byOnset = Dictionary(grouping: onStaff, by: { items[$0].event.onset })
            for (_, group) in byOnset where group.count > 1 {
                let ups = group.filter { items[$0].stemUp }
                let downs = group.filter { !items[$0].stemUp }
                for u in ups {
                    let collides = downs.contains { d in
                        items[u].notes.contains { un in items[d].notes.contains { abs($0.step - un.step) <= 1 } }
                    }
                    if collides {
                        let width = downs.map { items[$0].headWidth }.max() ?? items[u].headWidth
                        items[u].shiftX = width
                    }
                }
            }
        }
    }

    // MARK: Prefix widths

    /// Width of a key signature (with cancellation naturals) in staff spaces.
    private func keySignatureWidth(_ m: PreparedMeasure, includeCancellation: Bool) -> CGFloat {
        let count = abs(m.key.fifths)
        let cancel = includeCancellation && m.keyChanged ? NotationStaffGeometry.cancellationSteps(from: m.previousKey, to: m.key, staff: .right).count : 0
        guard count + cancel > 0 else { return 0 }
        var w = CGFloat(cancel) * 0.95 + CGFloat(count) * (m.key.fifths > 0 ? 1.05 : 0.95)
        if cancel > 0 && count > 0 { w += 0.4 }
        return w + 0.8
    }

    /// Width of a time signature.
    private func timeSignatureWidth(_ t: TimeSignature) -> CGFloat {
        max(digitsWidth(t.beats), digitsWidth(t.beatType)) + 1.0
    }

    private func digits(_ n: Int) -> [Int] { String(max(0, n)).compactMap { $0.wholeNumberValue } }
    private func digitsWidth(_ n: Int) -> CGFloat { digits(n).reduce(0) { $0 + NotationSMuFL.timeSignatureDigitAdvance[$1] } }

    /// Fixed (non-stretchable) prefix width at the start of a measure.
    private func prefixWidth(_ m: PreparedMeasure, isFirstInSystem: Bool) -> CGFloat {
        var w: CGFloat = 0
        if isFirstInSystem {
            w += Self.clefWidth + keySignatureWidth(m, includeCancellation: true)
        } else if m.keyChanged {
            w += 0.6 + keySignatureWidth(m, includeCancellation: true)
        }
        if m.showsTime { w += timeSignatureWidth(m.time) + (isFirstInSystem || m.keyChanged ? 0 : 0.6) }
        if m.measure.barline.repeatForward { w += Self.forwardRepeatWidth }
        return w
    }

    /// Width taken by the closing barline.
    private func barlineWidth(_ b: Barline) -> CGFloat {
        if b.repeatBackwardTimes != nil { return 1.76 }
        if b.isFinal { return 1.06 }
        return NotationEngraving.thinBarlineThickness
    }

    private func fixedWidth(_ m: PreparedMeasure, isFirstInSystem: Bool) -> CGFloat {
        prefixWidth(m, isFirstInSystem: isFirstInSystem) + NotationEngraving.measureLeadingPadding + (m.columnLeft.first ?? 0)
            + NotationEngraving.measureTrailingPadding + barlineWidth(m.measure.barline)
    }

    // MARK: Systems

    /// Measure index ranges per system: everything in one system in scroll mode, greedy line breaking in page mode.
    private func breakIntoSystems(_ prepared: [PreparedMeasure]) -> [Range<Int>] {
        guard let pageWidth = options.pageWidthInStaffSpaces else { return [0..<prepared.count] }
        let available = pageWidth - NotationEngraving.systemLeftInset - NotationEngraving.systemRightInset
        var systems: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for i in prepared.indices {
            let w = fixedWidth(prepared[i], isFirstInSystem: i == start) + prepared[i].flexibleWidth
            if i > start && used + w > available {
                systems.append(start..<i)
                start = i
                used = fixedWidth(prepared[i], isFirstInSystem: true) + prepared[i].flexibleWidth
            } else {
                used += w
            }
        }
        systems.append(start..<prepared.count)
        return systems
    }

    /// Spacing multiplier of a system: the scroll factor, or page justification (the last system is only
    /// justified when it is already at least 75 % full).
    private func stretchFactor(for range: Range<Int>, prepared: [PreparedMeasure], isLast: Bool) -> CGFloat {
        guard let pageWidth = options.pageWidthInStaffSpaces else { return options.scrollSpacingFactor }
        let available = pageWidth - NotationEngraving.systemLeftInset - NotationEngraving.systemRightInset
        let fixed = range.reduce(CGFloat(0)) { $0 + fixedWidth(prepared[$1], isFirstInSystem: $1 == range.lowerBound) }
        let flex = range.reduce(CGFloat(0)) { $0 + prepared[$1].flexibleWidth }
        guard flex > 0 else { return 1 }
        let f = (available - fixed) / flex
        if isLast && (fixed + flex) / available < 0.75 { return min(1, max(0.5, f)) }
        return max(0.5, f)
    }

    // MARK: Emission

    private mutating func addGlyph(_ cp: UInt32, _ x: CGFloat, _ y: CGFloat, role: NotationGlyphRole, measure: Int, owner: NotationInkOwner = .score, scale: CGFloat = 1) {
        glyphs.append(NotationGlyph(codepoint: cp, origin: CGPoint(x: x, y: y), scale: scale, role: role, measureIndex: measure, owner: owner))
    }

    private mutating func addRect(_ r: CGRect, role: NotationRectRole, measure: Int, owner: NotationInkOwner = .score) {
        rects.append(NotationRect(rect: r, role: role, measureIndex: measure, owner: owner))
    }

    /// Emits one measure starting at `startX`; returns its right edge.
    /// `omitsClosingBarline` is set when the next measure in the system opens with a forward repeat sign, which
    /// then stands in for the plain barline.
    private mutating func emitMeasure(_ m: PreparedMeasure, startX: CGFloat, isFirstInSystem: Bool, isFirstSystem: Bool, systemIndex: Int, factor: CGFloat, omitsClosingBarline: Bool) -> CGFloat {
        let mi = m.index
        var x = startX

        // System start: connecting line, brace, clefs.
        if isFirstInSystem {
            addRect(CGRect(x: startX, y: 0, width: NotationEngraving.thinBarlineThickness, height: Self.grandStaffHeight), role: .systemLine, measure: mi)
            let braceScale = Self.grandStaffHeight / 4
            let braceWidth = NotationSMuFL.boundingBox(NotationSMuFL.brace).width * braceScale
            addGlyph(NotationSMuFL.brace, startX - 0.3 - braceWidth, Self.grandStaffHeight, role: .brace, measure: mi, scale: braceScale)
            addGlyph(NotationSMuFL.gClef, x + 0.8, staffTop(.right) + 3, role: .clef, measure: mi)
            addGlyph(NotationSMuFL.fClef, x + 0.8, staffTop(.left) + 1, role: .clef, measure: mi)
            x += Self.clefWidth
            x = emitKeySignature(m, at: x)
        } else if m.keyChanged {
            x = emitKeySignature(m, at: x + 0.6)
        }
        if m.showsTime {
            if !isFirstInSystem && !m.keyChanged { x += 0.6 }
            x = emitTimeSignature(m.time, at: x, measure: mi)
        }
        if m.measure.barline.repeatForward {
            let thickX = x == startX ? x - NotationEngraving.thinBarlineThickness : x + 0.2
            addRect(CGRect(x: thickX, y: 0, width: NotationEngraving.thickBarlineThickness, height: Self.grandStaffHeight), role: .thickBarline, measure: mi)
            let thinX = thickX + NotationEngraving.thickBarlineThickness + NotationEngraving.barlineSeparation
            addRect(CGRect(x: thinX, y: 0, width: NotationEngraving.thinBarlineThickness, height: Self.grandStaffHeight), role: .barline, measure: mi)
            emitRepeatDots(at: thinX + NotationEngraving.thinBarlineThickness + 0.3, measure: mi)
            x += Self.forwardRepeatWidth
        }
        let contentStart = x

        // Columns.
        var columnX: [CGFloat] = []
        var cx = contentStart + NotationEngraving.measureLeadingPadding + (m.columnLeft.first ?? 0)
        for c in m.columnTicks.indices {
            columnX.append(cx)
            cx += m.columnAdvance[c] * factor
        }
        let contentEnd = cx
        let endX = contentEnd + NotationEngraving.measureTrailingPadding + barlineWidth(m.measure.barline)

        // Staff lines over the whole measure.
        for staff in Hand.allCases {
            for line in 0..<5 {
                let ly = staffTop(staff) + CGFloat(line) - NotationEngraving.staffLineThickness / 2
                addRect(CGRect(x: startX, y: ly, width: endX - startX, height: NotationEngraving.staffLineThickness), role: .staffLine, measure: mi)
            }
        }
        if !(omitsClosingBarline && m.measure.barline == .plain) {
            emitClosingBarline(m.measure.barline, endX: endX, measure: mi)
        }

        // Whole-measure rests for empty staves.
        let restCentreX = (contentStart + NotationEngraving.measureLeadingPadding + contentEnd) / 2
        let wholeRestWidth = NotationSMuFL.boundingBox(NotationSMuFL.restWhole).width
        for staff in m.emptyStaves {
            addGlyph(NotationSMuFL.restWhole, restCentreX - wholeRestWidth / 2, y(step: 2, staff: staff), role: .measureRest, measure: mi)
        }

        // Events: heads first (stems need beam geometry).
        let firstEventIndex = events.count
        var layouts: [NotationEventLayout] = []
        for item in m.events {
            layouts.append(eventLayout(item, columnX: columnX, restCentreX: restCentreX, measure: mi))
        }
        // Beams decide the tips of their stems.
        var tips: [Int: CGFloat] = [:]
        for (g, group) in m.beamGroups.enumerated() {
            let groupTips = emitBeams(group: group, items: m.events, layouts: layouts, measure: mi)
            for (k, idx) in group.items.enumerated() { tips[idx] = groupTips[k] }
            let ids = group.items.map { m.events[$0].event.id }
            let globalIndex = beamGroupLayouts.count
            beamGroupLayouts.append(NotationBeamGroup(measureIndex: mi, hand: m.events[group.items[0]].event.hand, voice: m.events[group.items[0]].event.voice, eventIDs: ids, stemUp: group.stemUp))
            for idx in group.items { layouts[idx].beamGroup = globalIndex }
            _ = g
        }
        for (idx, item) in m.events.enumerated() {
            emitEventInk(item, layout: &layouts[idx], beamTip: tips[idx], restCentreX: restCentreX, measure: mi)
        }
        emitTuplets(m, layouts: layouts, measure: mi)
        events.append(contentsOf: layouts)

        // Measure number, lifted above any notes, stems or beams at the start of the measure.
        if options.showsMeasureNumbers && m.measure.number > 0 {
            let isPage = options.pageWidthInStaffSpaces != nil
            let show = isPage ? (isFirstInSystem && !(isFirstSystem && m.measure.number <= 1)) : !(mi == 0 && m.measure.number <= 1)
            if show {
                let label = "\(m.measure.number)"
                let span = (startX - 0.2)...(startX + 0.4 + CGFloat(label.count) * 0.9)
                var top: CGFloat = -1.0
                for l in layouts where !l.bounds.isNull && l.bounds.maxX >= span.lowerBound && l.bounds.minX <= span.upperBound {
                    top = min(top, l.bounds.minY)
                }
                for b in beams where b.measureIndex == mi && max(b.start.x, b.end.x) >= span.lowerBound && min(b.start.x, b.end.x) <= span.upperBound {
                    top = min(top, b.start.y, b.end.y, b.start.y + b.thickness, b.end.y + b.thickness)
                }
                texts.append(NotationTextItem(string: label, origin: CGPoint(x: startX + 0.2, y: top - 0.5), fontSize: 1.4, role: .measureNumber, measureIndex: mi))
            }
        }

        measureLayouts.append(NotationMeasureLayout(
            index: mi, number: m.measure.number, systemIndex: systemIndex,
            frame: CGRect(x: startX, y: 0, width: endX - startX, height: Self.grandStaffHeight),
            contentStartX: contentStart, contentEndX: contentEnd,
            columns: zip(m.columnTicks, columnX).map { NotationColumn(tick: $0.0, x: $0.1) },
            length: m.length, notatedStart: m.notatedStart, timeSignature: m.time, keySignature: m.key,
            eventIndices: firstEventIndex..<events.count))
        return endX
    }

    /// Emits cancellation naturals and the key signature on both staves; returns the x after it.
    private mutating func emitKeySignature(_ m: PreparedMeasure, at startX: CGFloat) -> CGFloat {
        let width = keySignatureWidth(m, includeCancellation: true)
        guard width > 0 else { return startX }
        for staff in Hand.allCases {
            var x = startX
            if m.keyChanged {
                for step in NotationStaffGeometry.cancellationSteps(from: m.previousKey, to: m.key, staff: staff) {
                    addGlyph(NotationSMuFL.accidentalNatural, x, y(step: step, staff: staff), role: .keyCancellation, measure: m.index)
                    x += 0.95
                }
                if x > startX && m.key.fifths != 0 { x += 0.4 }
            }
            let glyph = m.key.fifths > 0 ? NotationSMuFL.accidentalSharp : NotationSMuFL.accidentalFlat
            for step in NotationStaffGeometry.keySignatureSteps(fifths: m.key.fifths, staff: staff) {
                addGlyph(glyph, x, y(step: step, staff: staff), role: .keySignature, measure: m.index)
                x += m.key.fifths > 0 ? 1.05 : 0.95
            }
        }
        return startX + width
    }

    /// Emits a time signature on both staves; returns the x after it.
    private mutating func emitTimeSignature(_ t: TimeSignature, at startX: CGFloat, measure: Int) -> CGFloat {
        let width = timeSignatureWidth(t)
        let inner = width - 1.0
        for staff in Hand.allCases {
            for (value, step) in [(t.beats, 2), (t.beatType, 6)] {
                var x = startX + (inner - digitsWidth(value)) / 2
                for d in digits(value) {
                    addGlyph(NotationSMuFL.timeSignatureDigit(d), x, y(step: step, staff: staff), role: .timeSignature, measure: measure)
                    x += NotationSMuFL.timeSignatureDigitAdvance[d]
                }
            }
        }
        return startX + width
    }

    /// Repeat dots in the two middle spaces of both staves.
    private mutating func emitRepeatDots(at x: CGFloat, measure: Int) {
        for staff in Hand.allCases {
            for step in [3, 5] {
                addGlyph(NotationSMuFL.repeatDot, x, y(step: step, staff: staff), role: .repeatDot, measure: measure)
            }
        }
    }

    /// Plain, final or backward-repeat barline ending at `endX`.
    private mutating func emitClosingBarline(_ b: Barline, endX: CGFloat, measure: Int) {
        let h = Self.grandStaffHeight
        let thin = NotationEngraving.thinBarlineThickness
        let thick = NotationEngraving.thickBarlineThickness
        if b.isFinal || b.repeatBackwardTimes != nil {
            let thickX = endX - thick
            let thinX = thickX - NotationEngraving.barlineSeparation - thin
            addRect(CGRect(x: thinX, y: 0, width: thin, height: h), role: .barline, measure: measure)
            addRect(CGRect(x: thickX, y: 0, width: thick, height: h), role: .thickBarline, measure: measure)
            if b.repeatBackwardTimes != nil {
                emitRepeatDots(at: thinX - 0.3 - NotationSMuFL.boundingBox(NotationSMuFL.repeatDot).width, measure: measure)
            }
        } else {
            addRect(CGRect(x: endX - thin, y: 0, width: thin, height: h), role: .barline, measure: measure)
        }
    }

    /// Head positions of an event (no ink yet).
    private func eventLayout(_ item: PreparedEvent, columnX: [CGFloat], restCentreX: CGFloat, measure: Int) -> NotationEventLayout {
        let x = (columnX.indices.contains(item.columnIndex) ? columnX[item.columnIndex] : (columnX.first ?? 0)) + item.shiftX
        let heads = item.notes.map { n in
            NotationNoteheadLayout(midi: n.chordNote.midi, pitch: n.chordNote.pitch,
                                   origin: CGPoint(x: x + n.headX, y: y(step: n.step, staff: item.staff)),
                                   staffStep: n.step, isDisplaced: n.displaced, accidental: n.accidental,
                                   fingering: Self.isDrawableFinger(n.chordNote.fingering) ? n.chordNote.fingering : nil, tieStart: n.chordNote.tieStart, tieStop: n.chordNote.tieStop)
        }
        return NotationEventLayout(id: item.event.id, measureIndex: measure, hand: item.event.hand, staff: item.staff,
                                   voice: item.event.voice, onset: item.event.onset, duration: item.event.duration,
                                   isRest: item.isRest, value: item.duration.value, dots: item.duration.dots,
                                   columnIndex: item.columnIndex, x: item.isMeasureRest ? restCentreX : x,
                                   noteheads: heads, stemUp: item.hasStem ? item.stemUp : nil, stem: nil, beamGroup: nil,
                                   bounds: .null)
    }

    /// Natural stem tip y of an event (before beaming).
    private func naturalTip(_ item: PreparedEvent, layout: NotationEventLayout, length: CGFloat) -> CGFloat {
        let ys = layout.noteheads.map { $0.origin.y }
        let middle = staffTop(item.staff) + 2
        if item.stemUp {
            return min((ys.min() ?? middle) - length, middle)
        }
        return max((ys.max() ?? middle) + length, middle)
    }

    /// Stem centre x of an event.
    private func stemCentreX(_ item: PreparedEvent, layout: NotationEventLayout) -> CGFloat {
        item.stemUp ? layout.x + NotationSMuFL.stemUpSE.x - Self.stemThickness / 2 : layout.x + NotationSMuFL.stemDownNW.x + Self.stemThickness / 2
    }

    /// Emits the beams of one group; returns the stem tip y for each member.
    private mutating func emitBeams(group: (items: [Int], stemUp: Bool), items: [PreparedEvent], layouts: [NotationEventLayout], measure: Int) -> [CGFloat] {
        let members = group.items
        let maxFlags = members.map { items[$0].flags }.max() ?? 1
        let length = NotationEngraving.stemLength + CGFloat(max(0, maxFlags - 2)) * 0.75
        let natural = members.map { CGPoint(x: stemCentreX(items[$0], layout: layouts[$0]), y: naturalTip(items[$0], layout: layouts[$0], length: length)) }
        let staff = items[members[0]].staff
        let line = NotationStaffGeometry.beamLine(tips: natural, stemUp: group.stemUp, middleLineY: staffTop(staff) + 2)
        func lineY(_ x: CGFloat) -> CGFloat { line.a + line.b * x }
        let half = Self.stemThickness / 2
        let thickness = group.stemUp ? NotationEngraving.beamThickness : -NotationEngraving.beamThickness
        let step = (NotationEngraving.beamThickness + NotationEngraving.beamSpacing) * (group.stemUp ? 1 : -1)
        let hand = items[members[0]].event.hand
        let ids = members.map { items[$0].event.id }

        for level in 1...max(1, maxFlags) {
            let dy = CGFloat(level - 1) * step
            var k = 0
            while k < members.count {
                guard items[members[k]].flags >= level else { k += 1; continue }
                var end = k
                while end + 1 < members.count && items[members[end + 1]].flags >= level { end += 1 }
                let x1: CGFloat
                let x2: CGFloat
                if end > k || level == 1 {
                    x1 = natural[k].x - half
                    x2 = natural[end].x + half
                } else if k == 0 {
                    x1 = natural[k].x - half
                    x2 = natural[k].x + 1.1
                } else {
                    x1 = natural[k].x - 1.1
                    x2 = natural[k].x + half
                }
                beams.append(NotationBeam(start: CGPoint(x: x1, y: lineY(x1) + dy), end: CGPoint(x: x2, y: lineY(x2) + dy),
                                          thickness: thickness, level: level, measureIndex: measure, hand: hand, eventIDs: ids))
                k = end + 1
            }
        }
        return natural.map { lineY($0.x) }
    }

    /// Emits heads, accidentals, ledger lines, stem, flag, dots, fingering (or the rest glyph) of one event.
    private mutating func emitEventInk(_ item: PreparedEvent, layout: inout NotationEventLayout, beamTip: CGFloat?, restCentreX: CGFloat, measure: Int) {
        let owner = NotationInkOwner.event(item.event.id, item.event.hand)
        let firstGlyph = glyphs.count
        let firstRect = rects.count
        let top = staffTop(item.staff)

        if item.isRest {
            if item.isMeasureRest {
                let w = NotationSMuFL.boundingBox(NotationSMuFL.restWhole).width
                addGlyph(NotationSMuFL.restWhole, restCentreX - w / 2, top + CGFloat(item.restStep) / 2, role: .measureRest, measure: measure, owner: owner)
            } else {
                let glyph = NotationSMuFL.rest(for: item.duration.value)
                let bb = NotationSMuFL.boundingBox(glyph)
                let rx = layout.x + (Self.blackHeadWidth - bb.width) / 2
                addGlyph(glyph, rx, top + CGFloat(item.restStep) / 2, role: .rest, measure: measure, owner: owner)
                let dotStep = item.restStep % 2 == 0 ? item.restStep - 1 : item.restStep
                for d in 0..<item.duration.dots {
                    addGlyph(NotationSMuFL.augmentationDot, rx + bb.width + 0.3 + CGFloat(d) * 0.5, top + CGFloat(dotStep) / 2, role: .augmentationDot, measure: measure, owner: owner)
                }
            }
            layout.bounds = inkBounds(glyphs: firstGlyph, rects: firstRect)
            return
        }

        // Heads and accidentals.
        for (n, head) in layout.noteheads.enumerated() {
            addGlyph(item.headCodepoint, head.origin.x, head.origin.y, role: .notehead, measure: measure, owner: owner)
            if let acc = item.notes[n].accidental {
                addGlyph(NotationSMuFL.accidental(acc), layout.x + item.notes[n].accidentalX, head.origin.y, role: .accidental, measure: measure, owner: owner)
            }
        }

        // Ledger lines spanning all heads of the event.
        let headLeft = (layout.noteheads.map { $0.origin.x }.min() ?? layout.x) - NotationEngraving.legerLineExtension
        let headRight = (layout.noteheads.map { $0.origin.x }.max() ?? layout.x) + item.headWidth + NotationEngraving.legerLineExtension
        let steps = layout.noteheads.map { $0.staffStep }
        var ledgerSet = Set<Int>()
        if let highest = steps.min() { ledgerSet.formUnion(NotationStaffGeometry.ledgerSteps(for: highest)) }
        if let lowest = steps.max() { ledgerSet.formUnion(NotationStaffGeometry.ledgerSteps(for: lowest)) }
        for s in ledgerSet.sorted() {
            let ly = top + CGFloat(s) / 2 - NotationEngraving.legerLineThickness / 2
            addRect(CGRect(x: headLeft, y: ly, width: headRight - headLeft, height: NotationEngraving.legerLineThickness), role: .ledgerLine, measure: measure, owner: owner)
        }

        // Stem and flag.
        var tipY: CGFloat?
        if item.hasStem {
            let flagExtra = item.beamGroup == nil && item.flags >= 2 ? CGFloat(item.flags - 1) * 0.5 : 0
            let tip = beamTip ?? naturalTip(item, layout: layout, length: NotationEngraving.stemLength + flagExtra)
            let ys = layout.noteheads.map { $0.origin.y }
            let stemLeft = item.stemUp ? layout.x + NotationSMuFL.stemUpSE.x - Self.stemThickness : layout.x + NotationSMuFL.stemDownNW.x
            let base = item.stemUp ? (ys.max() ?? tip) - NotationSMuFL.stemUpSE.y : (ys.min() ?? tip) - NotationSMuFL.stemDownNW.y
            let stemRect = CGRect(x: stemLeft, y: min(tip, base), width: Self.stemThickness, height: abs(base - tip))
            addRect(stemRect, role: .stem, measure: measure, owner: owner)
            layout.stem = stemRect
            tipY = tip
            if beamTip == nil, let flag = NotationSMuFL.flag(count: item.flags, stemUp: item.stemUp) {
                let anchor = NotationSMuFL.flagStemAnchor(count: item.flags, stemUp: item.stemUp)
                addGlyph(flag, stemLeft - anchor.x, tip + anchor.y, role: .flag, measure: measure, owner: owner)
            }
        }

        // Augmentation dots, one row per distinct line/space.
        if item.duration.dots > 0 {
            let rightmost = (layout.noteheads.map { $0.origin.x }.max() ?? layout.x) + item.headWidth
            let multi = item.event.voice > 1 && !item.stemUp
            var dotSteps = Set<Int>()
            for s in steps { dotSteps.insert(NotationStaffGeometry.isOnLine(s) ? (multi ? s + 1 : s - 1) : s) }
            for s in dotSteps.sorted() {
                for d in 0..<item.duration.dots {
                    addGlyph(NotationSMuFL.augmentationDot, rightmost + 0.35 + CGFloat(d) * 0.5, top + CGFloat(s) / 2, role: .augmentationDot, measure: measure, owner: owner)
                }
            }
        }

        // Fingering: above for the right hand, below for the left hand; owned by the hand, not the event.
        if options.showsFingering {
            emitFingering(item, layout: layout, tipY: tipY, measure: measure)
        }
        layout.bounds = inkBounds(glyphs: firstGlyph, rects: firstRect)
    }

    /// Fingering digits stacked away from the notes. Only fingers 1...5 are drawn: `ChordNote.fingering` can hold any
    /// integer when set directly or decoded from JSON, and the glyph tables only cover the SMuFL digits 0...5.
    private mutating func emitFingering(_ item: PreparedEvent, layout: NotationEventLayout, tipY: CGFloat?, measure: Int) {
        let fingered = layout.noteheads.filter { Self.isDrawableFinger($0.fingering) }
        guard !fingered.isEmpty else { return }
        let ys = layout.noteheads.map { $0.origin.y }
        let centreX = layout.x + item.headWidth / 2
        let above = item.event.hand == .right
        if above {
            var anchor = (ys.min() ?? 0) - 0.7
            if item.hasStem && item.stemUp, let tipY { anchor = min(anchor, tipY - 0.3) }
            // Highest note's finger on top.
            for (k, head) in fingered.sorted(by: { $0.origin.y > $1.origin.y }).enumerated() {
                guard let f = head.fingering, Self.isDrawableFinger(f) else { continue }
                let w = NotationSMuFL.fingeringAdvance[f]
                addGlyph(NotationSMuFL.fingering(f), centreX - w / 2, anchor - CGFloat(k) * 1.1, role: .fingering, measure: measure, owner: .hand(item.event.hand))
            }
        } else {
            var anchor = (ys.max() ?? 0) + 0.7 + 1.0
            if item.hasStem && !item.stemUp, let tipY { anchor = max(anchor, tipY + 0.3 + 1.0) }
            for (k, head) in fingered.sorted(by: { $0.origin.y < $1.origin.y }).enumerated() {
                guard let f = head.fingering, Self.isDrawableFinger(f) else { continue }
                let w = NotationSMuFL.fingeringAdvance[f]
                addGlyph(NotationSMuFL.fingering(f), centreX - w / 2, anchor + CGFloat(k) * 1.1, role: .fingering, measure: measure, owner: .hand(item.event.hand))
            }
        }
    }

    /// Whether a fingering value is a real piano finger (1...5) that has a glyph.
    static func isDrawableFinger(_ finger: Int?) -> Bool {
        guard let finger else { return false }
        return (1...5).contains(finger)
    }

    /// Union of the glyph and rect frames appended since the given indices.
    private func inkBounds(glyphs firstGlyph: Int, rects firstRect: Int) -> CGRect {
        var r = CGRect.null
        for g in glyphs[firstGlyph...] { r = r.union(g.frame) }
        for rect in rects[firstRect...] { r = r.union(rect.rect) }
        return r
    }

    /// Tuplet numbers over runs of tuplet events in one voice.
    private mutating func emitTuplets(_ m: PreparedMeasure, layouts: [NotationEventLayout], measure: Int) {
        let chains = Dictionary(grouping: m.events.indices, by: { "\(m.events[$0].event.hand.rawValue)-\(m.events[$0].event.voice)" })
        for key in chains.keys.sorted() {
            guard let chain = chains[key]?.sorted(by: { m.events[$0].event.onset < m.events[$1].event.onset }) else { continue }
            var group: [Int] = []
            var accumulated: Ticks = 0
            var target: Ticks = 0
            var current: Tuplet?
            func close(_ engraver: inout NotationEngraver) {
                if let t = current, !group.isEmpty { engraver.emitTupletNumber(t, members: group, items: m.events, layouts: layouts, measure: measure) }
                group = []; accumulated = 0; current = nil
            }
            for idx in chain {
                let item = m.events[idx]
                guard let t = item.duration.tuplet else { close(&self); continue }
                if let c = current, let last = group.last {
                    let contiguous = m.events[last].event.end == item.event.onset
                    if c != t || !contiguous { close(&self) }
                }
                if current == nil {
                    current = t
                    target = t.normal * item.duration.value.ticks
                }
                group.append(idx)
                accumulated += item.duration.ticks
                if accumulated >= target { close(&self) }
            }
            close(&self)
        }
    }

    /// Places the digits of a tuplet number above (stems up / rests) or below (stems down) the group.
    private mutating func emitTupletNumber(_ t: Tuplet, members: [Int], items: [PreparedEvent], layouts: [NotationEventLayout], measure: Int) {
        guard let first = members.first, let last = members.last else { return }
        let ups = members.filter { items[$0].isRest || items[$0].stemUp }.count
        let above = ups * 2 >= members.count
        let scale: CGFloat = 0.85
        let digitList = digits(t.actual)
        let digitWidth: [CGFloat] = digitList.map { NotationSMuFL.boundingBox(NotationSMuFL.tupletDigit($0)).width * scale }
        let total = digitWidth.reduce(0, +)
        let centre = (layouts[first].x + layouts[last].x + Self.blackHeadWidth) / 2
        let extents = members.map { layouts[$0].bounds }.filter { !$0.isNull }
        // Include beams of these events.
        let ids = Set(members.map { items[$0].event.id })
        let beamYs = beams.filter { !ids.isDisjoint(with: $0.eventIDs) }.flatMap { [$0.start.y, $0.end.y, $0.start.y + $0.thickness, $0.end.y + $0.thickness] }
        let minY = min(extents.map { $0.minY }.min() ?? 0, beamYs.min() ?? .greatestFiniteMagnitude)
        let maxY = max(extents.map { $0.maxY }.max() ?? 0, beamYs.max() ?? -.greatestFiniteMagnitude)
        let baseline = above ? minY - 0.4 : maxY + 0.4 + 1.5 * scale
        var x = centre - total / 2
        let hand = items[first].event.hand
        for (k, d) in digitList.enumerated() {
            addGlyph(NotationSMuFL.tupletDigit(d), x, baseline, role: .tupletNumber, measure: measure, owner: .hand(hand), scale: scale)
            x += digitWidth[k]
        }
    }

    /// Volta brackets over runs of measures with the same ending numbers within one system.
    private mutating func emitVoltas(range: Range<Int>) {
        var i = range.lowerBound
        while i < range.upperBound {
            let endings = score.measures[i].barline.endings
            guard !endings.isEmpty, measureLayouts.indices.contains(i) else { i += 1; continue }
            var j = i
            while j + 1 < range.upperBound && score.measures[j + 1].barline.endings == endings && !score.measures[j + 1].barline.repeatForward { j += 1 }
            let x1 = measureLayouts[i].frame.minX + 0.3
            let x2 = measureLayouts[j].frame.maxX - 0.5
            let lineY = min(-4.5, contentTop(measures: i...j) - 2.9)
            let t = NotationEngraving.repeatEndingLineThickness
            addRect(CGRect(x: x1, y: lineY, width: x2 - x1, height: t), role: .voltaLine, measure: i)
            addRect(CGRect(x: x1, y: lineY, width: t, height: 2.0), role: .voltaLine, measure: i)
            if score.measures[j].barline.repeatBackwardTimes != nil {
                addRect(CGRect(x: x2 - t, y: lineY, width: t, height: 2.0), role: .voltaLine, measure: j)
            }
            let label = endings.map(String.init).joined(separator: ", ") + "."
            texts.append(NotationTextItem(string: label, origin: CGPoint(x: x1 + 0.4, y: lineY + 1.6), fontSize: 1.3, role: .volta, measureIndex: i))
            i = j + 1
        }
    }

    /// Highest point (smallest y) of the ink already emitted for a run of measures, including measure numbers.
    private func contentTop(measures: ClosedRange<Int>) -> CGFloat {
        var top: CGFloat = 0
        for g in glyphs where measures.contains(g.measureIndex) { top = min(top, g.frame.minY) }
        for r in rects where measures.contains(r.measureIndex) && r.role != .voltaLine { top = min(top, r.rect.minY) }
        for b in beams where measures.contains(b.measureIndex) { top = min(top, b.start.y, b.end.y, b.start.y + b.thickness, b.end.y + b.thickness) }
        for t in texts where measures.contains(t.measureIndex) && t.role == .measureNumber { top = min(top, t.origin.y - t.fontSize) }
        return top
    }

    // MARK: Ties

    /// Connects every tie start to the next event of the same hand and voice that contains the same pitch;
    /// ties crossing a system break are split into two half arcs.
    private mutating func emitTies(systemsOfMeasures: [Range<Int>], measureSystem: [Int]) {
        // Event indices per (hand, voice) in notated order.
        var chains: [String: [Int]] = [:]
        for (idx, e) in events.enumerated() where !e.isRest {
            chains["\(e.hand.rawValue)-\(e.voice)", default: []].append(idx)
        }
        for (_, chain) in chains {
            for (k, idx) in chain.enumerated() {
                let e = events[idx]
                let next = k + 1 < chain.count ? events[chain[k + 1]] : nil
                let headWidth = NotationSMuFL.noteheadWidth(for: e.value)
                let count = e.noteheads.count
                for (n, head) in e.noteheads.enumerated() where head.tieStart {
                    // Single notes tie on the side opposite the stem; chords split outer halves up/down.
                    let stemUp = e.stemUp ?? (head.staffStep > NotationStaffGeometry.middleStep)
                    let mid = Double(count - 1) / 2
                    let above: Bool
                    if count == 1 || Double(n) == mid {
                        above = !stemUp
                    } else {
                        above = Double(n) > mid
                    }
                    let dy: CGFloat = above ? -0.55 : 0.55
                    let dotRoom: CGFloat = e.dots > 0 ? 0.35 + CGFloat(e.dots) * 0.5 : 0
                    let start = CGPoint(x: head.origin.x + headWidth + 0.12 + dotRoom, y: head.origin.y + dy)
                    let isRealNext = next.map { $0.measureIndex == e.measureIndex || $0.measureIndex == e.measureIndex + 1 } ?? false
                    if let next, isRealNext, let target = next.noteheads.first(where: { $0.midi == head.midi }) {
                        let end = CGPoint(x: target.origin.x - 0.12, y: target.origin.y + dy)
                        let fromSystem = measureSystem[e.measureIndex]
                        let toSystem = measureSystem[next.measureIndex]
                        if fromSystem == toSystem {
                            ties.append(NotationTie(start: start, end: end, above: above, measureIndex: e.measureIndex, hand: e.hand, fromEventID: e.id, toEventID: next.id, midi: head.midi))
                        } else {
                            let systemEnd = measureLayouts[systemsOfMeasures[fromSystem].upperBound - 1].frame.maxX
                            ties.append(NotationTie(start: start, end: CGPoint(x: max(start.x + 1, systemEnd + 0.3), y: start.y), above: above, measureIndex: e.measureIndex, hand: e.hand, fromEventID: e.id, toEventID: next.id, midi: head.midi))
                            let firstX = measureLayouts[next.measureIndex].contentStartX
                            ties.append(NotationTie(start: CGPoint(x: min(end.x - 1, firstX - 0.2), y: end.y), end: end, above: above, measureIndex: next.measureIndex, hand: e.hand, fromEventID: e.id, toEventID: next.id, midi: head.midi))
                        }
                    } else {
                        ties.append(NotationTie(start: start, end: CGPoint(x: start.x + 2.0, y: start.y), above: above, measureIndex: e.measureIndex, hand: e.hand, fromEventID: e.id, toEventID: nil, midi: head.midi))
                    }
                }
            }
        }
        ties.sort { ($0.measureIndex, $0.start.x, $0.start.y) < ($1.measureIndex, $1.start.x, $1.start.y) }
    }

    // MARK: Vertical placement

    /// Computes each system's vertical extent, stacks the systems and translates every element into place.
    private mutating func place(systemsOfMeasures: [Range<Int>], measureSystem: [Int]) -> NotationLayout {
        let systemCount = systemsOfMeasures.count
        var minY = Array(repeating: CGFloat(0), count: systemCount)
        var maxY = Array(repeating: Self.grandStaffHeight, count: systemCount)
        func include(_ r: CGRect, measure: Int) {
            guard !r.isNull, measureSystem.indices.contains(measure) else { return }
            let s = measureSystem[measure]
            minY[s] = min(minY[s], r.minY)
            maxY[s] = max(maxY[s], r.maxY)
        }
        for g in glyphs { include(g.frame, measure: g.measureIndex) }
        for r in rects { include(r.rect, measure: r.measureIndex) }
        for b in beams {
            include(CGRect(x: b.start.x, y: min(b.start.y, b.end.y, b.start.y + b.thickness, b.end.y + b.thickness), width: 0.1, height: abs(b.end.y - b.start.y) + abs(b.thickness)), measure: b.measureIndex)
        }
        for t in ties { include(CGRect(x: t.start.x, y: min(t.start.y, t.end.y) - 1, width: 0.1, height: abs(t.end.y - t.start.y) + 2), measure: t.measureIndex) }
        for t in texts { include(CGRect(x: t.origin.x, y: t.origin.y - t.fontSize, width: 0.1, height: t.fontSize), measure: t.measureIndex) }

        let isPage = options.pageWidthInStaffSpaces != nil
        let contentWidth: CGFloat
        if let pageWidth = options.pageWidthInStaffSpaces {
            contentWidth = pageWidth
        } else {
            contentWidth = (measureLayouts.last?.frame.maxX ?? 0) + NotationEngraving.systemRightInset
        }

        var systems: [NotationSystemLayout] = []
        var offsets: [CGFloat] = []
        var yCursor: CGFloat = 0
        for (s, range) in systemsOfMeasures.enumerated() {
            let topPadding = max(4.0, -minY[s] + 0.8)
            let bottomPadding = max(3.5, maxY[s] - Self.grandStaffHeight + 0.8) + (isPage && s < systemCount - 1 ? NotationEngraving.systemSpacing : 0)
            let trebleTop = yCursor + topPadding
            let height = topPadding + Self.grandStaffHeight + bottomPadding
            systems.append(NotationSystemLayout(index: s, frame: CGRect(x: 0, y: yCursor, width: contentWidth, height: height),
                                                trebleTop: trebleTop, bassTop: trebleTop + NotationEngraving.staffDistance, measureIndices: range))
            offsets.append(trebleTop)
            yCursor += height
        }

        func dy(_ measure: Int) -> CGFloat { measureSystem.indices.contains(measure) ? offsets[measureSystem[measure]] : 0 }
        for i in glyphs.indices { glyphs[i].origin.y += dy(glyphs[i].measureIndex) }
        for i in rects.indices { rects[i].rect.origin.y += dy(rects[i].measureIndex) }
        for i in beams.indices {
            let d = dy(beams[i].measureIndex)
            beams[i].start.y += d
            beams[i].end.y += d
        }
        for i in ties.indices {
            let d = dy(ties[i].measureIndex)
            ties[i].start.y += d
            ties[i].end.y += d
        }
        for i in texts.indices { texts[i].origin.y += dy(texts[i].measureIndex) }
        for i in measureLayouts.indices { measureLayouts[i].frame.origin.y += dy(i) }
        for i in events.indices {
            let d = dy(events[i].measureIndex)
            for h in events[i].noteheads.indices { events[i].noteheads[h].origin.y += d }
            events[i].stem = events[i].stem.map { $0.offsetBy(dx: 0, dy: d) }
            if !events[i].bounds.isNull { events[i].bounds = events[i].bounds.offsetBy(dx: 0, dy: d) }
        }

        var index: [UUID: Int] = [:]
        for (i, e) in events.enumerated() { index[e.id] = i }
        return NotationLayout(options: options, size: CGSize(width: contentWidth, height: yCursor), systems: systems,
                              measures: measureLayouts, events: events, beamGroups: beamGroupLayouts, glyphs: glyphs,
                              rects: rects, beams: beams, ties: ties, texts: texts, eventIndexByID: index)
    }
}
