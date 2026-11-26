import Foundation

extension CLIGitBackend {
    /// Compare the files on disk with HEAD through a copy of the live index. Keeping its
    /// tracked entries preserves Git's working-copy view. Adding intent-to-add entries to
    /// the copy lets the same diff include untracked files, including a recreation of a
    /// path whose deletion was staged.
    func workingCopyClipboardDiff(at root: URL) async throws -> Data {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let top = try await clipboardExportGitLine(["rev-parse", "--show-toplevel"], at: root)
        guard !top.isEmpty, URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.path else {
            throw ClipboardDiffExportRefusal.sourceChanged
        }
        let liveIndex = try await clipboardExportGitLine(
            ["rev-parse", "--path-format=absolute", "--git-path", "index"], at: root)
        let liveIndexURL = URL(fileURLWithPath: liveIndex)
        let head = try await clipboardExportHead(at: root)
        let baseline = try await clipboardExportBaseline(head: head, at: root)
        let drivers = try await clipboardExportFilterDrivers(at: root)

        return try await withClipboardExportIndex(at: root) { temporaryIndex, environment in
            let original = try Self.copyClipboardExportIndex(from: liveIndexURL, to: temporaryIndex)
            let staged = try await clipboardExportIndexPaths(at: root, environment: environment)
            guard staged.unmerged.isEmpty else {
                throw ClipboardDiffExportRefusal.unsupported(staged.unmerged)
            }
            let nestedDrivers = try await clipboardExportSubmoduleDrivers(staged.gitlinks, at: root)
            var seen = Set<Data>()
            let allDrivers = (drivers + nestedDrivers).filter { seen.insert(Data($0.utf8)).inserted }
            let index = allDrivers.reduce(environment) { environment, driver in
                var disabled = Self.withConfig("filter.\(driver).clean", "", over: environment)
                disabled = Self.withConfig("filter.\(driver).process", "", over: disabled)
                return Self.withConfig("filter.\(driver).required", "false", over: disabled)
            }

            let untracked = try await clipboardExportUntracked(at: root, environment: index)
            var paths: [String] = []
            var blocked: [String] = []
            for bytes in untracked.split(separator: 0) {
                if let path = String(validating: bytes, as: UTF8.self) {
                    if path.hasSuffix("/") { blocked.append(path) }
                    else { paths.append(path) }
                } else {
                    blocked.append(PatchBuilder.quoteGitPath(Array(bytes)))
                }
            }
            guard blocked.isEmpty else { throw ClipboardDiffExportRefusal.unsupported(blocked) }
            if !paths.isEmpty {
                _ = try await withPathspecFile(paths, in: temporaryIndex.deletingLastPathComponent()) { file in
                    try await runWithEnvironment(
                        ["add", "--intent-to-add", "--sparse", "--pathspec-from-file=\(file)", "--pathspec-file-nul"],
                        cwd: root, extra: index)
                }
            }

            let patch = try await runWithEnvironment(
                ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--ignore-submodules=none",
                 "--src-prefix=a/", "--dst-prefix=b/", "--no-relative", "--full-index", "-U3", "-M", "-l0",
                 "--output-indicator-new=+", "--output-indicator-old=-", "--output-indicator-context= ",
                 "--ita-invisible-in-index", baseline, "--"], cwd: root, extra: index)
            // Git can report a false deletion with exit zero when a tracked path is unreadable.
            guard patch.stderr.isEmpty else {
                throw GitError.commandFailed(exitCode: patch.exitCode, stderr: patch.stderr)
            }
            try await refuseClipboardExportFilters(in: patch.stdout, drivers: drivers, environment: index, at: root)
            // Refuse a changed baseline, staging snapshot, or set of untracked paths while
            // the export was reading. Git reads file content on disk during the diff, the
            // same way it does for the on-screen diff.
            guard try await clipboardExportHead(at: root) == head,
                try Self.clipboardExportIndexBytes(at: liveIndexURL) == original,
                try await clipboardExportUntracked(at: root, environment: Self.clipboardExportReadEnvironment()) == untracked
            else { throw ClipboardDiffExportRefusal.sourceChanged }
            return patch.stdout
        }
    }

    /// The shared temporary index and object store used by the working-copy and stash
    /// exports. The real objects are an alternate for reads, including a linked worktree's
    /// common repository. The temporary directory also holds the NUL-separated pathspec.
    func withClipboardExportIndex<T>(
        at root: URL, _ body: (URL, [String: String]) async throws -> T
    ) async throws -> T {
        let objectPath = try await clipboardExportGitLine(
            ["rev-parse", "--path-format=absolute", "--git-path", "objects"], at: root)
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let worktree = root.resolvingSymlinksInPath().standardizedFileURL
        guard temporary.path != worktree.path,
            !temporary.path.utf8.starts(with: (worktree.path + "/").utf8), worktree.path != "/"
        else { throw ClipboardDiffExportRefusal.sourceChanged }

        let directory = temporary.appendingPathComponent("gitter-export-\(UUID().uuidString)", isDirectory: true)
        let objects = directory.appendingPathComponent("objects", isDirectory: true)
        let temporaryIndex = directory.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: false)

        var environment = Self.withConfig("core.splitIndex", "false", over: Self.clipboardExportReadEnvironment())
        environment = Self.withConfig("core.hooksPath", "/dev/null", over: environment)
        environment = Self.withConfig("core.quotePath", "true", over: environment)
        environment = Self.withConfig("diff.suppressBlankEmpty", "false", over: environment)
        environment["GIT_INDEX_FILE"] = temporaryIndex.path
        environment["GIT_OBJECT_DIRECTORY"] = objects.path
        // A quoted alternate can contain a colon, which otherwise separates two paths.
        let quoted = objectPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let alternate = "\"\(quoted)\""
        if let existing = environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"], !existing.isEmpty {
            environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = alternate + ":" + existing
        } else {
            environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = alternate
        }
        return try await body(temporaryIndex, environment)
    }

    private static func clipboardExportReadEnvironment() -> [String: String] {
        var environment = Self.withConfig("core.fsmonitor", "false", over: ProcessInfo.processInfo.environment)
        environment["GIT_NO_LAZY_FETCH"] = "1"
        return environment
    }

    private func clipboardExportIndexPaths(
        at root: URL, environment: [String: String]
    ) async throws -> (unmerged: [String], gitlinks: [String]) {
        let data = try await runWithEnvironment(["ls-files", "--stage", "-z"], cwd: root, extra: environment).stdout
        var unmerged: [String] = []
        var gitlinks: [String] = []
        for record in data.split(separator: 0) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")) else {
                throw ClipboardDiffExportRefusal.sourceChanged
            }
            let header = record[..<tab]
            let isGitlink = header.starts(with: "160000 ".utf8)
            let isUnmerged = header.last != UInt8(ascii: "0")
            guard isGitlink || isUnmerged else { continue }
            let path = record[record.index(after: tab)...]
            let name = String(validating: path, as: UTF8.self)
            if isUnmerged { unmerged.append(name ?? PatchBuilder.quoteGitPath(Array(path))) }
            if isGitlink {
                guard let name else {
                    throw ClipboardDiffExportRefusal.unsupported([PatchBuilder.quoteGitPath(Array(path))])
                }
                gitlinks.append(name)
            }
        }
        return (unmerged, gitlinks)
    }

    /// Git's dirty gitlink check invokes status inside initialized submodules. Its config
    /// overrides are inherited by those status processes, including nested submodules.
    private func clipboardExportSubmoduleDrivers(_ paths: [String], at root: URL) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        let readEnvironment = Self.clipboardExportReadEnvironment()
        let commonPath = try await clipboardExportGitLine(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root)
        let common = URL(fileURLWithPath: commonPath).resolvingSymlinksInPath().path
        var pending = paths
        var seen = Set<Data>()
        var drivers: [String] = []
        while let path = pending.popLast() {
            try Task.checkCancellation()
            guard seen.insert(Data(path.utf8)).inserted else { continue }
            let checkout = root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
            let dotGit = checkout.appendingPathComponent(".git")
            guard checkout.path.utf8.starts(with: (root.path + "/").utf8),
                checkout.resolvingSymlinksInPath().path.utf8.elementsEqual(checkout.path.utf8),
                dotGit.resolvingSymlinksInPath().path.utf8.elementsEqual(dotGit.path.utf8)
            else { throw ClipboardDiffExportRefusal.unsupported([path]) }
            guard FileManager.default.fileExists(atPath: dotGit.path) else { continue }

            let top = try await clipboardExportGitLine(["rev-parse", "--show-toplevel"], at: checkout)
            let gitPath = try await clipboardExportGitLine(["rev-parse", "--absolute-git-dir"], at: checkout)
            let admin = URL(fileURLWithPath: gitPath).resolvingSymlinksInPath().path
            guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path.utf8.elementsEqual(checkout.path.utf8),
                admin.utf8.starts(with: (checkout.path + "/").utf8)
                    || admin.utf8.starts(with: (common + "/").utf8)
            else { throw ClipboardDiffExportRefusal.unsupported([path]) }

            drivers += try await clipboardExportFilterDrivers(at: checkout)
            let nested = try await clipboardExportIndexPaths(at: checkout, environment: readEnvironment)
            pending += nested.gitlinks.map { path + "/" + $0 }
        }
        return drivers
    }

    private func clipboardExportUntracked(at root: URL, environment: [String: String]) async throws -> Data {
        let read = try await runWithEnvironment(
            ["ls-files", "--others", "--exclude-standard", "-z"], cwd: root, extra: environment)
        // Git exits zero when an unreadable directory prevents full enumeration.
        guard read.stderr.isEmpty else {
            throw GitError.commandFailed(exitCode: read.exitCode, stderr: read.stderr)
        }
        return read.stdout
    }

    /// Both intent to add and the working-copy diff can invoke a clean or process filter
    /// even with external diff and text conversion disabled. Override configured drivers
    /// in the temporary commands so their programs cannot write to the source repository.
    private func clipboardExportFilterDrivers(at root: URL) async throws -> [String] {
        let read = try await runWithEnvironment(
            ["config", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process|required)$"],
            cwd: root, extra: Self.clipboardExportReadEnvironment(), allowedExitCodes: [1])
        var seen = Set<Data>()
        return try read.stdout.split(separator: 0).compactMap { key in
            let suffix = key.lastIndex(of: UInt8(ascii: "."))
            guard let suffix, let driver = String(validating: key.dropFirst("filter.".utf8.count).prefix(upTo: suffix), as: UTF8.self)
            else { throw ClipboardDiffExportRefusal.sourceChanged }
            return seen.insert(Data(driver.utf8)).inserted ? driver : nil
        }
    }

    /// Check only paths in the candidate patch. An unchanged filtered file elsewhere in
    /// the tree does not prevent copying a regular change.
    private func refuseClipboardExportFilters(
        in patch: Data, drivers: [String], environment: [String: String], at root: URL
    ) async throws {
        guard !drivers.isEmpty, !patch.isEmpty else { return }
        let names = Set(drivers.map { Data($0.utf8) })
        var seen = Set<Data>()
        let paths = DiffParser.parse(patch).flatMap { [$0.oldPath, $0.newPath].compactMap { $0 } }
            .filter { seen.insert(Data($0.utf8)).inserted }
        guard !paths.isEmpty else { return }
        var blocked: [String] = []
        for batch in Self.pathBatches(paths) {
            let read = try await runWithEnvironment(
                ["check-attr", "-z", "--all", "--"] + batch, cwd: root, extra: environment)
            guard read.stderr.isEmpty else {
                throw GitError.commandFailed(exitCode: read.exitCode, stderr: read.stderr)
            }
            let data = read.stdout
            if data.isEmpty { continue }
            let fields = data.dropLast().split(separator: 0, omittingEmptySubsequences: false)
            guard data.last == 0, fields.count.isMultiple(of: 3) else {
                throw ClipboardDiffExportRefusal.sourceChanged
            }
            for i in stride(from: 0, to: fields.count, by: 3)
            where fields[i + 1].elementsEqual("filter".utf8) && names.contains(fields[i + 2]) {
                blocked.append(String(decoding: fields[i], as: UTF8.self))
            }
        }
        if !blocked.isEmpty { throw ClipboardDiffExportRefusal.unsupported(blocked) }
    }

    private func clipboardExportGitLine(
        _ arguments: [String], at root: URL, allowed: Set<Int32> = []
    ) async throws -> String {
        var bytes = try await runWithEnvironment(
            arguments, cwd: root, extra: Self.clipboardExportReadEnvironment(), allowedExitCodes: allowed).stdout
        if bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
        guard let line = String(data: bytes, encoding: .utf8) else {
            throw ClipboardDiffExportRefusal.sourceChanged
        }
        return line
    }

    private func clipboardExportHead(at root: URL) async throws -> String {
        let head = try await clipboardExportGitLine(["rev-parse", "-q", "--verify", "HEAD"], at: root, allowed: [1])
        guard head.isEmpty || Self.isFullObjectID(head) else { throw ClipboardDiffExportRefusal.sourceChanged }
        return head
    }

    private func clipboardExportBaseline(head: String, at root: URL) async throws -> String {
        guard head.isEmpty else { return head }
        // Git knows the empty tree in its active object format, without an object on disk.
        switch try await clipboardExportGitLine(["rev-parse", "--show-object-format"], at: root) {
        case "sha1": return Self.emptyTree
        case "sha256": return "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"
        default: throw ClipboardDiffExportRefusal.sourceChanged
        }
    }

    /// Git uses the index's modification time to decide whether to check a matching
    /// stat entry's contents. A copy with a newer time could hide a same-size edit.
    private static func copyClipboardExportIndex(from live: URL, to temporary: URL) throws -> Data? {
        guard let file = try clipboardExportIndexFile(at: live) else { return nil }
        try FileManager.default.copyItem(at: file, to: temporary)
        let copied = try temporary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard copied.isRegularFile == true, copied.isSymbolicLink == false else {
            throw ClipboardDiffExportRefusal.sourceChanged
        }
        return try Data(contentsOf: temporary)
    }

    private static func clipboardExportIndexBytes(at url: URL) throws -> Data? {
        try clipboardExportIndexFile(at: url).map { try Data(contentsOf: $0) }
    }

    /// Resolve the live index link before copying it so Git receives a regular private file.
    private static func clipboardExportIndexFile(at url: URL) throws -> URL? {
        let file = url.resolvingSymlinksInPath()
        do {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink == false else {
                throw ClipboardDiffExportRefusal.sourceChanged
            }
            return file
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }
}
