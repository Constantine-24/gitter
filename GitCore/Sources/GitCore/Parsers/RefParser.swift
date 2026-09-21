import Foundation

/// Parses the output of
/// `git for-each-ref --format='%(refname)%00%(objectname)%00%(HEAD)%00%(upstream:short)%00%(objecttype)%00%(*objectname)%00%(upstream:track)%00%(upstream:remotename)%00%(upstream:remoteref)'`
/// into a `RefCollection`.
///
/// The sixth `%(*objectname)` field is the *peeled* object: for an annotated tag it is the
/// commit the tag object points at, and it is empty for everything else. The last three are
/// the tracking fields. Every field after the fifth is optional: lines with only the first
/// five, six or eight are still accepted, so output captured before a field was added (and
/// the test fixtures recorded from it) keeps parsing, with the missing fields simply unset.
///
/// `RefParser` knows nothing about which remotes are *configured* — that is `git remote -v`
/// and `RemoteParser` — so the `RefCollection` it returns has none.
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
            let peeled = fields.count >= 6 ? String(fields[5]) : ""
            let trackField = fields.count >= 7 ? fields[6] : nil
            let remoteNameField = fields.count >= 8 ? String(fields[7]) : ""
            let remoteRefField = fields.count >= 9 ? String(fields[8]) : ""

            if refname.hasPrefix(localBranchPrefix) {
                let name = String(refname.dropFirst(localBranchPrefix.count))
                guard !name.isEmpty else { continue }
                let upstream = upstreamField.isEmpty ? nil : upstreamField
                // git reports "." as the remote name when the upstream is another *local*
                // branch. "." is not a remote — `git remote add .` is refused outright — so it
                // is not passed off as one; such a branch has an `upstreamRef` but no
                // `upstreamRemote`, which is what `tracksLocalBranch` reads.
                let upstreamRemote =
                    (remoteNameField.isEmpty || remoteNameField == ".") ? nil : remoteNameField
                localBranches.append(
                    Branch(name: name, sha: sha, isHead: headMarker == "*", upstream: upstream,
                           tracking: Tracking.parse(trackField, hasUpstream: upstream != nil),
                           upstreamRemote: upstreamRemote,
                           upstreamRef: remoteRefField.isEmpty ? nil : remoteRefField)
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
                // An annotated tag's own `objectname` is the tag object, which is no use for
                // pointing at a row in the graph; prefer the commit it peels to.
                tags.append(
                    Tag(name: name, sha: peeled.isEmpty ? sha : peeled, isAnnotated: objectType == "tag")
                )
            }
            // Other refs (refs/stash, refs/notes/...) are intentionally skipped.
        }

        localBranches.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        remoteBranches.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        tags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return RefCollection(localBranches: localBranches, remoteBranches: remoteBranches, tags: tags)
    }
}
