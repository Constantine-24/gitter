import Foundation

public enum ClipboardDiffSource: Sendable, Hashable {
    case workingCopy
    case commit(String)
    case stash(Stash)
    case comparison(Comparison)
}

public struct ClipboardDiffExport: Sendable, Hashable {
    public let text: String
    public let fileCount: Int
}

public enum ClipboardDiffExportRefusal: Error, Sendable, Hashable {
    case unsupportedPaths([String])
    case sourceChanged

    static func unsupported(_ paths: [String]) -> Self {
        var seen = Set<Data>()
        return .unsupportedPaths(paths.filter {
            seen.insert(Data($0.utf8)).inserted
        }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    }
}
