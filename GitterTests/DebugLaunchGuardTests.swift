import Foundation
import Testing

@testable import Gitter

/// B2 Task 6, Step 0 (Ruling 15): a scripted launch — any `GITTER_DEBUG_*` variable set — must
/// never reach the repository the user last had open. Without this guard the app reopened
/// `lastRepositoryPath` (a real repository on the developer's machine), started the automatic
/// fetch on it, and ran the script's steps against whatever had loaded: `GITTER_DEBUG_OPEN` only
/// opened the fixture after that reopen, and a script whose own open failed acted on the real
/// one.
@Suite struct DebugLaunchGuardTests {
    static let fixture = "/private/tmp/gitter-guard-fixture/repo"

    // MARK: - Which launches are scripted

    @Test func aLaunchWithNoDebugVariableIsNotScripted() {
        let env = ["HOME": "/Users/someone", "PATH": "/usr/bin", "GITTER_OTHER": "1"]
        #expect(!DebugLaunchGuard.isScripted(env))
        #expect(DebugLaunchGuard.reopensLastRepository(env))
        #expect(DebugLaunchGuard.startsAutomaticFetch(env))
    }

    /// Every hook variable counts, not only the step lists: a click or a selection acts on the
    /// repository on screen just as a step does.
    @Test(arguments: [
        "GITTER_DEBUG_OPEN", "GITTER_DEBUG_BRANCH_ACTION", "GITTER_DEBUG_THEN",
        "GITTER_DEBUG_CLICK", "GITTER_DEBUG_KEYS", "GITTER_DEBUG_SELECT_PATH",
        "GITTER_DEBUG_APPLY", "GITTER_DEBUG_WINDOW", "GITTER_DEBUG_SNAPSHOT_DIR",
    ])
    func anyDebugVariableMakesTheLaunchScripted(_ name: String) {
        let env = [name: "x", "PATH": "/usr/bin"]
        #expect(DebugLaunchGuard.isScripted(env))
        #expect(!DebugLaunchGuard.reopensLastRepository(env))
        #expect(!DebugLaunchGuard.startsAutomaticFetch(env))
    }

    /// An empty value is still a scripted launch: the variable being there is what says a
    /// harness started the app.
    @Test func anEmptyDebugVariableStillCounts() {
        let env = ["GITTER_DEBUG_THEN": ""]
        #expect(DebugLaunchGuard.isScripted(env))
        #expect(!DebugLaunchGuard.reopensLastRepository(env))
    }

    /// The automatic fetch runs in a scripted launch only when the script asks for its schedule
    /// by name; the reopen stays off even then.
    @Test func theAutomaticFetchRunsOnlyWhenTheScriptAsksForIt() {
        let env = ["GITTER_DEBUG_AUTOFETCH": "5,2", "GITTER_DEBUG_OPEN": Self.fixture]
        #expect(DebugLaunchGuard.startsAutomaticFetch(env))
        #expect(!DebugLaunchGuard.reopensLastRepository(env))
    }

    // MARK: - Whether a step may run

    @Test func aStepRunsOnlyAgainstTheFixture() {
        let env = ["GITTER_DEBUG_OPEN": Self.fixture, "GITTER_DEBUG_THEN": "idle"]
        #expect(DebugLaunchGuard.stepRefusal(root: URL(fileURLWithPath: Self.fixture), env) == nil)
    }

    @Test func aStepIsRefusedAgainstAnotherRepository() throws {
        let env = ["GITTER_DEBUG_OPEN": Self.fixture]
        let real = URL(fileURLWithPath: "/Users/someone/Developer/real")
        let refusal = try #require(DebugLaunchGuard.stepRefusal(root: real, env))
        #expect(refusal.contains("/Users/someone/Developer/real"))
        #expect(refusal.contains(Self.fixture))
    }

    @Test func aStepIsRefusedWithNothingOpen() {
        let env = ["GITTER_DEBUG_OPEN": Self.fixture]
        #expect(DebugLaunchGuard.stepRefusal(root: nil, env) != nil)
    }

    /// No fixture named, or an empty one: there is nothing a step could be checked against, so
    /// none runs — whatever is open.
    @Test(arguments: [nil, ""] as [String?])
    func aStepIsRefusedWithoutAFixture(_ open: String?) {
        var env = ["GITTER_DEBUG_THEN": "idle"]
        env["GITTER_DEBUG_OPEN"] = open
        #expect(DebugLaunchGuard.stepRefusal(root: URL(fileURLWithPath: Self.fixture), env) != nil)
        #expect(DebugLaunchGuard.stepRefusal(root: nil, env) != nil)
    }

    /// A prefix of the fixture's path, or the fixture's parent, is another directory.
    @Test func aPrefixOrParentOfTheFixtureIsAnotherRepository() {
        let env = ["GITTER_DEBUG_OPEN": Self.fixture]
        #expect(DebugLaunchGuard.stepRefusal(root: URL(fileURLWithPath: Self.fixture + "2"), env) != nil)
        #expect(
            DebugLaunchGuard.stepRefusal(
                root: URL(fileURLWithPath: "/private/tmp/gitter-guard-fixture"), env) != nil)
    }

    /// `mktemp -d` answers under `/var/folders/…`, which is a link to `/private/var/folders/…`;
    /// the store keeps the path as it was given. Both spellings of one directory are the fixture,
    /// and so are a trailing slash and a `.` component.
    @Test func theFixtureIsComparedByItsResolvedPath() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "gitter-guard-\(UUID().uuidString)")
        let repo = base.appending(path: "repo")
        let link = base.appending(path: "link")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)

        let env = ["GITTER_DEBUG_OPEN": link.path + "/"]
        #expect(DebugLaunchGuard.stepRefusal(root: repo, env) == nil)
        #expect(DebugLaunchGuard.stepRefusal(root: URL(fileURLWithPath: repo.path + "/./"), env) == nil)
        #expect(DebugLaunchGuard.stepRefusal(root: base, env) != nil)
    }

    // MARK: - The other windows' repositories (E2 Task 4)

    /// `GITTER_DEBUG_ALSO_OPEN` is a colon-separated list of paths; empty parts are no path, and
    /// each is kept with its links resolved.
    @Test func alsoOpenIsAColonSeparatedListOfResolvedPaths() throws {
        #expect(DebugLaunchGuard.alsoOpen([:]).isEmpty)
        #expect(DebugLaunchGuard.alsoOpen(["GITTER_DEBUG_ALSO_OPEN": ""]).isEmpty)
        #expect(DebugLaunchGuard.alsoOpen(["GITTER_DEBUG_ALSO_OPEN": "::"]).isEmpty)
        #expect(
            DebugLaunchGuard.alsoOpen(["GITTER_DEBUG_ALSO_OPEN": "/nonexistent-gitter/a::/nonexistent-gitter/b/./"])
                .map(\.path) == ["/nonexistent-gitter/a", "/nonexistent-gitter/b"])

        let (base, repo, link) = try Self.linkedRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(DebugLaunchGuard.alsoOpen(["GITTER_DEBUG_ALSO_OPEN": link.path]).map(\.path) == [repo.path])
    }

    /// A step may act on a repository `allowed` names, matched through a link; an unlisted one is
    /// refused, the fixture is still allowed, and with no fixture named nothing is.
    @Test func aStepRunsAgainstAnAllowedRepositoryAndNoOther() throws {
        let (base, repo, link) = try Self.linkedRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        let env = ["GITTER_DEBUG_OPEN": Self.fixture, "GITTER_DEBUG_ALSO_OPEN": link.path]
        let allowed = DebugLaunchGuard.alsoOpen(env)

        #expect(DebugLaunchGuard.stepRefusal(root: repo, allowed: allowed, env) == nil)
        #expect(DebugLaunchGuard.stepRefusal(root: link, allowed: allowed, env) == nil)
        #expect(DebugLaunchGuard.stepRefusal(root: URL(fileURLWithPath: Self.fixture), allowed: allowed, env) == nil)
        let refusal = try #require(DebugLaunchGuard.stepRefusal(root: base, allowed: allowed, env))
        #expect(refusal.contains(base.resolvingSymlinksInPath().path))
        #expect(DebugLaunchGuard.stepRefusal(root: nil, allowed: allowed, env) != nil)
        // Without the list the other window's repository is refused, as before.
        #expect(DebugLaunchGuard.stepRefusal(root: repo, allowed: [], env) != nil)
        // No fixture named: nothing runs, whatever is allowed.
        #expect(DebugLaunchGuard.stepRefusal(root: repo, allowed: allowed, ["GITTER_DEBUG_ALSO_OPEN": link.path]) != nil)
    }

    /// `newwindow:<path>` opens only a path `GITTER_DEBUG_ALSO_OPEN` names, matched through a link.
    @Test func aNewWindowOpensOnlyAnAlsoOpenPath() throws {
        let (base, repo, link) = try Self.linkedRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        let env = ["GITTER_DEBUG_OPEN": Self.fixture, "GITTER_DEBUG_ALSO_OPEN": link.path]

        #expect(DebugLaunchGuard.newWindowRefusal(repo.path, env) == nil)
        #expect(DebugLaunchGuard.newWindowRefusal(link.path + "/", env) == nil)
        let refusal = try #require(DebugLaunchGuard.newWindowRefusal(base.path, env))
        #expect(refusal.contains("GITTER_DEBUG_ALSO_OPEN"))
        #expect(DebugLaunchGuard.newWindowRefusal(Self.fixture, env) != nil, "the fixture is not listed")
        #expect(DebugLaunchGuard.newWindowRefusal("", env) != nil)
        #expect(DebugLaunchGuard.newWindowRefusal(repo.path, ["GITTER_DEBUG_OPEN": Self.fixture]) != nil)
    }

    /// A real directory `repo` and a link to it, `link`, in a fresh temporary `base`.
    static func linkedRepo() throws -> (base: URL, repo: URL, link: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "gitter-guard-\(UUID().uuidString)")
        let repo = base.appending(path: "repo")
        let link = base.appending(path: "link")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        return (base, repo.resolvingSymlinksInPath(), link)
    }

    // MARK: - What is opened (final review M4)

    /// An empty `GITTER_DEBUG_OPEN` behaves as an unset one: nothing is opened — it used to open
    /// `URL(fileURLWithPath: "")`, the working directory, which from the checkout is the
    /// developer's own repository — and every step is refused (above).
    @Test(arguments: [nil, ""] as [String?])
    func anEmptyOrMissingFixtureOpensNothing(_ open: String?) {
        var env = ["GITTER_DEBUG_THEN": "idle"]
        env["GITTER_DEBUG_OPEN"] = open
        #expect(DebugLaunchGuard.fixtureToOpen(env) == nil)
    }

    @Test func aNamedFixtureIsOpened() {
        #expect(DebugLaunchGuard.fixtureToOpen(["GITTER_DEBUG_OPEN": Self.fixture]) == Self.fixture)
    }

    // MARK: - Open Recent (B3 Ruling 7)

    /// A scripted launch opens scratch fixtures; each `open(_:)` used to add one to the user's
    /// Open Recent list, which lives outside the defaults, so no `cmp` of them could see it. A
    /// harness run leaves that list alone; an ordinary launch still records what it opens.
    @Test func onlyAnUnscriptedLaunchNotesRecentDocuments() {
        #expect(DebugLaunchGuard.notesRecentDocuments(["HOME": "/Users/someone", "GITTER_OTHER": "1"]))
        #expect(!DebugLaunchGuard.notesRecentDocuments(["GITTER_DEBUG_OPEN": Self.fixture]))
        #expect(!DebugLaunchGuard.notesRecentDocuments(["GITTER_DEBUG_THEN": ""]))
        #expect(!DebugLaunchGuard.notesRecentDocuments(["GITTER_DEBUG_SNAPSHOT_DIR": "/tmp/x"]))
    }
}
