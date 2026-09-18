import Foundation

/// Runs an executable asynchronously, capturing stdout and stderr.
///
/// Every invocation is fully non-interactive: `GIT_TERMINAL_PROMPT=0` guarantees git
/// never blocks waiting for credentials, and `LC_ALL=C` keeps output parseable.
public struct ProcessRunner: Sendable {
    public init() {}

    public func run(
        _ executable: String, _ arguments: [String], cwd: URL, allowedExitCodes: Set<Int32> = []
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = cwd

            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["LC_ALL"] = "C"
            env["GIT_OPTIONAL_LOCKS"] = "0"
            process.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            // Drain both pipes on background threads so a chatty stderr can't deadlock stdout.
            let outData = DataCollector()
            let errData = DataCollector()
            stdout.fileHandleForReading.readabilityHandler = { h in outData.append(h.availableData) }
            stderr.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                outData.append(stdout.fileHandleForReading.readDataToEndOfFile())
                errData.append(stderr.fileHandleForReading.readDataToEndOfFile())
                if proc.terminationStatus == 0 || allowedExitCodes.contains(proc.terminationStatus) {
                    continuation.resume(returning: outData.value)
                } else {
                    let message = String(decoding: errData.value, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: GitError.commandFailed(exitCode: proc.terminationStatus, stderr: message))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitError.launchFailed(error.localizedDescription))
            }
        }
    }
}

/// Thread-safe append-only byte buffer used to drain pipes from readability handlers.
private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
