import Foundation

/// What the sidebar's Recent section needs: which branches HEAD was switched to, and how fresh
/// each local branch's tip is.
public struct BranchActivity: Sendable, Hashable {
    /// Switch targets from the HEAD reflog, newest first, deduplicated by the parser
    /// (`ReflogSwitchParser`), as git wrote them (not yet checked against existing branches).
    public let switchTargets: [String]
    /// Committer date of each local branch's tip, by short name.
    public let tipDates: [String: Date]

    public static let none = BranchActivity(switchTargets: [], tipDates: [:])

    public init(switchTargets: [String], tipDates: [String: Date]) {
        self.switchTargets = switchTargets
        self.tipDates = tipDates
    }
}

/// Reads the reflog subjects (`%gs`) `branchActivity` asks for.
public enum ReflogSwitchParser {
    /// The `<B>` of every `checkout: moving from <A> to <B>` subject, in the order given (git's:
    /// newest first), each name once. `<B>` is the text after the last ` to ` (a branch name has
    /// no space). Any other subject (commit, rebase, gpg output) is skipped; a detached target
    /// (`HEAD~0`, a sha) is kept here, as written, for the caller to check against real branches.
    public static func targets(_ text: String) -> [String] {
        let prefix = "checkout: moving from "
        var seen = Set<String>()
        var targets: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix(prefix), let to = line.range(of: " to ", options: .backwards) else { continue }
            let target = String(line[to.upperBound...])
            guard !target.isEmpty, seen.insert(target).inserted else { continue }
            targets.append(target)
        }
        return targets
    }
}
