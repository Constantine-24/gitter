import Foundation

/// Parses the output of `git for-each-ref` with the fifteen-field format
/// `%(refname) %(objectname) %(HEAD) %(upstream:short) %(objecttype) %(*objectname)`
/// `%(upstream:track) %(upstream:remotename) %(upstream:remoteref)`
/// `%(symref) %(push:remotename) %(push:remoteref)`
/// `%(taggername) %(taggerdate:iso-strict) %(contents:subject)`, NUL-separated, into a
/// `RefCollection`.
///
/// The sixth `%(*objectname)` field is the *peeled* object: for an annotated tag it is the
/// commit the tag object points at — through a tag of a tag, all the way (B18) — and it is
/// empty for everything else. Fields 7–9 say where the branch fetches from, 11–12 where it
/// pushes to — two different things (see `Branch.pushRemote`) — and field 10 is `%(symref)`,
/// which is non-empty exactly for a symbolic ref. Fields 13–15 are read for an annotated tag
/// only: a lightweight tag has no tagger, and its `%(contents:subject)` is the commit's
/// subject, not the tag's (B18).
///
/// Every field after the fifth is optional: a line with only the first five, six, nine, eleven
/// or twelve is still accepted, so output captured before a field was added (and the test
/// fixtures recorded from it) keeps parsing, with the missing fields simply unset.
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
            let symrefField = fields.count >= 10 ? String(fields[9]) : nil
            let pushRemoteField = fields.count >= 11 ? String(fields[10]) : ""
            let pushRefField = fields.count >= 12 ? String(fields[11]) : ""
            let taggerField = fields.count >= 13 ? String(fields[12]) : ""
            let taggerDateField = fields.count >= 14 ? String(fields[13]) : ""
            let subjectField = fields.count >= 15 ? String(fields[14]) : nil

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
                let pushRemote =
                    (pushRemoteField.isEmpty || pushRemoteField == ".") ? nil : pushRemoteField
                localBranches.append(
                    Branch(name: name, sha: sha, isHead: headMarker == "*", upstream: upstream,
                           tracking: Tracking.parse(trackField, hasUpstream: upstream != nil),
                           upstreamRemote: upstreamRemote,
                           upstreamRef: remoteRefField.isEmpty ? nil : remoteRefField,
                           pushRemote: pushRemote,
                           pushRef: pushRefField.isEmpty ? nil : pushRefField)
                )
            } else if refname.hasPrefix(remoteBranchPrefix) {
                let name = String(refname.dropFirst(remoteBranchPrefix.count))
                // A remote-tracking branch is always "<remote>/<branch>".
                guard let slashIndex = name.firstIndex(of: "/") else { continue }
                if let symrefField {
                    // `<remote>/HEAD` is a *symbolic* ref, and git says so outright — which is
                    // the only reliable test: guessing from the name ("is everything after the
                    // first slash exactly HEAD?") lets `up/stream/HEAD` through for a remote
                    // whose own name contains a slash, and hides a non-symbolic ref that
                    // merely happens to be called HEAD, along with the commits it holds.
                    guard symrefField.isEmpty else { continue }
                } else {
                    // Output recorded before `%(symref)` was in the format: fall back to the
                    // name, which is right for every single-component remote name.
                    guard name[name.index(after: slashIndex)...] != "HEAD" else { continue }
                }
                remoteBranches.append(
                    Branch(name: name, sha: sha, isHead: headMarker == "*", upstream: nil)
                )
            } else if refname.hasPrefix(tagPrefix) {
                let name = String(refname.dropFirst(tagPrefix.count))
                guard !name.isEmpty else { continue }
                // An annotated tag's own `objectname` is the tag object, which is no use for
                // pointing at a row in the graph; prefer the commit it peels to. The tag object
                // is kept as `objectID`: it is what the ref holds, and what a compare-and-delete
                // names (B19).
                let isAnnotated = objectType == "tag"
                tags.append(
                    Tag(name: name, sha: peeled.isEmpty ? sha : peeled, isAnnotated: isAnnotated,
                        objectID: sha,
                        tagger: isAnnotated && !taggerField.isEmpty ? taggerField : nil,
                        date: isAnnotated ? Self.date(taggerDateField) : nil,
                        subject: isAnnotated ? subjectField : nil,
                        isSymbolic: !(symrefField ?? "").isEmpty)
                )
            }
            // Other refs (refs/stash, refs/notes/...) are intentionally skipped.
        }

        localBranches.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        remoteBranches.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        tags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return RefCollection(localBranches: localBranches, remoteBranches: remoteBranches, tags: tags)
    }

    /// `%(taggerdate:iso-strict)` — `2023-11-16T02:00:00Z` or `…+04:00` — or nil when empty
    /// (a tag object written without a tagger line) or unreadable.
    ///
    /// One shared, `Sendable` style rather than an `ISO8601DateFormatter` per tag (fix round 1:
    /// measured ~0.8 µs a parse against ~120 µs for a new formatter). It reads git's
    /// `iso-strict` shapes exactly as that formatter did (`RefParserTests.taggerDatesParse`); it
    /// would also take fractional seconds, which git never prints there.
    private static func date(_ field: String) -> Date? {
        guard !field.isEmpty else { return nil }
        return try? taggerDateStyle.parse(field)
    }

    private static let taggerDateStyle = Date.ISO8601FormatStyle()
}
