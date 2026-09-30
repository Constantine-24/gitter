import Foundation

extension CLIGitBackend {
    /// `inherited` with `rerere.enabled=false` added as one more config parameter, for every
    /// `stash apply` Gitter runs.
    ///
    /// With a resolution recorded, rerere rewrites a conflicted file to that old resolution —
    /// no markers left — and with `rerere.autoUpdate=true` it stages it too, so the apply looks
    /// clean although git merged nothing (M 11). An apply has to show git's own conflict.
    ///
    /// git reads `GIT_CONFIG_COUNT` parameters as `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>`
    /// for `n` below the count, over every config file, and a later parameter wins over an
    /// earlier one. So the user's own parameters are kept and this one is appended at index
    /// `count` — after them, so it is the last word on `rerere.enabled`. Measured on git 2.54:
    /// it beats a repository's `rerere.enabled=true` + `rerere.autoUpdate=true`
    /// (`EnvironmentRunTests.rerereOffStopsARecordedResolutionFromBeingReplayed`), and a
    /// parameter of the user's own setting it to `true`
    /// (`gitReadsTheAddedParameterAsTheLastWord`).
    ///
    /// An absent, empty or unreadable `GIT_CONFIG_COUNT` counts as zero. git itself refuses to
    /// run with an unreadable or negative one (measured: `error: bogus count in
    /// GIT_CONFIG_COUNT`, `error: too many entries in GIT_CONFIG_COUNT`, both exit 128), so
    /// nothing that worked before is lost by replacing it.
    ///
    /// **`GIT_CONFIG_PARAMETERS` outranks all of that.** It is how `git -c` hands its
    /// parameters to a child — so it is in Gitter's environment when Gitter was started from a
    /// git alias or hook — and git reads it *after* the counted parameters (measured on git
    /// 2.54: its `'rerere.enabled'='true'` beat a counted `false`). When it is present, this
    /// appends `'rerere.enabled'='false'` to it as well, which then wins there too (measured).
    /// An absent one is left absent.
    static func rerereOff(_ inherited: [String: String]) -> [String: String] {
        withConfig("rerere.enabled", "false", over: inherited)
    }

    /// `inherited` with `key=value` appended as the last config parameter, by the rule
    /// `rerereOff` documents (it is that function, generalised in A2 Task 3 for the rebase
    /// continue's `commit.cleanup=scissors`, M 29): at index `GIT_CONFIG_COUNT`, after the
    /// user's own parameters, and appended to a non-empty `GIT_CONFIG_PARAMETERS` as well, so it
    /// is the last word on `key` for this one command. `key` and `value` are Gitter's own
    /// constants, never user input: neither is quoted for `GIT_CONFIG_PARAMETERS`.
    static func withConfig(_ key: String, _ value: String, over inherited: [String: String]) -> [String: String] {
        let count = inherited["GIT_CONFIG_COUNT"].flatMap { Int($0) }.map { max($0, 0) } ?? 0
        var environment = inherited
        environment["GIT_CONFIG_KEY_\(count)"] = key
        environment["GIT_CONFIG_VALUE_\(count)"] = value
        environment["GIT_CONFIG_COUNT"] = String(count + 1)
        if let parameters = inherited["GIT_CONFIG_PARAMETERS"],
            !parameters.trimmingCharacters(in: .whitespaces).isEmpty
        {
            environment["GIT_CONFIG_PARAMETERS"] = parameters + " '\(key)'='\(value)'"
        }
        return environment
    }
}
