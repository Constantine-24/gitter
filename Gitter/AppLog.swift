import AppKit
import Foundation
import GitCore

/// The writer as GitCore's sink: one `LogLine.entry` per call.
struct FileCommandLog: CommandLog {
    let writer: LogFileWriter
    func record(_ entry: CommandLogEntry) { writer.append(LogLine.entry(entry)) }
}

/// A store's line to the app's log. The app's stamps each line with `LogLine.event(_:at: Date())`.
struct EventLog: Sendable {
    let write: @Sendable (String) -> Void
    static let none = EventLog { _ in }
}

/// The app's diagnostics log (spec §3): `~/Library/Logs/Gitter/gitter.log`, one file writer behind
/// both GitCore's `CommandLog` and the app's own events — the launch header, the windows' opens and
/// closes, and every banner, notice and alert. Built once, at the composition root
/// (`AppModel.windows`), and never under the test host: there is no file at all in a test run, and a
/// harness launch logs to its own scratch folder (`GITTER_LOG_DIR`, DEBUG only).
@MainActor enum AppLog {
    /// Nil under the test host (`TestHost.isRunningTests`): no file is ever opened there. Nil too
    /// for a scripted DEBUG launch without a `GITTER_LOG_DIR` of its own (`writerFolder`).
    static let writer: LogFileWriter? =
        writerFolder(environment: ProcessInfo.processInfo.environment, isRunningTests: TestHost.isRunningTests)
        .map { LogFileWriter(folder: $0) }

    /// Where this process's writer writes, or nil for none: none under the test host, and — a
    /// mechanical guard, not the scripts' discipline (Task 2's review M5) — none for a harness launch
    /// (`DebugLaunchGuard.isScripted`) that names no folder of its own, so it can never write the
    /// user's real log. Otherwise `folder(environment:)`.
    static func writerFolder(environment: [String: String], isRunningTests: Bool) -> URL? {
        guard !isRunningTests else { return nil }
        #if DEBUG
            if DebugLaunchGuard.isScripted(environment), environment["GITTER_LOG_DIR"]?.isEmpty ?? true {
                return nil
            }
        #endif
        return folder(environment: environment)
    }

    /// `~/Library/Logs/Gitter`, or `GITTER_LOG_DIR` in DEBUG when it is set. Makes nothing.
    static func folder(environment: [String: String]) -> URL {
        #if DEBUG
            if let override = environment["GITTER_LOG_DIR"], !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
        #endif
        return URL.libraryDirectory.appending(path: "Logs/Gitter", directoryHint: .isDirectory)
    }

    /// The writer's sink, or `NoCommandLog()`.
    static var commandLog: any CommandLog {
        writer.map { FileCommandLog(writer: $0) } ?? NoCommandLog()
    }

    /// The writer's, or `.none`.
    static var events: EventLog {
        guard let writer else { return .none }
        return EventLog { text in writer.append(LogLine.event(text, at: Date())) }
    }

    /// The launch header: Gitter's version string, the macOS version, and `<gitPath> --version`'s
    /// first line or "git: not available". It runs git off the main actor.
    static func header(info: [String: Any], gitPath: String) async -> String {
        let versions = AboutPanel.versions(info: info)
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let git = await gitVersion(gitPath)
        return "launch: Gitter \(versions.application) (\(versions.build)), macOS \(system), \(git)"
    }

    /// `<gitPath> --version`'s first line, or "git: not available" for any failure.
    private nonisolated static func gitVersion(_ gitPath: String) async -> String {
        do {
            let output = try await ProcessRunner().run(gitPath, ["--version"], cwd: URL(fileURLWithPath: "/"))
            let first = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).first
            let line = first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return line.isEmpty ? "git: not available" : line
        } catch {
            return "git: not available"
        }
    }

    /// Help › Show Logs: the log's folder — created if needed — opened in Finder, or an alert that
    /// says why not.
    static func showLogs() {
        let folder = writer?.fileURL.deletingLastPathComponent()
            ?? folder(environment: ProcessInfo.processInfo.environment)
        showLogs(folder: folder, open: { NSWorkspace.shared.open($0) }) { message in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Gitter couldn't show its logs"
            alert.informativeText = message
            ModalAlert.raise(alert) { _ in }
        }
    }

    /// `showLogs`, with Finder and the alert as seams (internal for tests, which never pass the real
    /// folder): makes `folder`, then opens it; when either fails, `tell` gets one sentence naming it.
    static func showLogs(folder: URL, open: (URL) -> Bool, tell: (String) -> Void) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            tell("The folder \(folder.path) could not be made: \(error.localizedDescription)")
            return
        }
        if !open(folder) { tell("Finder could not open the folder \(folder.path).") }
    }
}
