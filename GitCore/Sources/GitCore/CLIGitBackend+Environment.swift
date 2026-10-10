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
    /// The count is read as git reads it (`configCount`): `" 1"` is git's 1, so the user's
    /// `GIT_CONFIG_KEY_0` is kept and this parameter goes at index 1 (E3; before it, Swift's
    /// `Int(_:)` read that count as 0 and this parameter replaced the user's). A count git
    /// refuses counts as zero. git itself refuses to run with one (measured: `error: bogus count
    /// in GIT_CONFIG_COUNT`, `error: too many entries in GIT_CONFIG_COUNT`, both exit 128), so
    /// nothing that worked before is lost by replacing it, and the git this hands back runs
    /// (`ConfigCountTests`, every row of the measured table).
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
        let count = configCount(inherited["GIT_CONFIG_COUNT"]) ?? 0
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

    /// git's reading of `GIT_CONFIG_COUNT`: leading C-isspace skipped, an optional sign, decimal
    /// digits, nothing after; nil when git would refuse it. A negative is wrapped as `strtoul`
    /// wraps it, so almost every one reads as nil (git's "too many"). An absent count is git's
    /// zero.
    ///
    /// Measured on git 2.54 (E3 B4.1, and `ConfigCountTests` against the real git, row by row):
    /// git reads the count with `strtoul(…, 10)` and refuses it when anything is left after the
    /// digits (`bogus count`) or the value is over `INT_MAX` (`too many entries`). `strtoul`
    /// saturates a magnitude past 2^64 − 1 to `ULONG_MAX` and negates a negative modulo 2^64, so
    /// `-1` is `ULONG_MAX` (refused) and `-0` is 0, while a negative near −2^64 wraps back into
    /// range: `-18446744073709551615` is git's 1 (fix round 1, measured). So `" 1"`, `"\t1"` and
    /// `" +1"` are 1, `""` is 0 (no digits, nothing left over), and `"1 "`, `"1\n"`, `" "`,
    /// `"0x1"`, `"-1"` and `"-18446744073709551616"` are refused. The bytes skipped are C's six
    /// spaces (git runs under `LC_ALL=C`, so `U+00A0` is not one, measured), read as bytes:
    /// `"\r\n"` is one `Character` in Swift and two spaces to git.
    static func configCount(_ raw: String?) -> Int? {
        guard let raw else { return 0 }
        var bytes = Substring(raw).utf8[...]
        while let first = bytes.first, [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains(first) {
            bytes = bytes.dropFirst()
        }
        var negative = false
        if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
            negative = sign == UInt8(ascii: "-")
            bytes = bytes.dropFirst()
        }
        // `strtoul` with no digits at all consumes nothing, so what is left is the whole value:
        // empty for `""` (git's 0), and anything else refused — a lone sign or space included.
        guard !bytes.isEmpty else { return raw.utf8.isEmpty ? 0 : nil }
        var magnitude: UInt64 = 0
        for byte in bytes {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            let (times10, over1) = magnitude.multipliedReportingOverflow(by: 10)
            let (next, over2) = times10.addingReportingOverflow(UInt64(byte - UInt8(ascii: "0")))
            // Past 2^64 − 1 `strtoul` answers `ULONG_MAX`, sign or no sign: git's "too many" —
            // or its "bogus count" if a non-digit follows. A refusal either way.
            if over1 || over2 { return nil }
            magnitude = next
        }
        let value = negative ? 0 &- magnitude : magnitude
        return value > UInt64(Int32.max) ? nil : Int(value)
    }
}
