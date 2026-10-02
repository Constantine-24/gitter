import Foundation

/// How a list of paths reaches git without one argument per path (Ruling 26).
///
/// `Process` raises an Objective-C exception — the app crashes — when it is given more than
/// 4096 arguments (measured on macOS 27), and macOS refuses more than 1 MiB of them (`E2BIG`, a
/// thrown launch failure). Discard All… of 5 000 files, or staging a selection that large, put
/// one argument per path into one vector and crashed. Two ways round it, measured on git 2.54:
///
/// - **A write takes a pathspec file** (`withPathspecFile`). `add`, `restore` and `rm` read
///   `--pathspec-from-file=<file> --pathspec-file-nul`; `:(literal)` magic inside it is
///   honoured (a listed `a*.txt` did not add `a b.txt`; a plain `a*.txt` in the file did), and
///   one bad path among 5 000 still refuses all of them, as on the command line (`restore`
///   exit 1, `add` exit 128, nothing changed). It stays one call, all or nothing (M A.5). The
///   runner's stdin is `/dev/null`, so `-` (stdin) cannot be used: only a file. An empty file is
///   refused by `restore` and `rm` (`you must specify path(s)`), not read as "everything".
/// - **A read goes in batches** (`readInBatches`). `diff`, `ls-files` and `ls-tree` take no
///   pathspec file (`invalid option` / `unknown option`, exit 129), so they run once per batch
///   of at most `pathBatch` paths and `pathBatchBytes` bytes, and the caller joins the results.
extension CLIGitBackend {
    /// Paths per read: `stageAllBatch`'s and `cacheinfoLimit`'s 1 000.
    static let pathBatch = 1_000

    /// Bytes of pathspec per read, so a batch of long names stays well under the 1 MiB
    /// `ARG_MAX` (1 000 names of 1 000 bytes would not).
    static let pathBatchBytes = 256 * 1024

    /// `paths` in order, split into batches of at most `limit` paths and `bytes` bytes (each
    /// counted with its `:(literal)` prefix and a terminator). A path longer than `bytes` goes
    /// alone. No paths is one empty batch: the caller's one call, as before batching.
    static func pathBatches(_ paths: [String], limit: Int = pathBatch, bytes: Int = pathBatchBytes) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var size = 0
        for path in paths {
            let cost = path.utf8.count + 11
            if !current.isEmpty, current.count >= max(limit, 1) || size + cost > bytes {
                batches.append(current)
                current = []
                size = 0
            }
            current.append(path)
            size += cost
        }
        if !current.isEmpty || batches.isEmpty { batches.append(current) }
        return batches
    }

    /// `named` without each path another named path covers as a literal pathspec of a
    /// recursive read: an exact duplicate (the first stays), `d/` beside `d` (`d` stays: it
    /// also matches a file `d`), and anything under a named directory. What is left matches
    /// exactly what all of them did, and no two of them match the same entry. Order is kept.
    static func withoutCoveredPaths(_ named: [String]) -> [String] {
        let keys = named.map(StashRecord.withoutTrailingSlash)
        let present = Set(keys)
        var kept: [String: Int] = [:]
        for (index, path) in named.enumerated() {
            if let first = kept[keys[index]] {
                if named[first].hasSuffix("/"), !path.hasSuffix("/") { kept[keys[index]] = index }
            } else {
                kept[keys[index]] = index
            }
        }
        return named.indices
            .filter { kept[keys[$0]] == $0 && !ancestors(of: keys[$0]).contains(where: present.contains) }
            .map { named[$0] }
    }

    /// `read` over `paths`: one call, exactly as before, while they fit in one batch; otherwise
    /// once per batch, the results in order.
    ///
    /// With `covering` (a read whose literal pathspec matches everything under a directory:
    /// `diff`, `ls-files`), the paths others cover are left out first (`withoutCoveredPaths`),
    /// so the batches match disjoint sets of entries: none is read twice, and a named
    /// directory's entries all come from one call, in git's order. Joined, the results are what
    /// one call over every path gave. Not for `ls-tree` without `-r`, which lists a named
    /// directory's own entry rather than what is under it; its results are merged by path.
    func readInBatches<T>(
        of paths: [String], covering: Bool, _ read: ([String]) async throws -> T
    ) async throws -> [T] {
        let batches = Self.pathBatches(paths)
        guard batches.count > 1 else { return [try await read(paths)] }
        var results: [T] = []
        for batch in covering ? Self.pathBatches(Self.withoutCoveredPaths(paths)) : batches {
            results.append(try await read(batch))
        }
        return results
    }

    /// `body` with the path of a file holding each of `paths` as a literal pathspec
    /// (`literalPathspec`), each NUL-terminated, for `--pathspec-from-file=<path>
    /// --pathspec-file-nul`. NUL-separated because a name may hold a newline or a quote, which
    /// the line form would read as a separator or C-quoting. The file lives under
    /// `directory` (`NSTemporaryDirectory()`; only tests pass another) with a UUID name, outside
    /// the repository where it could show as untracked, and is removed when `body` returns or
    /// throws.
    func withPathspecFile<T>(
        _ paths: [String], in directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
        _ body: (String) async throws -> T
    ) async throws -> T {
        let file = directory.appendingPathComponent("gitter-pathspec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(paths.map { literalPathspec($0) + "\0" }.joined().utf8).write(to: file)
        return try await body(file.path)
    }
}
