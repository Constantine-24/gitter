import Foundation
import GitCore

/// The words of the app's log (spec §3, "The file"): one line per event, each starting with an ISO
/// 8601 local time with milliseconds and the offset, and a git call's stderr on the lines after its
/// own, indented by four spaces. Every text is escaped (`escape`), so nothing a text holds — a
/// newline in a banner, a control character in git's words — can start a line of its own.
enum LogLine {
    /// "2026-10-11T10:08:38.264+04:00 <text>", with `escape` applied to `text`.
    static func event(_ text: String, at date: Date) -> String {
        "\(time(date)) \(escape(text))"
    }

    /// "<time> git <0.012s> <directory>: <arguments> → <outcome>", and stderr as continuation lines
    /// indented by four spaces, each line escaped.
    static func entry(_ entry: CommandLogEntry) -> String {
        let arguments = entry.arguments.map(quoted).joined(separator: " ")
        let first = "\(time(entry.started)) git \(seconds(entry.duration)) \(entry.directory): \(arguments) → "
            + words(entry.outcome)
        var lines = [escape(first)]
        if let stderr = entry.stderr {
            // At each "\n" scalar: a "\r\n" is one `Character`, which a split by characters would
            // not break at, and its "\r" is escaped like any other.
            var stderrLines = stderr.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            while stderrLines.last?.isEmpty == true { stderrLines.removeLast() }
            lines += stderrLines.map { "    " + escape(String(String.UnicodeScalarView($0))) }
        }
        return lines.joined(separator: "\n")
    }

    /// \n \r \t → "\\n" "\\r" "\\t"; other C0 controls and U+007F → "\\u{XX}"; everything else kept.
    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{0}"..."\u{1F}", "\u{7F}":
                escaped += "\\u{" + String(format: "%02X", scalar.value) + "}"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// An argument with a space, a quote or nothing in it is single-quoted, with ' as '\''.
    static func quoted(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" }) else {
            return argument
        }
        return "'" + argument.replacing("'", with: #"'\''"#) + "'"
    }

    /// `date` in `timeZone`: "2026-10-11T10:08:38.264+04:00", to the nearest millisecond, the
    /// offset always as ±hh:mm (UTC too, never "Z").
    static func time(_ date: Date, in timeZone: TimeZone = .current) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let whole = Date(timeIntervalSince1970: (milliseconds / 1000).rounded(.down))
        let fraction = Int(milliseconds - (milliseconds / 1000).rounded(.down) * 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        let offset = timeZone.secondsFromGMT(for: whole)
        let sign = offset < 0 ? "-" : "+"
        let minutes = abs(offset) / 60
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d%@%02d:%02d", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, fraction, sign,
            minutes / 60, minutes % 60)
    }

    /// "0.012s".
    private static func seconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.3fs", Double(seconds) + Double(attoseconds) / 1e18)
    }

    private static func words(_ outcome: CommandLogEntry.Outcome) -> String {
        switch outcome {
        case .succeeded: "ok"
        case .exitCode(let code): "exit \(code)"
        case .killed: "killed"
        case .launchFailed(let message): "launch failed: \(message)"
        case .cancelled: "cancelled"
        case .refusedBeforeLaunch(let message): "refused before launch: \(message)"
        }
    }
}
