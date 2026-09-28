import Foundation

/// A stash push, store, apply or drop that git refused or half-did, in the words
/// `BranchRefusalParser` does not know.
public enum StashFailure: Sendable, Hashable {
    /// `f: needs merge` — on **stdout** — then `error: could not write index` (M 13).
    case unmerged([String])
    /// `error: Entry 'n' not uptodate. Cannot merge.` (M 14, A.7).
    case intentToAdd([String])
    /// `u.txt already exists, no checkout` then `error: could not restore untracked files from
    /// stash`: the tracked part of an apply landed and these did not (M 6).
    case untrackedAlreadyExists([String])
    /// `error: '<sha>' is not a stash reference` — drop was given something other than
    /// `stash@{n}` (M 7).
    case notAStashReference
    /// `No stash entries found.` (M 7).
    case noEntries
    /// `Unable to create '…/index.lock': File exists.` — another git is running, or a crashed
    /// one left the lock (M 17, A.5).
    case indexLocked
}

/// Reads `StashFailure` out of git's stdout and stderr.
///
/// Pure and total, like `BranchRefusalParser`: nil for anything it does not recognise, so the
/// caller keeps git's own words. `ProcessRunner` sets `LC_ALL=C`, so the English wording is what
/// git prints, and names arrive raw (no C-style quoting) in these messages.
///
/// When several are present the lock comes first — while it is there nothing else can be
/// fixed — then unmerged and intent-to-add entries, which block everything else.
public enum StashFailureParser {
    public static func parse(stdout: String, stderr: String) -> StashFailure? {
        let lines = (stdout + "\n" + stderr).split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        if lines.contains(where: { $0.contains("index.lock': File exists.") }) {
            return .indexLocked
        }
        let unmerged = lines.compactMap { name(in: $0, prefix: "", suffix: ": needs merge") }
        if !unmerged.isEmpty { return .unmerged(unmerged) }
        let intentToAdd = lines.compactMap {
            name(in: $0, prefix: "error: Entry '", suffix: "' not uptodate. Cannot merge.")
        }
        if !intentToAdd.isEmpty { return .intentToAdd(intentToAdd) }
        let exists = lines.compactMap { name(in: $0, prefix: "", suffix: " already exists, no checkout") }
        if !exists.isEmpty { return .untrackedAlreadyExists(exists) }
        if lines.contains(where: { $0.hasPrefix("error: '") && $0.hasSuffix("' is not a stash reference") }) {
            return .notAStashReference
        }
        if lines.contains("No stash entries found.") { return .noEntries }
        return nil
    }

    /// The text between `prefix` and `suffix` when `line` is exactly that shape. The whole
    /// line is matched, so a quote or a colon inside the name stays part of it.
    private static func name(in line: String, prefix: String, suffix: String) -> String? {
        guard line.hasPrefix(prefix), line.hasSuffix(suffix),
            line.count > prefix.count + suffix.count
        else { return nil }
        return String(line.dropFirst(prefix.count).dropLast(suffix.count))
    }
}
