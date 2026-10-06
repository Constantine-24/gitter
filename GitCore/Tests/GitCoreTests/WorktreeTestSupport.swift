import Foundation
import Testing

@testable import GitCore

/// A main worktree at `<base>/main` and room for linked worktrees beside it, all inside one
/// temporary folder of the fixture's own (`base`), which `cleanUp` removes whole. Paths are built
/// from `base` as `FileManager` names it — `/var/folders/…`, where git prints `/private/var/…`
/// (R23) — so every comparison with what git printed goes through `realPath`.
///
/// `main` holds `f.txt` and `g.txt` and a `.gitignore` for `.build/`, `build/` and `*.log`, on
/// `main`. Hooks are looked up in main's `.git/hooks` by absolute path: `TestRepo`'s relative
/// `.git/hooks` would be resolved inside a linked worktree, where `.git` is a file.
struct WorktreeFixture {
    let base: URL
    let repo: TestRepo
    let backend = CLIGitBackend()

    /// `reftable`: the repository is made with `--ref-format=reftable` (B3 final review, I1).
    static func make(reftable: Bool = false) async throws -> WorktreeFixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-wt-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = TestRepo(root: root)
        try await repo.git(["init", "-q", "-b", "main"] + (reftable ? ["--ref-format=reftable"] : []))
        try await repo.git(["config", "user.email", "t@t"])
        try await repo.git(["config", "user.name", "Tester"])
        try await repo.git(["config", "commit.gpgsign", "false"])
        try await repo.git(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
        try repo.write("f.txt", "f\n")
        try repo.write("g.txt", "g\n")
        try repo.write(".gitignore", ".build/\nbuild/\n*.log\n")
        try await repo.commitAll("c1")
        return WorktreeFixture(base: base, repo: repo)
    }

    /// `<base>/<name>`, as `FileManager` spells it (not resolved).
    func path(_ name: String) -> String { base.appendingPathComponent(name).path }

    /// `<base>/<name>` as git prints it: the real path of `base`, then `name`.
    func listedPath(_ name: String) -> String { realPath(base.path) + "/" + name }

    /// `git worktree add -q <base>/<name> <arguments…>`, raw git, from main. Returns the path git
    /// lists it under.
    @discardableResult
    func addRaw(_ name: String, _ arguments: [String]) async throws -> String {
        try await repo.git(["worktree", "add", "-q", path(name)] + arguments)
        return listedPath(name)
    }

    /// A linked worktree on a new branch `branch` from main's tip.
    @discardableResult
    func addOnNewBranch(_ name: String, _ branch: String) async throws -> String {
        try await repo.git(["branch", branch])
        return try await addRaw(name, [branch])
    }

    /// The repository at a worktree's folder.
    func repo(at name: String) -> TestRepo { TestRepo(root: URL(fileURLWithPath: path(name))) }

    /// The worktree Gitter lists at `<base>/<name>`.
    func listed(_ name: String) async throws -> Worktree {
        let all = try await backend.worktrees(at: repo.root)
        return try #require(all.first { $0.path == listedPath(name) }, "not listed: \(name) in \(all.map(\.path))")
    }

    /// Whether git still lists a worktree at `<base>/<name>`.
    func isListed(_ name: String) async throws -> Bool {
        let text = String(decoding: try await repo.git(["worktree", "list", "--porcelain", "-z"]), as: UTF8.self)
        return text.split(separator: "\u{0}").contains { $0 == "worktree " + listedPath(name) }
    }

    func exists(_ relative: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(relative).path, isDirectory: &isDirectory)
    }

    func write(_ relative: String, _ contents: String) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `refs/heads/…` and the id each holds, one per line.
    func branches() async throws -> String {
        String(decoding: try await repo.git(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"]), as: UTF8.self)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }
}

/// `realpath(3)`: what git compares and prints (`/private/var/…`). Foundation's
/// `resolvingSymlinksInPath` strips `/private` instead, so it is not used here.
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A shell script standing in for `/usr/bin/git` that logs every launch's **whole** argument
/// vector (one line, NUL-free, arguments joined by a space) and the `GIT_CONFIG_COUNT` /
/// `KEY_0` / `VALUE_0` / `KEY_1` / `VALUE_1` it was started with, then runs the real git. `GitLaunchLog` keeps only the
/// subcommand, which cannot tell `worktree add` from `worktree list`.
///
/// `beforeRemove`, when given, is a shell command run just before a `worktree remove` is handed
/// to git: the window between Gitter's last check and git's own (R24). `stallAfterAdd` keeps a
/// `worktree add` running for 30 s after git has finished (`addFinished`), so a test can cancel it
/// then: had the cancel not stopped it, the stall would end with exit 0.
struct WorktreeLaunchLog {
    let directory: URL
    var wrapper: URL { directory.appendingPathComponent("git") }
    private var log: URL { directory.appendingPathComponent("log") }

    init(beforeRemove: String? = nil, stallAfterAdd: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-wt-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var script = "#!/bin/sh\n"
        script += "printf '%s | %s %s %s %s %s\\n' \"$*\" \"$GIT_CONFIG_COUNT\" \"$GIT_CONFIG_KEY_0\" \"$GIT_CONFIG_VALUE_0\" \"$GIT_CONFIG_KEY_1\" \"$GIT_CONFIG_VALUE_1\" >> '\(directory.path)/log'\n"
        if let beforeRemove {
            script += "if [ \"$1\" = worktree ] && [ \"$2\" = remove ]; then \(beforeRemove); fi\n"
        }
        if stallAfterAdd {
            script += "if [ \"$1\" = worktree ] && [ \"$2\" = add ]; then /usr/bin/git \"$@\"; touch '\(directory.path)/added'; exec /bin/sleep 30; fi\n"
        }
        script += "exec /usr/bin/git \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    var backend: CLIGitBackend { CLIGitBackend(gitPath: wrapper.path) }

    /// With `stallAfterAdd`: git has finished the `worktree add`, and the stall has begun.
    var addFinished: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("added").path) }

    /// Every launch so far: `<arguments> | <count> <key0> <value0> <key1> <value1>`.
    var launches: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The launches whose arguments begin with `prefix` (`"worktree add"`).
    func launches(startingWith prefix: String) -> [String] {
        launches.filter { $0.hasPrefix(prefix + " ") || $0.hasPrefix(prefix + " |") }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
