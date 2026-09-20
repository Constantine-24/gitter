import Foundation

/// Turns git's stderr for a refused branch operation into a `BranchOperationError`.
///
/// Pure and total: it never runs anything and returns nil for anything it does not recognise,
/// so the caller falls back to `GitError.commandFailed` with git's own words. `ProcessRunner`
/// sets `LC_ALL=C`, so the English wording below is what git always prints.
///
/// **File names arrive raw.** Verified on git 2.54: unlike diff headers and `status` without
/// `-z`, these messages do *not* apply `quote_c_style` — a name with a space, a double quote
/// or a non-ASCII byte is printed byte for byte, even with `core.quotepath=true`. So nothing
/// here unquotes, and `DiffParser.unquoteIfNeeded` is deliberately not used: a file genuinely
/// named `"quoted".txt` would be mangled by it.
public enum BranchRefusalParser {
    public static func parse(stderr: String) -> BranchOperationError? {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for (index, line) in lines.enumerated() {
            // The untracked variant is tested first: its text also ends in "would be
            // overwritten by checkout:", so the order of these two checks is what keeps them
            // apart.
            if line.contains("untracked working tree files would be overwritten by") {
                if let files = fileList(after: index, in: lines) {
                    return .untrackedWouldBeOverwritten(files: files)
                }
                continue
            }
            if line.contains("would be overwritten by checkout:")
                || line.contains("would be overwritten by merge:") {
                if let files = fileList(after: index, in: lines) {
                    return .wouldOverwrite(files: files)
                }
                continue
            }
            if let operation = operationInProgress(in: line) {
                return .operationInProgress(operation)
            }
            if let name = quotedName(in: line, after: "a branch named ", before: " already exists") {
                return .branchExists(name)
            }
            if let name = quotedName(in: line, after: "fatal: ", before: " is not a valid branch name") {
                return .invalidName(name)
            }
        }
        return nil
    }

    /// The tab-indented block git writes under a "would be overwritten" header, up to the
    /// first line that is not indented ("Please commit your changes…"). Nil when there are no
    /// indented lines at all: a header with no files is not something worth reporting as a
    /// typed error.
    private static func fileList(after index: Int, in lines: [String]) -> [String]? {
        var files: [String] = []
        for line in lines.dropFirst(index + 1) {
            guard line.hasPrefix("\t") else { break }
            files.append(String(line.dropFirst()))
        }
        return files.isEmpty ? nil : files
    }

    /// git spells four of these as "cannot switch branch while <gerund>" and the fifth as
    /// "cannot switch branch in the middle of an am session". The returned phrase always
    /// completes "while …", so the caller can build one sentence for all five.
    private static func operationInProgress(in line: String) -> String? {
        if line.contains("cannot switch branch in the middle of an am session") {
            return "applying patches"
        }
        guard let range = line.range(of: "cannot switch branch while ") else { return nil }
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// The text inside the single quotes between `prefix` and `suffix`, as git writes names in
    /// these messages. A name may itself contain a quote, so the closing quote is located from
    /// `suffix` backwards rather than by scanning forwards.
    private static func quotedName(in line: String, after prefix: String, before suffix: String)
        -> String? {
        guard let start = line.range(of: prefix), let end = line.range(of: suffix, options: .backwards),
            start.upperBound <= end.lowerBound
        else { return nil }
        let middle = line[start.upperBound..<end.lowerBound]
        guard middle.hasPrefix("'"), middle.hasSuffix("'"), middle.count >= 2 else { return nil }
        return String(middle.dropFirst().dropLast())
    }
}
