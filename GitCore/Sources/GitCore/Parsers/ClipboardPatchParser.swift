import Foundation

/// Validate the complete patch, including the metadata Git can ignore. Git supplies the
/// machine-readable paths and line counts, and every section must account for one of them.
enum ClipboardPatchParser {
    struct Section {
        let file: ClipboardPatchFile
        let mode: String?
    }

    private struct Numstat {
        let path: String
        let additions: Int
        let deletions: Int
    }

    static func parse(_ data: Data, numstat: Data, reportingExportPaths: Bool = false) throws -> [Section] {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let fieldsByRecord = numstat.split(separator: 0).map {
            $0.split(separator: UInt8(ascii: "\t"), maxSplits: 2)
        }
        if reportingExportPaths {
            let unsafe = unsafeExportPaths(fieldsByRecord)
            if !unsafe.isEmpty { throw ClipboardDiffExportRefusal.unsupported(unsafe) }
        }
        let records = try fieldsByRecord.map { fields in
            guard fields.count == 3,
                let additions = Int(String(decoding: fields[0], as: UTF8.self)), additions >= 0,
                let deletions = Int(String(decoding: fields[1], as: UTF8.self)), deletions >= 0,
                let path = String(validating: fields[2], as: UTF8.self)
            else { throw ClipboardPatchRefusal.invalidPatch }
            return Numstat(path: path, additions: additions, deletions: deletions)
        }
        let starts = lines.indices.filter { lines[$0].starts(with: "diff --git ".utf8) }
        guard !records.isEmpty, starts.first == 0, starts.count == records.count,
            lines.last?.isEmpty == true, numstat.last == 0
        else { throw ClipboardPatchRefusal.invalidPatch }

        // Two paths that alias on case-insensitive or normalization-insensitive macOS
        // volumes count as the same destination. A path cannot be another's parent.
        var names = Set<String>()
        for record in records {
            guard names.insert(try pathKey(record.path)).inserted else {
                throw ClipboardPatchRefusal.unsafePath(record.path)
            }
        }
        for name in names where ClipboardPatchPath.ancestors(of: name).contains(where: names.contains) {
            throw ClipboardPatchRefusal.unsafePath(name)
        }

        let ends = starts.dropFirst() + [lines.count - 1]
        return try zip(zip(starts, ends), records).map { range, record in
            try section(lines[range.0..<range.1].map { String(decoding: $0, as: UTF8.self) }, record: record)
        }
    }

    /// Identify both paths in each alias or ancestor conflict, using the exact names Git
    /// reported. A non-UTF-8 filename is shown in Git's quoted byte spelling.
    private static func unsafeExportPaths(_ fieldsByRecord: [[Data]]) -> [String] {
        var paths: [String] = []
        var unsafe: [String] = []
        for fields in fieldsByRecord where fields.count == 3 {
            if let path = String(validating: fields[2], as: UTF8.self) {
                paths.append(path)
            } else {
                unsafe.append(PatchBuilder.quoteGitPath(Array(fields[2])))
            }
        }
        let byKey = Dictionary(grouping: paths, by: ClipboardPatchPath.key)
        var conflicts = Set<String>()
        for (key, matches) in byKey {
            if matches.count > 1 || (try? pathKey(matches[0])) == nil { conflicts.insert(key) }
            for parent in ClipboardPatchPath.ancestors(of: key) where byKey[parent] != nil {
                conflicts.insert(key)
                conflicts.insert(parent)
            }
        }
        return unsafe + paths.filter { conflicts.contains(ClipboardPatchPath.key($0)) }
    }

    private static func pathKey(_ path: String) throws -> String {
        let key = ClipboardPatchPath.key(path)
        let components = ClipboardPatchPath.components(key)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" })
        else { throw ClipboardPatchRefusal.unsafePath(path) }
        return key
    }

    private static func section(_ lines: [String], record: Numstat) throws -> Section {
        let path = record.path
        guard matchesPair(lines[0], path: path) else { throw ClipboardPatchRefusal.invalidPatch }
        var index = 1
        var kind = ClipboardPatchFile.Kind.modified
        var mode: String?
        if index < lines.count {
            let line = lines[index]
            if line.hasPrefix("new file mode ") {
                kind = .added
                mode = String(line.dropFirst("new file mode ".count))
                index += 1
            } else if line.hasPrefix("deleted file mode ") {
                kind = .deleted
                mode = String(line.dropFirst("deleted file mode ".count))
                index += 1
            }
        }
        if index < lines.count, let metadata = lines[index].wholeMatch(
            of: /^index [0-9a-f]+\.\.[0-9a-f]+(?: (100644|100755))?$/)
        {
            if let sameMode = metadata.1 {
                guard kind == .modified else { throw ClipboardPatchRefusal.invalidPatch }
                mode = String(sameMode)
            }
            index += 1
        }
        if let mode, mode != "100644", mode != "100755" { throw ClipboardPatchRefusal.invalidPatch }

        if index < lines.count {
            guard index + 2 < lines.count,
                matchesSide(lines[index], marker: "--- ", expected: kind == .added ? "/dev/null" : "a/" + path),
                matchesSide(lines[index + 1], marker: "+++ ", expected: kind == .deleted ? "/dev/null" : "b/" + path)
            else { throw ClipboardPatchRefusal.invalidPatch }
            index += 2
        } else if kind == .modified {
            throw ClipboardPatchRefusal.invalidPatch
        }
        let changes = try countChanges(lines[index...])
        guard changes.additions == record.additions, changes.deletions == record.deletions,
            kind != .modified || changes.additions > 0 || changes.deletions > 0,
            kind != .added || changes.deletions == 0,
            kind != .deleted || changes.additions == 0
        else { throw ClipboardPatchRefusal.invalidPatch }
        return Section(file: .init(path: path, kind: kind, additions: changes.additions, deletions: changes.deletions),
                       mode: mode)
    }

    private static func matchesPair(_ line: String, path: String) -> Bool {
        if line.utf8.elementsEqual(("diff --git a/" + path + " b/" + path).utf8) { return true }
        guard let names = line.wholeMatch(of: /^diff --git ("(?:[^"\\]|\\.)*") ("(?:[^"\\]|\\.)*")$/),
            let old = DiffParser.unquoteCStyle(String(names.1)),
            let new = DiffParser.unquoteCStyle(String(names.2))
        else { return false }
        return old.utf8.elementsEqual(("a/" + path).utf8) && new.utf8.elementsEqual(("b/" + path).utf8)
    }

    private static func matchesSide(_ line: String, marker: String, expected: String) -> Bool {
        guard line.utf8.starts(with: marker.utf8) else { return false }
        var value = String(decoding: line.utf8.dropFirst(marker.utf8.count), as: UTF8.self)
        // Git adds a delimiter after an unquoted path containing spaces.
        if value.utf8.last == UInt8(ascii: "\t") { value.removeLast() }
        if value.utf8.first == UInt8(ascii: "\"") {
            guard value.wholeMatch(of: /^"(?:[^"\\]|\\.)*"$/) != nil,
                let decoded = DiffParser.unquoteCStyle(value)
            else { return false }
            value = decoded
        }
        return value.utf8.elementsEqual(expected.utf8)
    }

    private static func countChanges(_ lines: ArraySlice<String>) throws -> (additions: Int, deletions: Int) {
        var oldLeft = 0, newLeft = 0
        var additions = 0, deletions = 0
        var canMarkNoNewline = false
        for line in lines {
            if line == "\\ No newline at end of file", canMarkNoNewline {
                canMarkNoNewline = false
                continue
            }
            if oldLeft == 0, newLeft == 0 {
                guard let header = line.wholeMatch(of: /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@.*$/.dotMatchesNewlines()),
                    Int(header.1) != nil, Int(header.3) != nil,
                    let old = Int(header.2 ?? "1"), let new = Int(header.4 ?? "1"), old > 0 || new > 0
                else { throw ClipboardPatchRefusal.invalidPatch }
                oldLeft = old
                newLeft = new
                canMarkNoNewline = false
                continue
            }

            // diff.suppressBlankEmpty writes the blank context line without its leading space.
            switch line.utf8.first ?? UInt8(ascii: " ") {
            case UInt8(ascii: "+"): newLeft -= 1; additions += 1
            case UInt8(ascii: "-"): oldLeft -= 1; deletions += 1
            case UInt8(ascii: " "): oldLeft -= 1; newLeft -= 1
            default: throw ClipboardPatchRefusal.invalidPatch
            }
            guard oldLeft >= 0, newLeft >= 0 else { throw ClipboardPatchRefusal.invalidPatch }
            canMarkNoNewline = true
        }
        guard oldLeft == 0, newLeft == 0 else { throw ClipboardPatchRefusal.invalidPatch }
        return (additions, deletions)
    }
}

enum ClipboardPatchPath {
    private static let separator = UInt8(ascii: "/")

    static func key(_ path: String) -> String {
        path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    // A leading combining mark in a filename can share a Swift Character with the
    // preceding slash. Filesystem and Git path boundaries are bytes.
    static func components(_ path: String) -> [String] {
        path.utf8.split(separator: separator, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func ancestors(of path: String) -> [String] {
        let bytes = path.utf8
        return bytes.indices.compactMap {
            bytes[$0] == separator ? String(decoding: bytes[..<$0], as: UTF8.self) : nil
        }
    }
}
