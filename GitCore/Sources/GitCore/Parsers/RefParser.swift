import Foundation

/// Parses the output of
/// `git for-each-ref --format='%(refname)%00%(objectname)%00%(HEAD)%00%(upstream:short)%00%(objecttype)'`
/// into a `RefCollection`.
public enum RefParser {
    private static let localBranchPrefix = "refs/heads/"
    private static let remoteBranchPrefix = "refs/remotes/"
    private static let tagPrefix = "refs/tags/"

    public static func parse(_ data: Data) -> RefCollection {
        let text = String(decoding: data, as: UTF8.self)

        var localBranches: [Branch] = []
        var remoteBranches: [Branch] = []
        var tags: [Tag] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\u{0}", omittingEmptySubsequences: false)
            guard fields.count >= 5 else { continue }

            let refname = String(fields[0])
            let sha = String(fields[1])
            let headMarker = fields[2]
            let upstreamField = String(fields[3])
            let objectType = fields[4]

            if refname.hasPrefix(localBranchPrefix) {
                let name = String(refname.dropFirst(localBranchPrefix.count))
                guard !name.isEmpty else { continue }
                let upstream = upstreamField.isEmpty ? nil : upstreamField
                localBranches.append(
                    Branch(name: name, sha: sha, isHead: headMarker == "*", upstream: upstream)
                )
            } else if refname.hasPrefix(remoteBranchPrefix) {
                let name = String(refname.dropFirst(remoteBranchPrefix.count))
                guard !name.isEmpty else { continue }
                // name is "R/X"; skip only when X (everything after the remote's own
                // first path component) is exactly "HEAD", not merely ending in "/HEAD".
                guard let slashIndex = name.firstIndex(of: "/") else { continue }
                let branchPart = name[name.index(after: slashIndex)...]
                guard branchPart != "HEAD" else { continue }
                remoteBranches.append(
                    Branch(name: name, sha: sha, isHead: headMarker == "*", upstream: nil)
                )
            } else if refname.hasPrefix(tagPrefix) {
                let name = String(refname.dropFirst(tagPrefix.count))
                guard !name.isEmpty else { continue }
                tags.append(Tag(name: name, sha: sha, isAnnotated: objectType == "tag"))
            }
            // Other refs (refs/stash, refs/notes/...) are intentionally skipped.
        }

        localBranches.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        remoteBranches.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        tags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return RefCollection(localBranches: localBranches, remoteBranches: remoteBranches, tags: tags)
    }
}
