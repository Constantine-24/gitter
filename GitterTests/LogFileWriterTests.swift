import Foundation
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
/// Every writer here writes inside its own temporary folder.
@Suite struct LogFileWriterTests {

    @Test func linesComeBackInOrderAfterAFlush() throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url)
        writer.append("one")
        writer.append("two words")
        writer.append("three")
        writer.flush()

        #expect(writer.fileURL == folder.url.appending(path: "gitter.log"))
        #expect(try folder.lines() == ["one", "two words", "three"])
        #expect(!writer.hasStopped)
    }

    /// Seventy lines of 100 bytes each (the newline included) at a limit of 1 000: ten lines a
    /// file, six rotations. Five files are kept — `gitter.log` with the newest ten, then
    /// `gitter.1.log` … `gitter.4.log` going back — and the oldest twenty lines are gone.
    @Test func theFileRotatesAtTheLimitKeepingFiveFiles() throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url, limit: 1_000)
        let written = Self.hundredByteLines(70)
        for line in written { writer.append(line) }
        writer.flush()

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
    @Test func theRotationCheckCanFail() throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url, limit: 1_000)
        for line in Self.hundredByteLines(70) { writer.append(line) }
        writer.flush()
        let rotated = try folder.names().filter { $0 != "gitter.log" }.count
        withKnownIssue("five files are kept, so four are rotated, not six") {
            #expect(rotated == 6)
        }
    }

    @Test func aFolderThatCannotBeMadeStopsTheWriterWithoutThrowing() throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.parent, withIntermediateDirectories: true)
        // A plain file where a folder above the log's would have to be.
        let plain = folder.parent.appending(path: "plain")
        try Data("not a folder".utf8).write(to: plain)
        let writer = LogFileWriter(folder: plain.appending(path: "logs"))

        writer.append("first")
        writer.flush()
        #expect(writer.hasStopped)
        writer.append("second")
        writer.flush()
        #expect(writer.hasStopped)
        #expect(!FileManager.default.fileExists(atPath: plain.appending(path: "logs").path))
        #expect(try Data(contentsOf: plain) == Data("not a folder".utf8))
    }

    /// RF2: the log's folder deleted while the app runs (the user cleaning up) is made again, with
    /// a new `gitter.log`, at the next line.
    @Test func aDeletedFolderIsMadeAgainAtTheNextLine() throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url)
        writer.append("before")
        writer.flush()
        #expect(try folder.lines() == ["before"])

        try FileManager.default.removeItem(at: folder.url)
        writer.append("after")
        writer.flush()

        #expect(try folder.lines() == ["after"])
        #expect(!writer.hasStopped)
    }

    /// RF1: eight threads appending at once lose no line, tear none and duplicate none, and each
    /// thread's lines stay in its own order.
    @Test func appendsFromManyThreadsAreEachOneWholeLine() throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let writer = LogFileWriter(folder: folder.url)
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for index in 0..<200 { writer.append("thread \(thread) line \(index) " + String(repeating: "x", count: 40)) }
        }
        writer.flush()

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
    /// rotating the same folder can still race: docs/BACKLOG.md.)
    @Test func twoWritersOnOneFileOverwriteNothing() throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        let one = LogFileWriter(folder: folder.url)
        let two = LogFileWriter(folder: folder.url)
        one.append("one first")
        one.flush()
        two.append("two first")
        two.flush()
        one.append("one second")
        one.flush()
        #expect(try folder.lines() == ["one first", "two first", "one second"])
    }

    /// `count` distinct lines of 99 characters: 100 bytes each with the newline.
    static func hundredByteLines(_ count: Int) -> [String] {
        (1...count).map { index in
            let number = String(format: "%03d ", index)
            return number + String(repeating: "x", count: 99 - number.count)
        }
    }
}
