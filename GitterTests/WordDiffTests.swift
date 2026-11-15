import Foundation
import Testing

@testable import Gitter

/// Word-level change marks: the ranges of `new` (UTF-16 offsets) that are not in `old`, or the
/// whole line when less than half of it stayed.
@Suite struct WordDiffTests {

    /// `needle`'s UTF-16 range in `text`.
    static func range(of needle: String, in text: String) -> Range<Int> {
        let found = (text as NSString).range(of: needle)
        return found.location..<(found.location + found.length)
    }

    @Test func aChangedNumberMarksOnlyTheNumber() {
        #expect(WordDiff.marks(old: "round(value, 1)", new: "round(value, 2)") == [13..<14])
    }

    @Test func anAdditionMarksOnlyWhatWasAdded() {
        let new = "1 if value < 100 else 0"
        #expect(WordDiff.marks(old: "1", new: new) == [Self.range(of: " if value < 100 else 0", in: new)])
    }

    @Test func theMockupsConflictMarks() {
        let base = "    return round(value, 1)"
        let ours = "    return round(value, 2)"
        let theirs = "    return round(value, 1 if value < 100 else 0)"
        #expect(WordDiff.marks(old: base, new: ours) == [24..<25])
        #expect(WordDiff.marks(old: base, new: theirs) == [Self.range(of: " if value < 100 else 0", in: theirs)])
    }

    @Test func anUnrelatedLineMarksTheWholeLine() {
        let new = "let total = items.count"
        #expect(WordDiff.marks(old: "return base * factor", new: new) == [0..<new.utf16.count])
    }

    @Test func anEmptyOldMarksTheWholeLine() {
        let new = "    \"pint\": 473.2,"
        #expect(WordDiff.marks(old: "", new: new) == [0..<new.utf16.count])
    }

    @Test func anUnchangedLineHasNoMarks() {
        #expect(WordDiff.marks(old: "same line", new: "same line").isEmpty)
    }

    @Test func offsetsAreUTF16() {
        // 👍 is one Character but two UTF-16 units: "2" is at 16 in UTF-16, 15 in Characters.
        let new = "👍 round(value, 2)"
        #expect(WordDiff.marks(old: "👍 round(value, 1)", new: new) == [16..<17])
        #expect(Self.range(of: "2", in: new) == 16..<17)
    }

    @Test func changedWordsSeparatedBySpaceAreOneMark() {
        let new = "\"\"\"US and metric units for the scaler.\"\"\""
        #expect(
            WordDiff.marks(old: "\"\"\"Units for the scaler.\"\"\"", new: new)
                == [Self.range(of: "US and metric units", in: new)])
    }
}
