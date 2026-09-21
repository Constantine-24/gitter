import Foundation

/// A configured remote, as `git remote -v` reports it.
public struct Remote: Sendable, Hashable, Identifiable {
    public let name: String
    public let fetchURL: String
    public let pushURL: String

    public var id: String { name }

    public init(name: String, fetchURL: String, pushURL: String) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL
    }
}
