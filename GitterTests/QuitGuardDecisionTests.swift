import Foundation
import Testing

@testable import Gitter

/// E2 Task 2: what `QuitGuard` does with every store's lane, decided from the lanes alone. Pure:
/// no store, no alert, no `NSApp`.
@MainActor @Suite struct QuitGuardDecisionTests {

    private static let fetch = RemoteActivity(kind: .fetch, remote: "origin")
    private static let autoFetch = RemoteActivity(kind: .autoFetch, remote: nil)
    private static let push = RemoteActivity(kind: .push, remote: "origin")
    private static let deleteTag = RemoteActivity(kind: .deleteRemoteTag, remote: "origin")

    @Test func noStoreQuitsNow() {
        #expect(QuitGuard.decision([]) == .now)
    }

    @Test func everyLaneFreeQuitsNow() {
        #expect(QuitGuard.decision([nil, nil]) == .now)
    }

    @Test func aReadOnAnyLaneIsStopped() {
        #expect(QuitGuard.decision([nil, Self.fetch]) == .stopReads)
        #expect(QuitGuard.decision([Self.autoFetch]) == .stopReads)
    }

    /// The read comes first, the write second: the question is about the write, and the index
    /// names its store.
    @Test func aReadAndAWriteAskAboutTheWrite() {
        #expect(QuitGuard.decision([Self.fetch, Self.push]) == .ask(writeAt: 1))
    }

    @Test func twoWritesAskAboutTheFirst() {
        #expect(QuitGuard.decision([Self.push, Self.deleteTag]) == .ask(writeAt: 0))
    }
}
