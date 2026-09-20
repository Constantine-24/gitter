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
///
/// Three consequences of "raw", all verified and all tested:
///
/// - Leading and trailing spaces in a name survive intact (` lead-and-trail .txt` comes back
///   with both spaces), so the only character stripped from a file line is the single leading
///   TAB.
/// - A name containing a **newline** cannot be recovered. git prints it raw, so its second
///   half looks like an unindented line and ends the block — `new\nline.txt` yields `new` and
///   the rest is lost. There is no `-z` or `--porcelain` variant of these messages to escape
///   to. The file list is therefore a best effort for display, never a set of paths to feed
///   back to git.
/// - A block ends at the first line that does not begin with a TAB, which is how the trailing
///   "Please commit your changes…", "Aborting" and "Merge with strategy ort failed." lines
///   stay out of the list.
public enum BranchRefusalParser {
    public static func parse(stderr: String) -> BranchOperationError? {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Every block, not just the first: one `git switch` can print the tracked block AND
        // the untracked block (verified on git 2.54). Returning on the first match would have
        // the user fix the file they were told about, retry, and be refused over the other.
        var tracked: [String] = []
        var untracked: [String] = []
        for (index, line) in lines.enumerated() {
            // Tested first: the untracked header also ends in "would be overwritten by
            // checkout:", so this order is what keeps the two apart.
            if line.contains("untracked working tree files would be overwritten by") {
                untracked += fileList(after: index, in: lines)
            } else if line.contains("would be overwritten by checkout:")
                || line.contains("would be overwritten by merge:") {
                tracked += fileList(after: index, in: lines)
            }
        }
        if !tracked.isEmpty || !untracked.isEmpty {
            return .wouldOverwrite(tracked: tracked, untracked: untracked)
        }

        // A header with no files under it falls through to here and then to nil, so it
        // surfaces as `GitError.commandFailed` with git's own words rather than as an empty
        // file list the UI would render as a blank refusal.
        for line in lines {
            if let operation = operationInProgress(in: line) {
                return .operationInProgress(operation)
            }
            if let name = quotedName(in: line, after: "a branch named ", before: " already exists") {
                return .branchExists(name)
            }
            if let name = quotedName(in: line, after: "fatal: ", before: " is not a valid branch name") {
                return .invalidName(name)
            }
            // Same wording for "the current branch, in this worktree" and "checked out in a
            // linked worktree elsewhere" — git 2.54 does not distinguish them, and neither does
            // Gitter: both make the delete unsafe the same way. Checked before `noSuchBranch`
            // only because it happens to read better here; the two patterns cannot both match
            // one line (their required suffixes differ), so the order does not matter.
            if let name = quotedName(in: line, after: "cannot delete branch ", before: " used by worktree at") {
                return .cannotDeleteCurrent(name)
            }
            if let name = quotedName(in: line, after: "error: branch ", before: " not found") {
                return .noSuchBranch(name)
            }
        }
        return nil
    }

    /// The tab-indented block git writes under a "would be overwritten" header, up to the
    /// first line that is not indented ("Please commit your changes…"). Empty when there are
    /// no indented lines at all.
    private static func fileList(after index: Int, in lines: [String]) -> [String] {
        var files: [String] = []
        for line in lines.dropFirst(index + 1) {
            guard line.hasPrefix("\t") else { break }
            files.append(String(line.dropFirst()))
        }
        return files
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
