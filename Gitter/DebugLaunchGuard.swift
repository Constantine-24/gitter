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
    ///   own open failed, or that names no fixture, does nothing and says why.
    ///
    /// Pure: each answer comes from the environment it is handed (and, for the paths, the file
    /// system's links). Compiled out of Release, where launches are never scripted.
    enum DebugLaunchGuard {
        static let prefix = "GITTER_DEBUG_"
        static let openVariable = "GITTER_DEBUG_OPEN"
        static let autoFetchVariable = "GITTER_DEBUG_AUTOFETCH"

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

        /// Nil when a hook may act on `root`, the repository on screen; otherwise the line to
        /// log instead of acting.
        static func stepRefusal(root: URL?, _ environment: [String: String]) -> String? {
            guard let fixture = environment[openVariable], !fixture.isEmpty else {
                return "refused: no \(openVariable) names the fixture to act on"
            }
            guard let root else {
                return "refused: no repository is open (\(openVariable)=\(fixture))"
            }
            let wanted = resolved(URL(fileURLWithPath: fixture))
            let open = resolved(root)
            guard open == wanted else {
                return "refused: the open repository \(open) is not \(openVariable)=\(fixture) (\(wanted))"
            }
            return nil
        }

        /// The path with its links followed, `.` and `..` removed and no trailing slash —
        /// `/var/folders/…` and `/private/var/folders/…` are one directory.
        private static func resolved(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }
    }

#endif
