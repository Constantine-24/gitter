import Foundation

/// Why a tag name is refused before anything runs — the New Tag sheet's live check and the
/// create's own (B17, RF2).
public enum TagNameProblem: Sendable, Hashable {
    /// No name at all.
    case empty
    /// A name git cannot store: `git check-ref-format refs/tags/<name>` refuses it (`a..b`,
    /// `x.lock`, `a b`, `a~1`, `v1.0^{}`, `x/`, `.x`, `a//b`, `a@{b`, …).
    case invalid
    /// A tag of that name already exists — compared as the file system compares it, so `V1`
    /// beside `v1` is this too (measured on APFS: git refuses it, "tag 'V1' already exists",
    /// and `refs/tags/V1` then resolves to `v1`); and so is a name one path level above or
    /// below an existing tag (`a` beside `a/b`), which git cannot store either. A symbolic ref at
    /// `refs/tags/<name>` — a dangling one too, which no listing shows and `git tag` would write
    /// through onto the branch it names — is this as well (fix round 1).
    case exists
    /// The name of a local branch or the short name of a remote-tracking branch (`origin/x`),
    /// ignoring case. git resolves a short name to the **tag** before the branch (B17: `rebase
    /// main`, `merge main` and `log main` all took the tag), so such a tag silently redirects
    /// every command that names the branch. Also a configured remote's name, ignoring case:
    /// `origin` alone resolves to `refs/remotes/origin/HEAD`, and a tag of that name wins.
    case isBranchName
    /// Seven or more hexadecimal digits, either case: git reads such a name as an abbreviated
    /// object id too, and a tag named like a commit's abbreviation wins over that commit (B17).
    case looksLikeObjectID
    /// `HEAD`, `@` (git's other name for HEAD), a name beginning with `-`, or any root-ref name
    /// ignoring case — only `A`–`Z`, `_`, `-`, ending in `HEAD` (`MERGE_HEAD`, `ORIG_HEAD`, …),
    /// or `AUTO_MERGE`, `BISECT_EXPECTED_REV`, `NOTES_MERGE_PARTIAL`, `NOTES_MERGE_REF`,
    /// `MERGE_AUTOSTASH`. `HEAD` and `-x` pass `check-ref-format` and `git tag` refuses them
    /// (B17); the rest git takes, and then the name means the tag: a tag `MERGE_HEAD` made
    /// Gitter report a merge in a clean repository (fix round 1).
    case reserved
    /// Over 250 bytes: git cannot create the lock file beside it ("File name too long", B17).
    case tooLong
}

/// What `deleteTag` took away, and everything needed to put it back exactly: `restoreTag`
/// recreates `refs/tags/<name>` at `objectID` — for an annotated tag the **tag object**, so the
/// same tag (message, tagger, date) comes back, not a new one (B19, measured).
public struct TagReceipt: Sendable, Hashable {
    public let name: String
    /// What `refs/tags/<name>` held: the tag object for an annotated tag, the commit for a
    /// lightweight one. The recovery hint shows this id.
    public let objectID: String
    /// The commit (or tree, or blob) the tag peeled to — what the notice names.
    public let target: String

    public init(name: String, objectID: String, target: String) {
        self.name = name
        self.objectID = objectID
        self.target = target
    }
}

/// What the server did with one tag push (B20). Never forced: a remote that has another tag of
/// that name is `.rejectedExists`, and nothing in Gitter overwrites it.
public enum TagPushOutcome: Sendable, Hashable {
    /// The remote did not have it and does now (`*` `[new tag]`).
    case pushed
    /// The remote already had this very tag (`=` `[up to date]`).
    case alreadyThere
    /// The remote has a different tag of that name (`!` `[rejected] (already exists)`) — also
    /// when the remote's is an ancestor of ours (measured): tags never fast-forward.
    case rejectedExists
    /// Anything else, in git's words (redacted): a `pre-push` hook or a server hook declining,
    /// `remote.<r>.mirror=true` ("--mirror can't be combined with refspecs"), a local tag that
    /// does not exist. A network failure Gitter can word is thrown as `RemoteOperationError`
    /// instead.
    case failed(gitsWords: String)
}

/// A tag operation Gitter refused, or one whose expected state was gone — nothing changed in
/// any case.
public enum TagOperationError: Error, Sendable, Hashable {
    /// The name was refused before git ran (`createTag`, `restoreTag`, `pushTag`,
    /// `remoteTagID`, `deleteRemoteTag`). `restoreTag` checks `.exists` only: the name was a
    /// tag a moment ago, so the rest describes something the user already had.
    case nameProblem(TagNameProblem)
    /// An object id that is not a full (40 or 64 lower-case hex digits), non-zero id, refused
    /// before git ran. An all-zero or empty expected value makes `update-ref -d` delete
    /// **unconditionally** (B19), and a short one is resolved by git rather than compared.
    case invalidObjectID(String)
    /// The local tag no longer holds the id the sheet showed — moved, or deleted — and was left
    /// as it is: the compare-and-delete refused (B19, RF1).
    case tagMoved(name: String)
    /// The remote's tag no longer holds the id the sheet showed — moved, or deleted — and was
    /// left as it is: the lease was stale (B21, RF1).
    case remoteTagMoved(name: String, remote: String)
    /// The tag is a symbolic ref (`Tag.isSymbolic`) — Gitter neither deletes nor restores one:
    /// a delete that followed it would delete the branch it names (measured), and a restore
    /// could not bring a symbolic ref back. Refused before git runs; nothing changed.
    case symbolicTag(name: String)
}

/// Tags: name checks, create, a compare-and-delete with its restore, and the remote half —
/// reading one remote tag's id, pushing one tag, and a leased remote delete (B17–B21).
///
/// The ninth GitCore protocol. Every vector is pinned whole in `ForceFlagScannerTests`, and
/// user config cannot widen or rewrite one: `--no-sign` with an explicit `-a` (B17:
/// `tag.gpgSign` and `tag.forceSignAnnotated`), `--cleanup=verbatim`, `--no-follow-tags`
/// (B20), full `refs/tags/<name>` refspecs and full object ids (B17), and a full non-zero
/// expected id in every compare-and-delete (B19, B21).
///
/// Failures that are git's own — a hook refusing, a race git caught — are thrown as
/// `GitError.commandFailed` with git's words; nothing was changed by them.
public protocol GitTagBackend: Sendable {
    /// Why `name` cannot be a new tag here, or nil when it can. Checked in this order: `.empty`,
    /// `.reserved`, `.tooLong`, `.invalid`, `.looksLikeObjectID`, `.exists`, `.isBranchName`.
    /// Reads only.
    func tagNameProblem(_ name: String, at root: URL) async throws -> TagNameProblem?

    /// Creates `name` at `sha` (a full object id): lightweight when `message` is nil, annotated
    /// otherwise, with `message` stored as written — `#` lines and blank lines kept — and never
    /// signed. Refuses `TagOperationError.nameProblem` (every `TagNameProblem`) and
    /// `.invalidObjectID` before git runs.
    func createTag(_ name: String, at sha: String, message: String?, at root: URL) async throws

    /// Deletes `tag` only if `refs/tags/<name>` still holds `tag.objectID` — the tag object for
    /// an annotated tag — in one atomic compare-and-delete (B19). `.invalidObjectID` before any
    /// process runs; `.tagMoved` when the tag moved or is gone (nothing deleted).
    func deleteTag(_ tag: Tag, at root: URL) async throws -> TagReceipt

    /// Recreates the deleted tag at `receipt.objectID`: the identical tag object for an
    /// annotated tag (B19). `.nameProblem(.exists)` when a tag of that name exists again;
    /// `.invalidObjectID` for a receipt not made by `deleteTag`.
    func restoreTag(_ receipt: TagReceipt, at root: URL) async throws

    /// `refs/tags/<name>`'s id on `remote` — **unpeeled**: the tag object for an annotated tag,
    /// which is what a lease on it must name (B21) — or nil when the remote has no such tag.
    /// One `ls-remote`, a network round trip.
    func remoteTagID(_ name: String, on remote: String, at root: URL) async throws -> String?

    /// Pushes exactly `refs/tags/<name>` to `remote` (B20): no other tag, whatever
    /// `push.followTags` says, and never forced.
    func pushTag(_ name: String, to remote: String, at root: URL) async throws -> TagPushOutcome

    /// Deletes `refs/tags/<name>` on `remote` only while it still holds `id` (from
    /// `remoteTagID`): a lease (B21). `.remoteTagMoved` when it moved or is gone;
    /// `RemoteOperationError.invalidLease` for an id that is not full and non-zero, before git
    /// runs; a server refusing is git's words (`GitError.commandFailed`).
    func deleteRemoteTag(_ name: String, on remote: String, expecting id: String, at root: URL) async throws

    /// The remotes whose `remote.<name>.tagOpt` is `--no-tags` (git's last value wins), sorted:
    /// a fetch from one of them never brings a deleted tag back (B22, measured through
    /// Gitter's own fetch in `TagFetchOptionTests`). One local config read, no network.
    func remotesFetchingNoTags(at root: URL) async throws -> [String]
}
