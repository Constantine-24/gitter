import AppKit

/// Gitter › About Gitter (spec §1): AppKit's standard panel, its version line built from
/// `Info.plist` — "Version 0.1.0 (412, d410591)" for a packaged build, whose build number is the
/// commit count and whose `GitterCommit` is the commit; the version and build only for a build
/// without one (a plain Xcode build).
enum AboutPanel {
    /// ("0.1.0", "412, d410591"), or ("0.1.0", "412") without a non-empty `GitterCommit`.
    static func versions(info: [String: Any]) -> (application: String, build: String) {
        let application = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        guard let commit = info["GitterCommit"] as? String, !commit.isEmpty else { return (application, build) }
        return (application, "\(build), \(commit)")
    }

    @MainActor static func show() {
        let versions = versions(info: Bundle.main.infoDictionary ?? [:])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: versions.application, .version: versions.build,
        ])
    }
}
