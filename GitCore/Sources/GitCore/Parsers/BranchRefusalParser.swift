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
///
/// **One header, two block shapes.** "Your local changes to the following files would be
/// overwritten by merge:" is printed by two different parts of git (verified on git 2.54): the
/// checkout machinery writes one TAB-indented line per file and means it literally, while
/// `merge-ort` writes a single SPACE-indented line with the names joined by spaces and means
/// "the index does not match HEAD" — which it refuses over even for files the merge never
/// touches. The indentation of the line after the header is the only discriminator, and the
/// space-joined form cannot be split back into names (a name with a space in it is
/// indistinguishable from two names), so it becomes `.indexNotClean` with no file list.
public enum BranchRefusalParser {
    public static func parse(stderr: String) -> BranchOperationError? {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Every block, not just the first: one `git switch` can print the tracked block AND
        // the untracked block (verified on git 2.54). Returning on the first match would have
        // the user fix the file they were told about, retry, and be refused over the other.
        var tracked: [String] = []
        var untracked: [String] = []
        var indexNotClean = false
        for (index, line) in lines.enumerated() {
            // Tested first: the untracked header also ends in "would be overwritten by
            // checkout:", so this order is what keeps the two apart.
            if line.contains("untracked working tree files would be overwritten by") {
                untracked += fileList(after: index, in: lines)
            } else if line.contains("would be overwritten by checkout:")
                || line.contains("would be overwritten by merge:") {
                let files = fileList(after: index, in: lines)
                tracked += files
                if files.isEmpty, isSpaceIndented(lines.dropFirst(index + 1).first) {
                    indexNotClean = true
                }
            }
        }
        if !tracked.isEmpty || !untracked.isEmpty {
            return .wouldOverwrite(tracked: tracked, untracked: untracked)
        }
        if indexNotClean { return .indexNotClean }

        // A header with no files under it falls through to here and then to nil, so it
        // surfaces as `GitError.commandFailed` with git's own words rather than as an empty
        // file list the UI would render as a blank refusal.
        for line in lines {
            // `git rebase` over any uncommitted change, related or not (verified on git 2.54).
            // When both kinds are present git prints the unstaged sentence first and adds
            // "additionally, your index contains uncommitted changes." on the next line; either
            // first line is enough.
            if line.contains("cannot rebase: You have unstaged changes.")
                || line.contains("cannot rebase: Your index contains uncommitted changes.") {
                return .treeNotClean
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
            // `git merge nosuch` — verified on git 2.54, the one message in this file whose
            // name is NOT quoted: `merge: nosuch - not something we can merge`.
            if let name = unquotedName(
                in: line, after: "merge: ", before: " - not something we can merge") {
                return .noSuchBranch(name)
            }
        }
        return nil
    }

    /// Whether `line` starts with a space — the one thing that tells `merge-ort`'s
    /// space-joined, space-indented file line apart from the TAB-indented block every other
    /// message in this file uses. Both sit under the identical "Your local changes to the
    /// following files would be overwritten by merge:" header (verified on git 2.54), and only
    /// the indentation says which refusal it is.
    private static func isSpaceIndented(_ line: String?) -> Bool {
        line?.hasPrefix(" ") == true
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
        // `git merge` has two wordings of its own, neither of which mentions switching.
        // `MERGE_HEAD` with a clean index is unambiguously a merge; unmerged entries could
        // belong to a merge, cherry-pick, revert or rebase, so that phrase names the state
        // instead of guessing which operation left them there.
        if line.contains("You have not concluded your merge (MERGE_HEAD exists)") {
            return "merging"
        }
        if line.contains("Merging is not possible because you have unmerged files") {
            return "resolving conflicts"
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

    /// Same idea without the quotes, for `merge`'s "not something we can merge". The line must
    /// *start* with `prefix` — a bare `contains` would let any sentence mentioning "merge: "
    /// through — and `suffix` is found backwards so a name containing " - " survives.
    private static func unquotedName(in line: String, after prefix: String, before suffix: String)
        -> String? {
        guard line.hasPrefix(prefix), let end = line.range(of: suffix, options: .backwards),
            line.index(line.startIndex, offsetBy: prefix.count) < end.lowerBound
        else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: prefix.count)..<end.lowerBound])
    }
}
