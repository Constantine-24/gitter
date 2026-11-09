import Foundation
import GitCoreTestSupport
import Synchronization
import Testing

@testable import Gitter

/// A folder of the test's own under the temporary directory, not made yet: the writer makes it.
/// `remove()` takes it and everything in it.
struct LogTestFolder {
    let parent: URL
    let url: URL

    init() {
        parent = FileManager.default.temporaryDirectory.appending(path: "gitter-log-\(UUID().uuidString)")
        url = parent.appending(path: "logs")
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }

    /// The file names in the folder, sorted.
    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    /// The lines of `name` in the folder, in order.
    func lines(_ name: String = "gitter.log") throws -> [String] {
        let text = try String(contentsOf: url.appending(path: name), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
}

/// P1 Task 2: the log file's writer — one serial queue, lines in order, rotation at the limit,
/// a folder made again when it was deleted (RF2), every line whole under appends from many
/// threads (RF1), and a writer that stops for good, without throwing, when it cannot write.
/// Every writer here writes inside its own temporary folder. Every wait for the writer's queue is
/// `settle`, which a time limit can end (`CallUnderTest`, the final review's m5).
@Suite(.timeLimit(.minutes(10))) struct LogFileWriterTests {

    @Test func linesComeBackInOrderAfterAFlush() async throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url)
        writer.append("one")
        writer.append("two words")
        writer.append("three")
        await settle(writer)

        #expect(writer.fileURL == folder.url.appending(path: "gitter.log"))
        #expect(try folder.lines() == ["one", "two words", "three"])
        #expect(!writer.hasStopped)
    }

    /// Seventy lines of 100 bytes each (the newline included) at a limit of 1 000: ten lines a
    /// file, six rotations. Five files are kept — `gitter.log` with the newest ten, then
    /// `gitter.1.log` … `gitter.4.log` going back — and the oldest twenty lines are gone.
    @Test func theFileRotatesAtTheLimitKeepingFiveFiles() async throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url, limit: 1_000)
        let written = Self.hundredByteLines(70)
        for line in written { writer.append(line) }
        await settle(writer)

        #expect(
            try folder.names() == ["gitter.1.log", "gitter.2.log", "gitter.3.log", "gitter.4.log", "gitter.log"])
        #expect(try folder.lines("gitter.log") == Array(written[60..<70]))
        #expect(try folder.lines("gitter.1.log") == Array(written[50..<60]))
        #expect(try folder.lines("gitter.4.log") == Array(written[20..<30]))
        let kept = try folder.names().flatMap { try folder.lines($0) }
        #expect(!kept.contains(written[0]))
        #expect(!kept.contains(written[19]))
        #expect(kept.count == 50)
        #expect(!writer.hasStopped)
    }

    /// The control for the rotation check: the rotated files counted are not six.
    @Test func theRotationCheckCanFail() async throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url, limit: 1_000)
        for line in Self.hundredByteLines(70) { writer.append(line) }
        await settle(writer)
        let rotated = try folder.names().filter { $0 != "gitter.log" }.count
        withKnownIssue("five files are kept, so four are rotated, not six") {
            #expect(rotated == 6)
        }
    }

    @Test func aFolderThatCannotBeMadeStopsTheWriterWithoutThrowing() async throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.parent, withIntermediateDirectories: true)
        // A plain file where a folder above the log's would have to be.
        let plain = folder.parent.appending(path: "plain")
        try Data("not a folder".utf8).write(to: plain)
        let writer = LogFileWriter(folder: plain.appending(path: "logs"))

        writer.append("first")
        await settle(writer)
        #expect(writer.hasStopped)
        writer.append("second")
        await settle(writer)
        #expect(writer.hasStopped)
        #expect(!FileManager.default.fileExists(atPath: plain.appending(path: "logs").path))
        #expect(try Data(contentsOf: plain) == Data("not a folder".utf8))
    }

    /// RF2: the log's folder deleted while the app runs (the user cleaning up) is made again, with
    /// a new `gitter.log`, at the next line.
    @Test func aDeletedFolderIsMadeAgainAtTheNextLine() async throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url)
        writer.append("before")
        await settle(writer)
        #expect(try folder.lines() == ["before"])

        try FileManager.default.removeItem(at: folder.url)
        writer.append("after")
        await settle(writer)

        #expect(try folder.lines() == ["after"])
        #expect(!writer.hasStopped)
    }

    /// RF1: eight threads appending at once lose no line, tear none and duplicate none, and each
    /// thread's lines stay in its own order.
    @Test func appendsFromManyThreadsAreEachOneWholeLine() async throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url)
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for index in 0..<200 { writer.append("thread \(thread) line \(index) " + String(repeating: "x", count: 40)) }
        }
        await settle(writer)

        let lines = try folder.lines()
        var expected = Set<String>()
        for thread in 0..<8 {
            for index in 0..<200 { expected.insert("thread \(thread) line \(index) " + String(repeating: "x", count: 40)) }
        }
        #expect(lines.count == 1_600)
        #expect(Set(lines) == expected)
        for thread in 0..<8 {
            let own = lines.filter { $0.hasPrefix("thread \(thread) line ") }
            let indices = own.compactMap { Int($0.split(separator: " ")[3]) }
            #expect(indices == Array(0..<200), "thread \(thread)'s lines in its order")
        }
        #expect(!writer.hasStopped)
    }

    /// M1: the file is opened to append, so a second writer on the same file — a Debug build beside
    /// the installed one — adds its lines after the first one's instead of over them. (Two writers
    /// rotating the same folder can still race.)
    @Test func twoWritersOnOneFileOverwriteNothing() async throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let one = LogFileWriter(folder: folder.url)
        let two = LogFileWriter(folder: folder.url)
        one.append("one first")
        await settle(one)
        two.append("two first")
        await settle(two)
        one.append("one second")
        await settle(one)
        #expect(try folder.lines() == ["one first", "two first", "one second"])
    }

    /// m11: a write stuck on a hung volume holds the queue, and the bounded flush gives up on it at
    /// its limit instead of waiting with it; once the volume answers, the line is written and the
    /// writer goes on.
    @Test func aWriterStuckOnAHungWriteDoesNotHoldTheBoundedFlush() async throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let volume = HangingFileManager()
        let writer = LogFileWriter(folder: folder.url, fileManager: volume)
        writer.append("first")
        await settle(writer)
        volume.hang()
        defer { volume.answer() }
        writer.append("second")
        while volume.hangs == 0 { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(!writer.flush(within: .milliseconds(50)))

        volume.answer()
        await settle(writer)
        #expect(try folder.lines() == ["first", "second"])
        #expect(!writer.hasStopped)
        #expect(volume.hangs == 1, "the stuck call was the writer's own check of its file")
    }

    /// The control for `settle`: a queue stuck on a hung write never drains, and the wait for it is
    /// caught by the hang guard — cancelled here as `.timeLimit` cancels it — with the guard's own
    /// issue, instead of freezing the run.
    @Test func aQueueThatNeverDrainsIsCaughtBySettle() async throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let volume = HangingFileManager()
        let writer = LogFileWriter(folder: folder.url, fileManager: volume)
        writer.append("first")
        await settle(writer)
        volume.hang()
        defer { volume.answer() }
        writer.append("second")

        await withKnownIssue("the writer's queue is stuck on a hung write and never drains") {
            let waiter = Task { await settle(writer) }
            while volume.hangs == 0 { try? await Task.sleep(for: .milliseconds(5)) }
            try? await Task.sleep(for: .milliseconds(100))
            waiter.cancel()
            await waiter.value
        } matching: { $0.isNeverCameBack }

        volume.answer()
        await settle(writer)
        #expect(try folder.lines() == ["first", "second"])
    }

    /// The control: with nothing stuck, the bounded flush says every line is written.
    @Test func anIdleWritersBoundedFlushSaysItIsDone() async throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url)
        writer.append("one")
        await settle(writer)
        let done = writer.flush(within: .seconds(60))
        #expect(done)
        withKnownIssue("an idle writer's flush is done, not timed out") {
            #expect(!done)
        }
    }

    /// `count` distinct lines of 99 characters: 100 bytes each with the newline.
    static func hundredByteLines(_ count: Int) -> [String] {
        (1...count).map { index in
            let number = String(format: "%03d ", index)
            return number + String(repeating: "x", count: 99 - number.count)
        }
    }
}

/// Returns once every line given to `writer` so far is written — through `CallUnderTest`, so a
/// queue that never drains ends at the test's time limit with `neverCameBack`, not with a hung run.
func settle(_ writer: LogFileWriter, sourceLocation: SourceLocation = #_sourceLocation) async {
    let call = CallUnderTest { () async -> Bool in
        await writer.flushed()
        return true
    }
    if await call.value("the log writer's queue draining", sourceLocation: sourceLocation) == nil {
        call.cancel()
    }
}

/// A `FileManager` whose `fileExists(atPath:)` — the writer's check of its file before each write
/// to an open file — can be made to hang, as a call to a volume that does not answer would, until
/// `answer()`.
final class HangingFileManager: FileManager, @unchecked Sendable {
    private let hanging = Mutex(false)
    private let counted = Mutex(0)
    private let gate = DispatchSemaphore(value: 0)

    /// How many calls hung.
    var hangs: Int { counted.withLock { $0 } }

    /// The next `fileExists(atPath:)` hangs until `answer()`.
    func hang() { hanging.withLock { $0 = true } }

    /// Ends a hang (and any to come); a second call does nothing.
    func answer() {
        let wasHanging = hanging.withLock { state in
            defer { state = false }
            return state
        }
        if wasHanging { gate.signal() }
    }

    override func fileExists(atPath path: String) -> Bool {
        if hanging.withLock({ $0 }) {
            counted.withLock { $0 += 1 }
            gate.wait()
        }
        return super.fileExists(atPath: path)
    }
}
