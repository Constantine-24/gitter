#if DEBUG

    import Foundation

    /// Keeps a scripted launch away from the repository the user last had open (B2, Ruling 15).
    ///
    /// The app reopens `lastRepositoryPath` at launch and fetches it automatically — on the
    /// developer's machine that is a real repository. A launch with any `GITTER_DEBUG_*`
    /// variable set is a harness run, and for one:
    ///
    /// - nothing is reopened (`reopensLastRepository`): the fixture named by
    ///   `GITTER_DEBUG_OPEN` is the first repository the window shows;
    /// - nothing it opens is added to Open Recent (`notesRecentDocuments`);
    /// - no automatic fetch starts (`startsAutomaticFetch`) unless the script asks for its
    ///   schedule with `GITTER_DEBUG_AUTOFETCH`;
    /// - no hook acts — no selection, staging, click, key or step — unless the repository on
    ///   screen is that fixture (`stepRefusal`), compared by resolved path, so a script whose
    ///   own open failed, or that names no fixture, does nothing and says why;
    /// - another window is opened (`newwindow:`) only on a path `GITTER_DEBUG_ALSO_OPEN` names
    ///   (`newWindowRefusal`), and a step acts on a window's repository only when it is the
    ///   fixture or one of those (E2 Task 4).
    ///
    /// Pure: each answer comes from the environment it is handed (and, for the paths, the file
    /// system's links). Compiled out of Release, where launches are never scripted.
    enum DebugLaunchGuard {
        static let prefix = "GITTER_DEBUG_"
        static let openVariable = "GITTER_DEBUG_OPEN"
        static let autoFetchVariable = "GITTER_DEBUG_AUTOFETCH"
        static let alsoOpenVariable = "GITTER_DEBUG_ALSO_OPEN"

        /// Whether a harness started this process: any `GITTER_DEBUG_*` variable, even empty.
        static func isScripted(_ environment: [String: String]) -> Bool {
            environment.keys.contains { $0.hasPrefix(prefix) }
        }

        static func reopensLastRepository(_ environment: [String: String]) -> Bool {
            !isScripted(environment)
        }

        /// The fixture to open first: `GITTER_DEBUG_OPEN`'s path — none when it is unset or
        /// empty (final review M4). An empty path is the working directory, which from the
        /// checkout is the developer's own repository; every step is refused then as well.
        static func fixtureToOpen(_ environment: [String: String]) -> String? {
            guard let fixture = environment[openVariable], !fixture.isEmpty else { return nil }
            return fixture
        }

        /// Whether `open(_:)` adds what it opens to Open Recent (B3 Ruling 7): not in a scripted
        /// launch, whose fixtures are scratch folders — that list is the user's, kept outside
        /// the defaults, where a harness's restore cannot put it back.
        static func notesRecentDocuments(_ environment: [String: String]) -> Bool {
            !isScripted(environment)
        }

        static func startsAutomaticFetch(_ environment: [String: String]) -> Bool {
            !isScripted(environment) || environment[autoFetchVariable] != nil
        }

        /// The other windows' repositories (E2 Task 4): `GITTER_DEBUG_ALSO_OPEN`'s colon-separated
        /// paths, each with its links resolved; an empty part is no path.
        static func alsoOpen(_ environment: [String: String]) -> [URL] {
            (environment[alsoOpenVariable] ?? "").split(separator: ":").map {
                URL(fileURLWithPath: resolved(URL(fileURLWithPath: String($0))))
            }
        }

        /// Nil when `newwindow:<path>` may open `path`: one of `alsoOpen`'s, by resolved path —
        /// the launcher named it, as it names the fixture. Otherwise the line to log instead.
        static func newWindowRefusal(_ path: String, _ environment: [String: String]) -> String? {
            let allowed = alsoOpen(environment).map(\.path)
            guard !path.isEmpty else { return "refused: newwindow: names no path" }
            let wanted = resolved(URL(fileURLWithPath: path))
            guard allowed.contains(wanted) else {
                return "refused: newwindow:\(path) (\(wanted)) is not in \(alsoOpenVariable)=\(environment[alsoOpenVariable] ?? "")"
            }
            return nil
        }

        /// Nil when a hook may act on `root`, the repository its window shows; otherwise the line
        /// to log instead of acting. `allowed` (`alsoOpen`) are the other windows' repositories a
        /// step may act on besides the fixture; nothing is allowed when no fixture is named.
        static func stepRefusal(root: URL?, allowed: [URL], _ environment: [String: String]) -> String? {
            guard let fixture = environment[openVariable], !fixture.isEmpty else {
                return "refused: no \(openVariable) names the fixture to act on"
            }
            guard let root else {
                return "refused: no repository is open (\(openVariable)=\(fixture))"
            }
            let wanted = resolved(URL(fileURLWithPath: fixture))
            let open = resolved(root)
            guard open == wanted || allowed.map(resolved).contains(open) else {
                let also = allowed.isEmpty ? "" : " nor one of \(alsoOpenVariable)'s"
                return "refused: the open repository \(open) is not \(openVariable)=\(fixture) (\(wanted))\(also)"
            }
            return nil
        }

        /// `stepRefusal` with only the fixture allowed.
        static func stepRefusal(root: URL?, _ environment: [String: String]) -> String? {
            stepRefusal(root: root, allowed: [], environment)
        }

        /// The path with its links followed, `.` and `..` removed and no trailing slash —
        /// `/var/folders/…` and `/private/var/folders/…` are one directory.
        private static func resolved(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }
    }

#endif
