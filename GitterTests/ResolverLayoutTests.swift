import Foundation
import GitCore
import Testing

@testable import Gitter

/// Ours | Result | Theirs aligned into rows: grey fillers, tints, word marks, badges, the waiting
/// slot and the base strip. The main fixture is the mockup's `units.py` (Figma frame 4:2), its
/// segments as `git merge-file --diff3 --diff-algorithm=histogram` writes them.
@Suite struct ResolverLayoutTests {

    // MARK: - Fixtures

    static func common(_ text: String) -> ConflictSegment { .common(Data(text.utf8)) }

    static func block(_ ours: String, _ base: String?, _ theirs: String) -> ConflictSegment {
        .block(ConflictBlock(ours: Data(ours.utf8), base: base.map { Data($0.utf8) }, theirs: Data(theirs.utf8)))
    }

    static func sides(ours: String, base: String?, theirs: String) -> ConflictSides {
        ConflictSides(
            ours: Data(ours.utf8), base: base.map { Data($0.utf8) }, theirs: Data(theirs.utf8), markerSize: 7)
    }

    static func document(
        _ segments: [ConflictSegment], sides: ConflictSides, kind: ConflictKind = .bothModified
    ) throws -> ResolverDocument {
        let stage = ConflictStage(mode: "100644", blob: "a")
        let file = ConflictedFile(
            path: "units.py", kind: kind, base: kind == .bothAdded ? nil : stage, ours: stage, theirs: stage)
        let conflict = ConflictDocument(
            snapshot: ConflictSnapshot(file: file, worktreeHash: "h"), presentation: .blocks(segments),
            matchesGitsConflict: true, worktree: Data("x\n".utf8))
        return try #require(ResolverDocument(document: conflict, sides: sides))
    }

    static let unitsBase = """
        \"\"\"Units for the scaler.\"\"\"

        VOLUME = {
            "cup": 236.6,
            "tbsp": 14.8,
            "tsp": 4.9,
        }

        WEIGHT = {
            "oz": 28.35,
            "lb": 453.6,
        }


        def to_base(amount, unit):
            table = VOLUME if unit in VOLUME else WEIGHT
            return amount * table[unit]


        def round_amount(value):
            return round(value, 1)


        def scale(amount, unit, factor):
            base = to_base(amount, unit)
            return round_amount(base * factor)

        """

    static let unitsOurs = """
        \"\"\"Units for the scaler.\"\"\"

        VOLUME = {
            "cup": 236.6,
            "tbsp": 14.8,
            "tsp": 4.9,
            "pint": 473.2,
        }

        WEIGHT = {
            "oz": 28.35,
            "lb": 453.6,
            "stone": 6350.3,
        }


        def to_base(amount, unit):
            table = VOLUME if unit in VOLUME else WEIGHT
            return amount * table[unit]


        def round_amount(value):
            return round(value, 2)


        def scale(amount, unit, factor):
            base = to_base(amount, unit)
            return round_amount(base * factor)

        """

    static let unitsTheirs = """
        \"\"\"US and metric units for the scaler.\"\"\"

        VOLUME = {
            "cup": 236.6,
            "tbsp": 14.8,
            "tsp": 4.9,
            "ml": 1.0,
            "l": 1000.0,
        }

        WEIGHT = {
            "oz": 28.35,
            "lb": 453.6,
            "g": 1.0,
            "kg": 1000.0,
        }


        def to_base(amount, unit):
            table = VOLUME if unit in VOLUME else WEIGHT
            return amount * table[unit]


        def round_amount(value):
            return round(value, 1 if value < 100 else 0)


        def scale(amount, unit, factor):
            base = to_base(amount, unit)
            return round_amount(base * factor)

        """

    /// The diff3 parse of ours/base/theirs: line 1 auto-merged from theirs, three conflicts
    /// (chunks 1, 3 and 5), the first two with an empty base.
    static let unitsSegments: [ConflictSegment] = [
        common(
            """
            \"\"\"US and metric units for the scaler.\"\"\"

            VOLUME = {
                "cup": 236.6,
                "tbsp": 14.8,
                "tsp": 4.9,

            """),
        block("    \"pint\": 473.2,\n", "", "    \"ml\": 1.0,\n    \"l\": 1000.0,\n"),
        common(
            """
            }

            WEIGHT = {
                "oz": 28.35,
                "lb": 453.6,

            """),
        block("    \"stone\": 6350.3,\n", "", "    \"g\": 1.0,\n    \"kg\": 1000.0,\n"),
        common(
            """
            }


            def to_base(amount, unit):
                table = VOLUME if unit in VOLUME else WEIGHT
                return amount * table[unit]


            def round_amount(value):

            """),
        block(
            "    return round(value, 2)\n", "    return round(value, 1)\n",
            "    return round(value, 1 if value < 100 else 0)\n"),
        common(
            """


            def scale(amount, unit, factor):
                base = to_base(amount, unit)
                return round_amount(base * factor)

            """),
    ]

    static let unitsSides = sides(ours: unitsOurs, base: unitsBase, theirs: unitsTheirs)

    static let editedLine = "    return round(value, 2 if value < 100 else 0)"

    /// The mockup's state: conflict 1 taken Ours + Theirs, conflict 2 waiting, conflict 3 typed.
    static func mockup() throws -> ResolverDocument {
        var document = try document(unitsSegments, sides: unitsSides)
        document.take(.oursThenTheirs, chunk: 1)
        document.replace(document.range(ofChunk: 5), with: editedLine + "\n")
        try #require(document.chunks.first { $0.id == 5 }?.state == .edited)
        return document
    }

    static let filler = LayoutCell(lineNumber: nil, text: nil, tint: .filler, marks: [])

    static func utf16Range(of needle: String, in text: String) -> Range<Int> {
        let found = (text as NSString).range(of: needle)
        return found.location..<(found.location + found.length)
    }

    /// 1-based numbers with nils, from runs: `numbers([1...7, nil, 8...9])`.
    static func numbers(_ parts: [ClosedRange<Int>?]) -> [Int?] {
        parts.flatMap { part -> [Int?] in part.map { Array($0) } ?? [nil] }
    }

    // MARK: - The mockup

    @Test func theMockupAlignsAsDrawn() throws {
        let rows = ResolverLayout.rows(try Self.mockup(), sides: Self.unitsSides, showBase: false)
        try #require(rows.count == 31)

        // Line numbers are each column's own, skipping fillers and the slot.
        #expect(
            rows.map(\.ours.lineNumber)
                == Self.numbers([1...7, nil, nil, 8...13, nil, 14...22, 23...23, 24...28]))
        #expect(rows.map(\.result.lineNumber) == Self.numbers([1...14, nil, nil, 15...29]))
        #expect(rows.map(\.theirs.lineNumber) == Self.numbers([1...8, nil, 9...30]))
        #expect(rows.map(\.chunk) == [0, 0, 0, 0, 0, 0] + [1, 1, 1] + [2, 2, 2, 2, 2] + [3, 3] + Array(repeating: 4, count: 9) + [5] + Array(repeating: 6, count: 5))

        // Row 0: the line merged from theirs.
        #expect(rows[0].result.tint == .fromTheirs)
        #expect(rows[0].badge == .fromTheirs)
        #expect(rows[0].theirs.tint == .theirsChanged)
        #expect(!rows[0].theirs.marks.isEmpty)
        #expect(rows[0].ours.tint == .none)
        #expect(rows[0].ours.text == "\"\"\"Units for the scaler.\"\"\"")
        #expect(rows[0].result.text == "\"\"\"US and metric units for the scaler.\"\"\"")

        // Rows 1–5 are unchanged everywhere, with no badge.
        for row in rows[1...5] {
            #expect(row.ours.tint == .none && row.result.tint == .none && row.theirs.tint == .none)
            #expect(row.badge == nil && !row.isSlot)
        }

        // Rows 6–8: conflict 1, taken Ours + Theirs; two ours fillers, one theirs filler.
        #expect(rows[6].ours.text == "    \"pint\": 473.2,")
        #expect(rows[6].ours.tint == .oursChanged)
        #expect(rows[6].ours.marks == [Self.utf16Range(of: "\"pint\": 473.2,", in: rows[6].ours.text ?? "")])
        #expect(rows[7].ours == Self.filler && rows[8].ours == Self.filler)
        #expect(rows[6].theirs.text == "    \"ml\": 1.0," && rows[7].theirs.text == "    \"l\": 1000.0,")
        #expect(rows[6].theirs.tint == .theirsChanged && rows[7].theirs.tint == .theirsChanged)
        #expect(rows[8].theirs == Self.filler)
        #expect(rows[6...8].map(\.result.tint) == [.taken, .taken, .taken])
        #expect(rows[6...8].map(\.result.text) == ["    \"pint\": 473.2,", "    \"ml\": 1.0,", "    \"l\": 1000.0,"])
        #expect(rows[6...8].map(\.badge) == [.oursThenTheirs, nil, nil])

        // Rows 14–15: conflict 2's slot.
        for row in rows[14...15] {
            #expect(row.isSlot)
            #expect(row.result.text == nil && row.result.lineNumber == nil)
            #expect(row.badge == nil)
        }
        #expect(rows[14].ours.text == "    \"stone\": 6350.3,")
        #expect(rows[15].ours == Self.filler)
        #expect(rows[14].theirs.text == "    \"g\": 1.0," && rows[15].theirs.text == "    \"kg\": 1000.0,")
        #expect(rows.filter(\.isSlot).count == 2)

        // Row 25: conflict 3, edited; each side's marks against the base.
        let ours = try #require(rows[25].ours.text), theirs = try #require(rows[25].theirs.text)
        #expect(rows[25].ours.tint == .oursChanged)
        #expect(rows[25].ours.marks == [Self.utf16Range(of: "2", in: ours)])
        #expect(rows[25].theirs.tint == .theirsChanged)
        #expect(rows[25].theirs.marks == [Self.utf16Range(of: " if value < 100 else 0", in: theirs)])
        #expect(rows[25].result.text == Self.editedLine)
        #expect(rows[25].result.tint == .edited)
        #expect(rows[25].badge == .editedByYou)

        // Nothing else is tinted or badged, and no row is a base strip.
        let marked: Set<Int> = [0, 6, 7, 8, 14, 15, 25]
        for (index, row) in rows.enumerated() where !marked.contains(index) {
            #expect(row.ours.tint == .none && row.result.tint == .none && row.theirs.tint == .none, "row \(index)")
            #expect(row.badge == nil, "row \(index)")
        }
        #expect(rows.allSatisfy { !$0.isBaseStrip })
    }

    // MARK: - Typing

    @Test func typingANewLinePushesTheSideFillers() throws {
        // Into conflict 1 (taken): it becomes edited and four lines tall.
        var document = try Self.mockup()
        let chunk1 = document.range(ofChunk: 1)
        document.replace(NSRange(location: chunk1.location, length: 0), with: "    \"cl\": 10.0,\n")
        var rows = ResolverLayout.rows(document, sides: Self.unitsSides, showBase: false)
        #expect(rows.count == 32)
        #expect(rows[6...9].allSatisfy { $0.chunk == 1 })
        #expect(rows[6...9].map(\.result.tint) == [.edited, .edited, .edited, .edited])
        #expect(rows[6...9].map(\.badge) == [.editedByYou, nil, nil, nil])
        #expect(rows[6...9].map(\.ours.lineNumber) == [7, nil, nil, nil])
        #expect(rows[6...9].map(\.theirs.lineNumber) == [7, 8, nil, nil])
        #expect(rows[10].ours.lineNumber == 8 && rows[10].result.lineNumber == 11 && rows[10].theirs.lineNumber == 9)

        // Into common text: the typed line is edited, with a filler on each side.
        document = try Self.mockup()
        let chunk2 = document.range(ofChunk: 2)
        document.replace(NSRange(location: chunk2.location, length: 0), with: "# note\n")
        rows = ResolverLayout.rows(document, sides: Self.unitsSides, showBase: false)
        #expect(rows.count == 32)
        let typed = rows[9]
        #expect(typed.chunk == 2)
        #expect(typed.result.text == "# note" && typed.result.tint == .edited && typed.result.lineNumber == 10)
        #expect(typed.badge == .editedByYou)
        #expect(typed.ours == Self.filler && typed.theirs == Self.filler)
        #expect(rows[10].ours.text == "}" && rows[10].ours.lineNumber == 8 && rows[10].result.lineNumber == 11)
        #expect(rows[10].result.tint == .none && rows[10].badge == nil)
    }

    @Test func anEditedCommonLineIsEditedAgainstGitsText() throws {
        var document = try Self.mockup()
        // Retype "WEIGHT = {" as "MASS = {" in chunk 2.
        let range = (document.resultText as NSString).range(of: "WEIGHT")
        document.replace(range, with: "MASS")
        let rows = ResolverLayout.rows(document, sides: Self.unitsSides, showBase: false)
        #expect(rows.count == 31)
        #expect(rows[11].result.text == "MASS = {")
        #expect(rows[11].result.tint == .edited && rows[11].badge == .editedByYou)
        #expect(rows[11].ours.text == "WEIGHT = {" && rows[11].theirs.text == "WEIGHT = {")
        #expect(rows[10].badge == nil && rows[12].badge == nil)
    }

    // MARK: - Deletions

    @Test func aDeletionByOneSideIsAFillerOnThatSide() throws {
        // Ours deleted "b" (theirs kept it), and both changed "x".
        let sides = Self.sides(ours: "a\nc\nX1\n", base: "a\nb\nc\nx\n", theirs: "a\nb\nc\nX2\n")
        var document = try Self.document([Self.common("a\nc\n"), Self.block("X1\n", "x\n", "X2\n")], sides: sides)
        var rows = ResolverLayout.rows(document, sides: sides, showBase: false)
        #expect(rows.map(\.ours.lineNumber) == [1, nil, 2, 3])
        #expect(rows.map(\.result.lineNumber) == [1, nil, 2, nil])
        #expect(rows.map(\.theirs.lineNumber) == [1, 2, 3, 4])
        #expect(rows[1].ours == Self.filler && rows[1].result == Self.filler)
        #expect(rows[1].theirs.text == "b" && rows[1].theirs.tint == .none)
        #expect(rows[1].chunk == 0)

        // A conflict whose ours side is empty: a filler on ours while it waits.
        let repeated = Self.sides(ours: "a\n}\n}\nb\n", base: "a\n}\nx\n}\nb\n", theirs: "a\n}\nX2\n}\nB\n")
        document = try Self.document(
            [Self.common("a\n}\n"), Self.block("", "x\n", "X2\n"), Self.common("}\nB\n")], sides: repeated)
        rows = ResolverLayout.rows(document, sides: repeated, showBase: false)
        // The "}" on each side of the empty block is told apart by the common text around it.
        #expect(rows.map(\.ours.lineNumber) == [1, 2, nil, 3, 4])
        #expect(rows.map(\.theirs.lineNumber) == [1, 2, 3, 4, 5])
        #expect(rows[2].isSlot && rows[2].ours == Self.filler && rows[2].theirs.text == "X2")
        #expect(rows[4].ours.text == "b" && rows[4].result.text == "B" && rows[4].result.tint == .fromTheirs)
        #expect(rows[4].badge == .fromTheirs && rows[4].theirs.tint == .theirsChanged)
    }

    @Test func theCommonTextAroundABlockPlacesItAmongRepeatedLines() throws {
        // Ours deleted "x"; theirs changed it and added two lines at the top. The empty ours
        // side could sit before either "}": the common text's last lines ("a", "}") say which,
        // though the common text is two lines longer than ours' part of it.
        let sides = Self.sides(ours: "a\n}\n}\nb\n", base: "a\n}\nx\n}\nb\n", theirs: "t1\nt2\na\n}\nX2\n}\nb\n")
        let document = try Self.document(
            [Self.common("t1\nt2\na\n}\n"), Self.block("", "x\n", "X2\n"), Self.common("}\nb\n")], sides: sides)
        let rows = ResolverLayout.rows(document, sides: sides, showBase: false)
        #expect(rows.map(\.ours.lineNumber) == [nil, nil, 1, 2, nil, 3, 4])
        #expect(rows.map(\.theirs.lineNumber) == [1, 2, 3, 4, 5, 6, 7])
        #expect(rows.map(\.result.lineNumber) == [1, 2, 3, 4, nil, 5, 6])
        #expect(rows.map(\.chunk) == [0, 0, 0, 0, 1, 2, 2])
        #expect(rows[0...1].map(\.result.tint) == [.fromTheirs, .fromTheirs])
        #expect(rows[0...1].map(\.badge) == [.fromTheirs, nil])
        #expect(rows[0].result.marks == [0..<2] && rows[0].theirs.tint == .theirsChanged)
        #expect(rows[4].isSlot && rows[4].ours == Self.filler)
    }

    @Test func noTwoResultRowsShareALineNumberAfterABreakIsDeleted() throws {
        // Deleting the line break a taken conflict ends with: its last line runs on into the
        // common text's first, and the two chunks merge (Ruling 11), so the joined line is one
        // Result row.
        let sides = Self.sides(ours: "a\nO\nz\n", base: "a\nB\nz\n", theirs: "a\nT\nz\n")
        var document = try Self.document(
            [Self.common("a\n"), Self.block("O\n", "B\n", "T\n"), Self.common("z\n")], sides: sides)
        document.take(.ours, chunk: 1)
        document.replace(NSRange(location: 3, length: 1), with: "")
        #expect(document.resultText == "a\nOz\n")
        let rows = ResolverLayout.rows(document, sides: sides, showBase: false)
        let numbers = rows.compactMap(\.result.lineNumber)
        #expect(numbers == [1, 2])
        #expect(Set(numbers).count == numbers.count)
        #expect(rows.compactMap(\.result.text) == ["a", "Oz"])
        #expect(rows.compactMap(\.ours.lineNumber) == [1, 2, 3])
    }

    // MARK: - Show Base

    @Test func showBaseYieldsTheBaseStrip() throws {
        let document = try Self.mockup()
        #expect(ResolverLayout.baseStrip(document, chunk: 5) == ["    return round(value, 1)"])
        #expect(ResolverLayout.baseStrip(document, chunk: 1) == nil)  // both sides only added lines
        #expect(ResolverLayout.baseStrip(document, chunk: 0) == nil)  // common text
        #expect(ResolverLayout.baseStrip(document, chunk: 99) == nil)

        let rows = ResolverLayout.rows(document, sides: Self.unitsSides, showBase: true)
        #expect(rows.count == 34)  // one strip row above each of the three conflicts
        let strips = rows.enumerated().filter { $0.element.isBaseStrip }
        #expect(strips.map(\.offset) == [6, 15, 27])
        for (offset, row) in strips {
            #expect(row.ours == Self.filler && row.theirs == Self.filler)
            #expect(row.result.tint == .filler && row.result.lineNumber == nil && row.result.marks.isEmpty)
            #expect(row.badge == nil && !row.isSlot)
            #expect(rows[offset + 1].chunk == row.chunk && !rows[offset + 1].isBaseStrip)
        }
        #expect(rows[6].result.text == nil && rows[15].result.text == nil)
        #expect(rows[27].result.text == "    return round(value, 1)")
        // The badge moves to the chunk's first row below the strip.
        #expect(rows[7].badge == .oursThenTheirs && rows[28].badge == .editedByYou)
        // Line numbers below are unaffected.
        let plain = ResolverLayout.rows(document, sides: Self.unitsSides, showBase: false)
        #expect(rows.filter { !$0.isBaseStrip } == plain)
    }

    @Test func anAddAddHasNoBaseStrip() throws {
        let ours = "header\nours line\nfooter\n", theirs = "header\ntheirs line\nfooter\n"
        let sides = ConflictSides(ours: Data(ours.utf8), base: nil, theirs: Data(theirs.utf8), markerSize: 7)
        let document = try Self.document(
            [Self.common("header\n"), Self.block("ours line\n", "", "theirs line\n"), Self.common("footer\n")],
            sides: sides, kind: .bothAdded)
        #expect(ResolverLayout.baseStrip(document, chunk: 1) == nil)
        let rows = ResolverLayout.rows(document, sides: sides, showBase: true)
        #expect(rows.count == 4)
        #expect(rows[1].isBaseStrip && rows[1].result.text == nil && rows[1].chunk == 1)
        // Without a base, the common lines are not tinted and a block's lines are marked whole.
        #expect(rows[0].ours.tint == .none && rows[3].theirs.tint == .none)
        #expect(rows[2].ours.tint == .oursChanged && rows[2].ours.marks == [0..<9])
        #expect(rows[2].theirs.tint == .theirsChanged && rows[2].theirs.marks == [0..<11])
        #expect(rows[2].isSlot)
    }

    // MARK: - Badges

    @Test func badgesNameTheChoice() throws {
        let sides = Self.sides(ours: "top\no1\nend\n", base: "top\nb1\nend\n", theirs: "top\nt1\nend\n")
        let segments = [Self.common("top\n"), Self.block("o1\n", "b1\n", "t1\n"), Self.common("end\n")]
        func badge(_ change: (inout ResolverDocument) -> Void) throws -> ResultBadge? {
            var document = try Self.document(segments, sides: sides)
            change(&document)
            let rows = ResolverLayout.rows(document, sides: sides, showBase: false)
            #expect(rows.filter { $0.badge != nil }.allSatisfy { $0.chunk == 1 })
            return rows.first { $0.chunk == 1 }?.badge
        }
        #expect(try badge { _ in } == nil)
        #expect(try badge { $0.take(.ours, chunk: 1) } == .ours)
        #expect(try badge { $0.take(.theirs, chunk: 1) } == .theirs)
        #expect(try badge { $0.take(.oursThenTheirs, chunk: 1) } == .oursThenTheirs)
        #expect(try badge { $0.take(.theirsThenOurs, chunk: 1) } == .theirsThenOurs)
        #expect(try badge { $0.replace($0.range(ofChunk: 1), with: "mine\n") } == .editedByYou)
    }

    @Test func aMergedChunkSpansTheUnionOfItsSides() throws {
        // An edit across conflict 1 and the common text below it merges chunks 1 and 2.
        var document = try Self.mockup()
        let start = document.range(ofChunk: 1).location
        let end = (document.resultText as NSString).range(of: "WEIGHT").location
        document.replace(NSRange(location: start, length: end - start), with: "")
        let merged = try #require(document.chunks.first { $0.id == 1 })
        #expect(merged.isMerged && merged.state == .edited)
        let rows = ResolverLayout.rows(document, sides: Self.unitsSides, showBase: false)
        let chunk1 = rows.filter { $0.chunk == 1 }
        // The merged chunk holds all of chunk 2: ours 7…12 ("pint" to "lb"), theirs 7…13 ("ml" to
        // "lb"), and the Result's three lines left, with fillers below.
        #expect(chunk1.map(\.ours.lineNumber) == [7, 8, 9, 10, 11, 12, nil])
        #expect(chunk1.map(\.theirs.lineNumber) == Array(7...13))
        #expect(chunk1.map(\.result.lineNumber) == [7, 8, 9, nil, nil, nil, nil])
        #expect(chunk1.prefix(3).map(\.result.text) == ["WEIGHT = {", "    \"oz\": 28.35,", "    \"lb\": 453.6,"])
        #expect(chunk1.prefix(3).allSatisfy { $0.result.tint == .edited })
        #expect(chunk1.dropFirst(3).allSatisfy { $0.result == Self.filler })
        #expect(chunk1.map(\.badge) == [.editedByYou, nil, nil, nil, nil, nil, nil])
        #expect(rows.first { $0.chunk == 3 }?.ours.text == "    \"stone\": 6350.3,")
        #expect(rows.first { $0.chunk == 2 } == nil)
        #expect(rows.map(\.ours.lineNumber).compactMap { $0 } == Array(1...28))
        #expect(rows.map(\.theirs.lineNumber).compactMap { $0 } == Array(1...30))
    }

    /// The repeated-"}" fixture with conflict 1 taken Theirs: "a\n}\nX2\n}\nB\n".
    static let repeatedSides = sides(ours: "a\n}\n}\nb\n", base: "a\n}\nx\n}\nb\n", theirs: "a\n}\nX2\n}\nB\n")
    static func repeatedTakenTheirs() throws -> ResolverDocument {
        var document = try document(
            [common("a\n}\n"), block("", "x\n", "X2\n"), common("}\nB\n")], sides: repeatedSides)
        document.take(.theirs, chunk: 1)
        return document
    }

    @Test func aMergedChunkAfterCommonTextIsPlacedByThatText() throws {
        // An edit from conflict 1 into the common text below merges chunks 1 and 2. The empty
        // ours side could sit before either "}": chunk 0's text says which.
        var document = try Self.repeatedTakenTheirs()
        document.replace(NSRange(location: 5, length: 3), with: "")
        #expect(document.chunks.map(\.id) == [0, 1])
        let rows = ResolverLayout.rows(document, sides: Self.repeatedSides, showBase: false)
        let chunk0 = rows.filter { $0.chunk == 0 }
        #expect(chunk0.map(\.ours.lineNumber) == [1, 2])
        #expect(chunk0.map(\.result.tint) == [.none, .none] && chunk0.map(\.badge) == [nil, nil])
        let merged = rows.filter { $0.chunk == 1 }
        #expect(merged.map(\.ours.lineNumber) == [3, 4, nil])
        #expect(merged.map(\.theirs.lineNumber) == [3, 4, 5])
    }

    @Test func aMergedChunkBeforeCommonTextKeepsItsOwnCommonLines() throws {
        // An edit from chunk 0 into conflict 1 merges them; the common text it took in places
        // the empty ours side after its own "}".
        var document = try Self.repeatedTakenTheirs()
        document.replace(NSRange(location: 2, length: 3), with: "")
        #expect(document.chunks.map(\.id) == [0, 2])
        let rows = ResolverLayout.rows(document, sides: Self.repeatedSides, showBase: false)
        #expect(rows.filter { $0.chunk == 0 }.map(\.ours.lineNumber) == [1, 2, nil])
        let chunk2 = rows.filter { $0.chunk == 2 }
        #expect(chunk2.map(\.ours.lineNumber) == [3, 4])
        #expect(chunk2.map(\.result.tint) == [.none, .fromTheirs])
        #expect(chunk2.map(\.badge) == [nil, .fromTheirs])
    }

    @Test func aMergedChunksBaseStripJoinsItsBlocksBases() throws {
        let sides = Self.sides(ours: "top\no1\nmid\no2\nend\n", base: "top\nb1\nmid\nb2\nend\n", theirs: "top\nt1\nmid\nt2\nend\n")
        var document = try Self.document(
            [
                Self.common("top\n"), Self.block("o1\n", "b1\n", "t1\n"), Self.common("mid\n"),
                Self.block("o2\n", "b2\n", "t2\n"), Self.common("end\n"),
            ], sides: sides)
        document.take(.ours, chunk: 1)
        document.take(.ours, chunk: 3)
        let range = (document.resultText as NSString).range(of: "o1\nmid\no2")
        document.replace(range, with: "one")
        #expect(document.chunks.map(\.id) == [0, 1, 4])
        #expect(ResolverLayout.baseStrip(document, chunk: 1) == ["b1", "b2"])
        let rows = ResolverLayout.rows(document, sides: sides, showBase: true)
        let merged = rows.filter { $0.chunk == 1 }
        #expect(merged.map(\.isBaseStrip) == [true, true, false, false, false])
        #expect(merged.map(\.result.text) == ["b1", "b2", "one", nil, nil])
        #expect(merged.map(\.ours.lineNumber) == [nil, nil, 2, 3, 4])
        #expect(merged.map(\.badge) == [nil, nil, .editedByYou, nil, nil])
    }

    // MARK: - Prebuilt sides

    @Test func prebuiltSidesGiveTheSameRows() throws {
        // Built once from the pristine document, then reused through a take, typing in common
        // text and typing in the taken conflict: every call matches a fresh build.
        var document = try Self.document(Self.unitsSegments, sides: Self.unitsSides)
        let prebuilt = ResolverLayout.Sides(Self.unitsSides, document: document)
        func expectSameRows(sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(prebuilt.fits(document), sourceLocation: sourceLocation)
            for showBase in [false, true] {
                let fresh = ResolverLayout.rows(document, sides: Self.unitsSides, showBase: showBase)
                #expect(!fresh.isEmpty, sourceLocation: sourceLocation)
                #expect(
                    ResolverLayout.rows(document, using: prebuilt, showBase: showBase) == fresh,
                    sourceLocation: sourceLocation)
            }
        }
        expectSameRows()
        document = try Self.mockup()
        expectSameRows()
        document.replace(NSRange(location: document.range(ofChunk: 2).location, length: 0), with: "# note\n")
        expectSameRows()
        document.replace(NSRange(location: document.range(ofChunk: 1).location, length: 0), with: "    \"cl\": 10.0,\n")
        #expect(document.chunks.first { $0.id == 1 }?.state == .edited)
        expectSameRows()
    }

    @Test func prebuiltSidesFitUntilChunksMerge() throws {
        var document = try Self.mockup()
        let prebuilt = ResolverLayout.Sides(Self.unitsSides, document: document)
        #expect(prebuilt.fits(document))
        document.take(.theirs, chunk: 3)
        document.replace(NSRange(location: document.range(ofChunk: 4).location, length: 0), with: "x")
        #expect(prebuilt.fits(document))  // takes and typing inside one chunk keep the structure

        // An edit across conflict 1 and the common text below merges chunks 1 and 2.
        let start = document.range(ofChunk: 1).location
        let end = (document.resultText as NSString).range(of: "WEIGHT").location
        document.replace(NSRange(location: start, length: end - start), with: "")
        #expect(!prebuilt.fits(document))
        // Used anyway, it rebuilds rather than misplacing the merged chunk.
        #expect(
            ResolverLayout.rows(document, using: prebuilt, showBase: false)
                == ResolverLayout.rows(document, sides: Self.unitsSides, showBase: false))
        #expect(ResolverLayout.Sides(Self.unitsSides, document: document).fits(document))
    }

    /// A `Sides` refitted after chunks merge (and split again, by undo) keeps the stages' tints
    /// and marks and redoes only the placement: its rows are a fresh build's (Ruling 28).
    @Test func aRefittedSidesGivesTheSameRowsAsAFreshOne() throws {
        let pristine = try Self.mockup()
        let prebuilt = ResolverLayout.Sides(Self.unitsSides, document: pristine)
        var merged = pristine
        let start = merged.range(ofChunk: 1).location
        let end = (merged.resultText as NSString).range(of: "WEIGHT").location
        merged.replace(NSRange(location: start, length: end - start), with: "")
        #expect(!prebuilt.fits(merged))
        let refitted = prebuilt.refitted(to: merged)
        #expect(refitted.fits(merged))
        for showBase in [false, true] {
            #expect(
                ResolverLayout.rows(merged, using: refitted, showBase: showBase)
                    == ResolverLayout.rows(merged, sides: Self.unitsSides, showBase: showBase))
        }
        // Back to the unmerged chunks (an undo): refitted again, the same as fresh.
        let back = refitted.refitted(to: pristine)
        #expect(back.fits(pristine))
        #expect(
            ResolverLayout.rows(pristine, using: back, showBase: false)
                == ResolverLayout.rows(pristine, sides: Self.unitsSides, showBase: false))
        // Still fitting: itself.
        #expect(ResolverLayout.rows(pristine, using: prebuilt.refitted(to: pristine), showBase: false)
            == ResolverLayout.rows(pristine, using: prebuilt, showBase: false))
    }

    @Test func crlfLinesHaveNoTerminatorInTheirText() throws {
        let sides = Self.sides(ours: "a\r\nO\r\nz\r\n", base: "a\r\nB\r\nz\r\n", theirs: "a\r\nT\r\nz\r\n")
        var document = try Self.document(
            [Self.common("a\r\n"), Self.block("O\r\n", "B\r\n", "T\r\n"), Self.common("z\r\n")], sides: sides)
        document.take(.ours, chunk: 1)
        let rows = ResolverLayout.rows(document, sides: sides, showBase: false)
        #expect(rows.map(\.result.text) == ["a", "O", "z"])
        #expect(rows.map(\.ours.text) == ["a", "O", "z"])
        #expect(rows.map(\.result.lineNumber) == [1, 2, 3])
    }
}
