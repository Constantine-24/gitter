import Darwin
import Foundation

extension CLIGitBackend {
    public func planClipboardPatch(_ text: String, at root: URL) async throws -> ClipboardPatchPlan {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        return try await withClipboardPatchFile(text, outside: root) { data, file in
            try await checkedClipboardPatch(text, data: data, file: file, at: root)
        }
    }

    public func applyClipboardPatch(_ plan: ClipboardPatchPlan, at root: URL) async throws {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard root == plan.root else { throw ClipboardPatchRefusal.changedSinceShown }
        try await withClipboardPatchFile(plan.text, outside: root) { data, file in
            let current = try await checkedClipboardPatch(plan.text, data: data, file: file, at: root)
            guard current == plan else { throw ClipboardPatchRefusal.changedSinceShown }
            try Task.checkCancellation()
            // The same file and options as --check. Git checks every hunk again before
            // writing the worktree. Another process can still race the last process launch.
            _ = try await clipboardApply(.write, file: file, at: root)
        }
    }

    private static let clipboardLocalEnvironment = ["GIT_NO_LAZY_FETCH": "1"]

    private enum ClipboardApply {
        case numstat, check, write
    }

    // Keep the complete vectors literal for the safety scanner. These pins override
    // the user's apply policy without changing the repository or global configuration.
    private func clipboardApply(_ operation: ClipboardApply, file: URL, at root: URL) async throws -> Data {
        switch operation {
        case .numstat:
            try await runWithEnvironment(
                ["-c", "apply.ignoreWhitespace=no", "-c", "core.protectHFS=true", "-c", "core.protectNTFS=true",
                 "apply", "--whitespace=nowarn", "--numstat", "-z", "--", file.path],
                cwd: root, extra: Self.clipboardLocalEnvironment).stdout
        case .check:
            try await runWithEnvironment(
                ["-c", "apply.ignoreWhitespace=no", "-c", "core.protectHFS=true", "-c", "core.protectNTFS=true",
                 "apply", "--whitespace=nowarn", "--check", "--", file.path],
                cwd: root, extra: Self.clipboardLocalEnvironment).stdout
        case .write:
            // The caller checks cancellation before authorizing the write. Once launched,
            // allow Git to finish writing even if the caller's task is cancelled.
            try await Task {
                try await runWithEnvironment(
                    ["-c", "apply.ignoreWhitespace=no", "-c", "core.protectHFS=true", "-c", "core.protectNTFS=true",
                     "apply", "--whitespace=nowarn", "--", file.path],
                    cwd: root, extra: Self.clipboardLocalEnvironment).stdout
            }.value
        }
    }

    private func withClipboardPatchFile<T>(
        _ text: String, outside root: URL, _ body: (Data, URL) async throws -> T
    ) async throws -> T {
        let data = Data(text.utf8)
        guard data.starts(with: "diff --git ".utf8), data.last == UInt8(ascii: "\n"), !data.contains(0)
        else { throw ClipboardPatchRefusal.invalidPatch }

        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard temporary.path != root.path, !temporary.path.utf8.starts(with: (root.path + "/").utf8), root.path != "/"
        else { throw ClipboardPatchRefusal.unsafePath(temporary.path) }
        let directory = temporary.appendingPathComponent("gitter-clipboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("patch")
        try data.write(to: file)
        return try await body(data, file)
    }

    private func checkedClipboardPatch(
        _ text: String, data: Data, file: URL, at root: URL
    ) async throws -> ClipboardPatchPlan {
        let top = try await clipboardGitLine(["rev-parse", "--show-toplevel"], at: root)
        guard !top.isEmpty, URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.path
        else { throw ClipboardPatchRefusal.changedSinceShown }
        let gitDirectory = URL(fileURLWithPath: try await clipboardGitLine(
            ["rev-parse", "--absolute-git-dir"], at: root)).resolvingSymlinksInPath()
        let gitCommonDirectory = URL(fileURLWithPath: try await clipboardGitLine(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root)).resolvingSymlinksInPath()

        async let headRead = clipboardGitLine(["rev-parse", "-q", "--verify", "HEAD^{commit}"], at: root, allowed: [1])
        async let referenceRead = clipboardGitLine(["symbolic-ref", "-q", "HEAD"], at: root, allowed: [1])
        async let unmergedRead = run(["ls-files", "--unmerged", "-z"], cwd: root)
        try await refuseClipboardOperation(at: root, gitDirectory: gitDirectory)
        let unmerged = try await unmergedRead
        guard unmerged.isEmpty else { throw ClipboardPatchRefusal.operationInProgress }
        let (head, symbolicHead) = try await (headRead, referenceRead)
        guard Self.isFullObjectID(head) || (head.isEmpty && symbolicHead.hasPrefix("refs/heads/"))
        else { throw ClipboardPatchRefusal.changedSinceShown }

        let numstat: Data
        do {
            numstat = try await clipboardApply(.numstat, file: file, at: root)
        } catch GitError.commandFailed {
            throw ClipboardPatchRefusal.invalidPatch
        }
        let sections = try ClipboardPatchParser.parse(data, numstat: numstat)
        let paths = sections.map { $0.file.path }
        let administrativePaths = [gitDirectory.path, gitCommonDirectory.path] + [
            try await clipboardGitLine(["rev-parse", "--path-format=absolute", "--git-path", "index"], at: root)
        ]
        try Self.refuseClipboardAdministrativePaths(paths, under: root, administrative: administrativePaths)
        let locations = try paths.map { try Self.clipboardWorktreeInfo($0, at: root) }
        try Self.refuseChangingClipboardAttributes(paths)
        try await refuseClipboardConversions(on: paths, at: root)

        // Read names without pathspec filtering. Git's literal pathspecs are case-sensitive,
        // so an absent staged deletion "Foo" would be invisible to a lookup for "foo".
        async let indexRead = clipboardEntries(["ls-files", "--stage", "-v", "-z"], relevantTo: paths, at: root)
        async let treeRead = head.isEmpty ? ClipboardEntries() : clipboardEntries(
            ["ls-tree", "-r", "-z", "--full-tree", head], relevantTo: paths, at: root)
        let (index, tree) = try await (indexRead, treeRead)

        var images: [ClipboardPatchPlan.Preimage?] = []
        for (section, location) in zip(sections, locations) {
            images.append(try await clipboardPreimage(section, info: location, index: index, tree: tree, at: root))
        }
        _ = try await clipboardApply(.check, file: file, at: root)

        let branch = symbolicHead.hasPrefix("refs/heads/") ? String(symbolicHead.dropFirst("refs/heads/".count)) : symbolicHead
        let headLabel = branch.isEmpty ? "detached at \(head.prefix(7))" : branch
        return ClipboardPatchPlan(text: text, files: sections.map(\.file), headLabel: headLabel,
                                  root: root, gitDirectory: gitDirectory, head: head, symbolicHead: symbolicHead,
                                  preimages: images)
    }

    private func clipboardGitLine(
        _ arguments: [String], at root: URL, allowed: Set<Int32> = []
    ) async throws -> String {
        var bytes = try await runWithEnvironment(arguments, cwd: root, extra: Self.clipboardLocalEnvironment,
                                                 allowedExitCodes: allowed).stdout
        if bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
        guard let line = String(data: bytes, encoding: .utf8) else {
            throw ClipboardPatchRefusal.changedSinceShown
        }
        return line
    }

    private func refuseClipboardOperation(at root: URL, gitDirectory: URL) async throws {
        guard Self.operationRefusal(in: gitDirectory) == nil,
            try Self.clipboardFileInfo(gitDirectory.appendingPathComponent("SQUASH_MSG").path) == nil,
            try await operationInProgress(at: root) == nil
        else { throw ClipboardPatchRefusal.operationInProgress }
    }

    private static func refuseClipboardAdministrativePaths(
        _ paths: [String], under root: URL, administrative: [String]
    ) throws {
        let reserved = administrative.map { ClipboardPatchPath.key($0) }
        for path in paths {
            let candidate = ClipboardPatchPath.key(root.appendingPathComponent(path).path)
            if reserved.contains(where: {
                $0 == candidate || $0.utf8.starts(with: (candidate + "/").utf8)
                    || candidate.utf8.starts(with: ($0 + "/").utf8)
            }) {
                throw ClipboardPatchRefusal.unsafePath(path)
            }
        }
    }

    private static func refuseChangingClipboardAttributes(_ paths: [String]) throws {
        let folded = paths.map(ClipboardPatchPath.key)
        let attributeDirectories = Set(folded.compactMap { path -> String? in
            let components = ClipboardPatchPath.components(path)
            guard components.last == ".gitattributes" else { return nil }
            return components.dropLast().joined(separator: "/")
        })
        for (path, key) in zip(paths, folded) where ClipboardPatchPath.components(key).last != ".gitattributes" {
            if attributeDirectories.contains("") || ClipboardPatchPath.ancestors(of: key).contains(where: attributeDirectories.contains) {
                throw ClipboardPatchRefusal.checkoutConversion(path)
            }
        }
    }

    private func refuseClipboardConversions(on paths: [String], at root: URL) async throws {
        let autocrlf = try await clipboardGitLine(
            ["config", "--type=bool-or-str", "--default=false", "--get", "core.autocrlf"], at: root)
        if autocrlf != "false", let path = paths.first { throw ClipboardPatchRefusal.checkoutConversion(path) }

        let conversions: Set<String> = ["filter", "working-tree-encoding", "ident", "text", "eol", "crlf"]
        for batch in Self.pathBatches(paths) {
            async let worktree = runWithEnvironment(["check-attr", "-z", "--all", "--"] + batch,
                                                     cwd: root, extra: Self.clipboardLocalEnvironment).stdout
            async let index = runWithEnvironment(["check-attr", "-z", "--all", "--cached", "--"] + batch,
                                                  cwd: root, extra: Self.clipboardLocalEnvironment).stdout
            for data in try await [worktree, index] {
                // --all returns only assigned attributes. In a single-attribute lookup,
                // filter=unspecified is indistinguishable from an unassigned attribute.
                if data.isEmpty { continue }
                let fields = data.dropLast().split(separator: 0, omittingEmptySubsequences: false)
                guard data.last == 0, fields.count.isMultiple(of: 3)
                else { throw ClipboardPatchRefusal.changedSinceShown }
                for index in stride(from: 0, to: fields.count, by: 3) {
                    let attribute = String(decoding: fields[index + 1], as: UTF8.self)
                    guard conversions.contains(attribute) else { continue }
                    // Git prints "unset" for a disabled attribute. A filter or encoding can
                    // also take that literal name, which is ambiguous in check-attr output.
                    if attribute != "filter", attribute != "working-tree-encoding",
                        fields[index + 2].elementsEqual("unset".utf8)
                    {
                        continue
                    }
                    throw ClipboardPatchRefusal.checkoutConversion(String(decoding: fields[index], as: UTF8.self))
                }
            }
        }
    }

    private struct ClipboardEntry {
        let path: String
        let mode: String
        let object: String
        let stage: String
        let tag: String
    }

    private struct ClipboardEntries {
        var files: [String: [ClipboardEntry]] = [:]
        var directories: Set<String> = []
    }

    private func clipboardEntries(
        _ arguments: [String], relevantTo paths: [String], at root: URL
    ) async throws -> ClipboardEntries {
        let targets = Set(paths.map(ClipboardPatchPath.key))
        let parents = Set(targets.flatMap(ClipboardPatchPath.ancestors))
        var entries = ClipboardEntries()
        let data = try await runWithEnvironment(arguments, cwd: root, extra: Self.clipboardLocalEnvironment).stdout
        for record in data.split(separator: 0) {
            let fields = record.split(separator: UInt8(ascii: "\t"), maxSplits: 1)
            guard fields.count == 2 else { throw ClipboardPatchRefusal.changedSinceShown }
            let path = String(decoding: fields[1], as: UTF8.self)
            let key = ClipboardPatchPath.key(path)
            // A tracked descendant also occupies a destination named as a file.
            entries.directories.formUnion(ClipboardPatchPath.ancestors(of: key).filter(targets.contains))
            guard targets.contains(key) || parents.contains(key) else { continue }

            let metadata = String(decoding: fields[0], as: UTF8.self).split(separator: " ").map(String.init)
            let entry: ClipboardEntry
            switch metadata.count {
            case 3: // ls-tree: mode type object
                entry = .init(path: path, mode: metadata[0], object: metadata[2], stage: "0", tag: "H")
            case 4: // ls-files: tag mode object stage
                entry = .init(path: path, mode: metadata[1], object: metadata[2], stage: metadata[3], tag: metadata[0])
            default: throw ClipboardPatchRefusal.changedSinceShown
            }
            entries.files[key, default: []].append(entry)
        }
        return entries
    }

    private func clipboardPreimage(
        _ section: ClipboardPatchParser.Section, info: stat?, index: ClipboardEntries,
        tree: ClipboardEntries, at root: URL
    ) async throws -> ClipboardPatchPlan.Preimage? {
        let file = section.file
        let key = ClipboardPatchPath.key(file.path)
        let old = tree.files[key] ?? []
        let staged = index.files[key] ?? []
        let parents = ClipboardPatchPath.ancestors(of: key)
        guard !parents.contains(where: { index.files[$0] != nil || tree.files[$0] != nil })
        else { throw ClipboardPatchRefusal.unsafePath(file.path) }
        guard !index.directories.contains(key), !tree.directories.contains(key)
        else { throw ClipboardPatchRefusal.affectedPathChanged(file.path) }
        if file.kind == .added {
            guard old.isEmpty, staged.isEmpty, info == nil else {
                throw ClipboardPatchRefusal.affectedPathChanged(file.path)
            }
            return nil
        }
        guard old.count == 1, staged.count == 1,
            old[0].path.utf8.elementsEqual(file.path.utf8), staged[0].path.utf8.elementsEqual(file.path.utf8),
            old[0].object == staged[0].object, old[0].mode == staged[0].mode,
            staged[0].tag == "H", staged[0].stage == "0", Self.isFullObjectID(staged[0].object),
            let info, info.st_mode & S_IFMT == S_IFREG
        else { throw ClipboardPatchRefusal.affectedPathChanged(file.path) }
        let mode = info.st_mode & S_IXUSR == 0 ? "100644" : "100755"
        guard staged[0].mode == mode, section.mode == nil || section.mode == mode
        else { throw ClipboardPatchRefusal.affectedPathChanged(file.path) }

        // Compare raw bytes with the index blob, avoiding Git's stat cache, filters and
        // respect for assume-unchanged/skip-worktree. Even an edit outside hunk context refuses.
        let object = staged[0].object
        let blob = try await runWithEnvironment(["cat-file", "blob", object], cwd: root,
                                                extra: Self.clipboardLocalEnvironment).stdout
        let url = root.appendingPathComponent(file.path)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ClipboardPatchRefusal.affectedPathChanged(file.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var current = stat()
        guard fstat(fd, &current) == 0, current.st_ino == info.st_ino, current.st_dev == info.st_dev,
            current.st_mode == info.st_mode, current.st_size == blob.count,
            (try handle.readToEnd() ?? Data()) == blob, !blob.contains(0),
            String(data: blob, encoding: .utf8) != nil,
            file.kind != .deleted || file.deletions > 0 || blob.isEmpty
        else { throw ClipboardPatchRefusal.affectedPathChanged(file.path) }
        return .init(object: object, permissions: info.st_mode)
    }

    private static func clipboardWorktreeInfo(_ path: String, at root: URL) throws -> stat? {
        var url = root
        let components = ClipboardPatchPath.components(path)
        for (index, component) in components.enumerated() {
            url.appendPathComponent(component)
            guard let info = try clipboardFileInfo(url.path) else { return nil }
            if index == components.count - 1 { return info }
            guard info.st_mode & S_IFMT == S_IFDIR,
                try clipboardFileInfo(url.appendingPathComponent(".git").path) == nil
            else { throw ClipboardPatchRefusal.unsafePath(path) }
            if try clipboardFileInfo(url.appendingPathComponent("HEAD").path) != nil,
                try clipboardFileInfo(url.appendingPathComponent("objects").path) != nil,
                try clipboardFileInfo(url.appendingPathComponent("refs").path) != nil
            {
                throw ClipboardPatchRefusal.unsafePath(path)
            }
        }
        return nil
    }

    private static func clipboardFileInfo(_ path: String) throws -> stat? {
        var info = stat()
        if lstat(path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw ClipboardPatchRefusal.unsafePath(path)
    }

}
