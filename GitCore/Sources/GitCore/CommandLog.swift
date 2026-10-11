import Foundation

/// Where `CLIGitBackend` reports each git call it ran, once, after it ended. Called on whatever
/// thread the call ended on; an implementation must not block.
public protocol CommandLog: Sendable {
    func record(_ entry: CommandLogEntry)
}

/// The default: records nothing.
public struct NoCommandLog: CommandLog {
    public init() {}
    public func record(_ entry: CommandLogEntry) {}
}

public struct CommandLogEntry: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// `run`'s success: an exit of 0 or of an allowed code, which `run` does not tell apart.
        case succeeded
        /// The code the streaming seams returned, or the one a `GitError.commandFailed` carries.
        case exitCode(Int32)
        /// A git ended by a signal (`CLIGitBackend.wasKilledBySignal`).
        case killed
        case launchFailed(String)
        case cancelled
        /// Thrown before git was launched (`GitError.tooManyArguments`).
        case refusedBeforeLaunch(String)
    }

    public let started: Date
    public let duration: Duration
    public let directory: String
    /// Redacted (`RemoteFailureParser.redactingCredentials`, one argument at a time); more than
    /// `argumentThreshold` are cut to the first `argumentsShown` plus "… and N more".
    public let arguments: [String]
    public let outcome: Outcome
    /// For an outcome other than `.succeeded` and `.exitCode(0)` only: git's stderr, redacted, cut to
    /// at most `stderrLimit` UTF-8 bytes on a character boundary, with "…" appended when cut. Nil when
    /// empty.
    public let stderr: String?

    public static let argumentThreshold = 40
    public static let argumentsShown = 20
    public static let stderrLimit = 2048

    /// Applies the redaction and the cuts. The only initializer.
    public init(started: Date, duration: Duration, directory: URL, rawArguments: [String],
                outcome: Outcome, rawStderr: String) {
        self.started = started
        self.duration = duration
        self.directory = directory.path
        self.arguments = Self.shown(rawArguments)
        self.outcome = Self.shown(outcome)
        switch outcome {
        case .succeeded, .exitCode(0):
            self.stderr = nil
        default:
            self.stderr = Self.shown(stderr: rawStderr)
        }
    }

    /// `arguments` redacted one at a time; over `argumentThreshold`, only the first
    /// `argumentsShown` of them (redacted — the rest are never looked at) and a count of the rest.
    static func shown(_ arguments: [String]) -> [String] {
        guard arguments.count > argumentThreshold else {
            return arguments.map(RemoteFailureParser.redactingCredentials)
        }
        return arguments.prefix(argumentsShown).map(RemoteFailureParser.redactingCredentials)
            + ["… and \(arguments.count - argumentsShown) more"]
    }

    /// The outcome's own strings (a launch failure's message, a refusal's description) redacted and
    /// cut like stderr, so no field carries a raw credential.
    static func shown(_ outcome: Outcome) -> Outcome {
        switch outcome {
        case .launchFailed(let message): .launchFailed(shown(stderr: message) ?? "")
        case .refusedBeforeLaunch(let message): .refusedBeforeLaunch(shown(stderr: message) ?? "")
        default: outcome
        }
    }

    /// `stderr` redacted and cut to `stderrLimit` UTF-8 bytes on a character boundary, "…" after a
    /// cut; nil when empty.
    static func shown(stderr: String) -> String? {
        let redacted = RemoteFailureParser.redactingCredentials(stderr)
        guard !redacted.isEmpty else { return nil }
        guard redacted.utf8.count > stderrLimit else { return redacted }
        var kept = ""
        var bytes = 0
        for character in redacted {
            let size = character.utf8.count
            if bytes + size > stderrLimit { break }
            kept.append(character)
            bytes += size
        }
        return kept + "…"
    }
}
