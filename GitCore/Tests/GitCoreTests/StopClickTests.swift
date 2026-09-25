import Foundation
import Testing

@testable import GitCore

/// `StopClick.isDeliberate`: the toolbar's Stop drops a click that arrives so soon after the
/// activity started that it is the tail of the click that started it (Task 9's review: a
/// double-click on Fetch cancelled the fetch it had just begun).
@Suite struct StopClickTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aClickBeforeTheIntervalIsDropped() {
        #expect(!StopClick.isDeliberate(
            startedAt: Self.start, now: Self.start.addingTimeInterval(0.2), doubleClickInterval: 0.5))
    }

    @Test func aClickExactlyAtTheIntervalIsAccepted() {
        #expect(StopClick.isDeliberate(
            startedAt: Self.start, now: Self.start.addingTimeInterval(0.5), doubleClickInterval: 0.5))
    }

    @Test func aClickAfterTheIntervalIsAccepted() {
        #expect(StopClick.isDeliberate(
            startedAt: Self.start, now: Self.start.addingTimeInterval(0.8), doubleClickInterval: 0.5))
    }

    /// The system setting goes up to 5 s; Stop must not ignore a deliberate click for that long.
    @Test func aLongSystemIntervalIsCappedAtSixTenths() {
        #expect(StopClick.isDeliberate(
            startedAt: Self.start, now: Self.start.addingTimeInterval(0.6), doubleClickInterval: 5))
        #expect(!StopClick.isDeliberate(
            startedAt: Self.start, now: Self.start.addingTimeInterval(0.59), doubleClickInterval: 5))
    }
}
