import Foundation

/// Scans Swift source text for git invocations that could destroy uncommitted work.
///
/// This milestone's safety promise — "Gitter never discards uncommitted work or commits
/// without a confirmation that names what will be lost" — rests entirely on the *absence* of
/// certain git flags. An absence is invisible in a diff, so the suite enforces it directly.
///
/// How it works: comments and string contents are lexed away first, then every array literal
/// is read as a candidate argument vector and every `.append("…")` as a one-element addition
/// to one. Two things are asked of each element: whether it is exactly one string literal
/// (which is what can name a subcommand), and which string literals it contains *anywhere*
/// (which is what gets checked against the rules). Those differ for an element like
/// `cond ? "--squash" : "--merge"`, and every literal in it is checked. Each vector is then
/// handled one of two ways:
///
/// - **Classified** — it begins with a string literal that is not a flag, so that literal is
///   the git subcommand and the per-subcommand rules apply. This is what lets `reset --merge`
///   (how a pending squash is undone) and `branch -D` (behind a second confirmation) coexist
///   with `switch --merge` and `branch -M` being fatal.
/// - **Fragment** — anything else: `arguments += ["--merge"]`, `arguments.append("--merge")`,
///   `["-C", dir, "switch", "--merge", b]`, `[repoFlag, "switch", "--ours"]`. These are
///   exactly the shapes the first version of this scanner walked straight past while
///   `createBranch` was building its vector with `var` + `+=`. A fragment cannot say which
///   subcommand it belongs to, so it is checked against `fragmentForbidden`, the union of the
///   per-subcommand rules.
///
/// Every rule above keys on a *whole token*, which is all a flag ever is — until the remote
/// milestone, where two of the things that can destroy work are not tokens at all:
///
/// - **A lease.** `--force-with-lease=refs/heads/x:<sha>` is what makes a force push safe (the
///   server refuses if the branch moved since the sheet showed that sha), and its tail is data.
///   So there is one *prefix* rule — `flagPrefixesAllowedOnlyAfter` — and, because permitting a
///   prefix promises much more than permitting a token, it is pinned to a position as well:
///   only inside an array literal classified `push`. Everywhere else, including the whole-file
///   sweep, it is a finding. The bare `--force-with-lease` — leasing against whatever the last
///   fetch left behind, which nobody was shown — stays in `alwaysForbidden` and is a finding
///   everywhere, this rule notwithstanding.
/// - **A force refspec.** `+refs/heads/x:refs/heads/x` discards the other side's commits with
///   no flag involved. `isForceRefspec` reads it out of the literal's shape; the narrowing it
///   needs, and the spellings it cannot see, are written up there.
///
/// Both work on the interpolated spelling, because the lexer keeps a literal's *raw* text:
/// `"+\(src):\(dst)"` and `"--force-with-lease=\(ref):\(sha)"` are single literals whose values
/// still contain the `+`, the `=` and the `:`. That is what the real code will write, and
/// `readsAnInterpolatedLiteralAsOneLiteralWithItsRawText` pins it.
///
/// Known limits, stated so nobody mistakes this for a proof:
///
/// - **Only literals.** This is the remaining hole, and it is now the *only* structural one:
///   a flag assembled from non-literals is invisible: `"--" + verb`,
///   `"--\(mode)"`, a `let forceFlag = "--" + "force"`, a flag read from config or passed in
///   by a caller, a `[String]` built in another function and handed over. This is the real
///   hole, and nothing short of a Swift parser plus dataflow would close it. Argument vectors
///   in `GitCore` are written as literals by convention precisely so this scanner can see
///   them; a reviewer must still read any code that departs from that.
///
///   A flag chosen by a *ternary between literals* — `["merge", cond ? "--squash" : "--ff", b]`
///   — used to be in this bucket too and no longer is: such an element has no single value, and
///   the lexer once discarded it whole rather than keeping the literals inside. Both are now
///   checked (`catchesAFlagHiddenInsideATernaryElement`). `CLIGitBackend+Merge.swift` still
///   spells each mode's vector as one complete literal chosen by a `switch`, because reading
///   what reaches git should not depend on the scanner being clever.
///
///   **Interpolation reaches the same hole by a second road.** A plain `"\(x)"` is fine — the
///   contents are blanked like any other, the literal stays one literal — but a *string literal
///   inside* an interpolation ends the outer literal as far as this lexer is concerned, so
///   `"--for\("ce")"` is read as the two literals `--for\(` and `)` and matches nothing. A flag
///   can hide there. Quote parity survives, so the rest of the file is still lexed correctly and
///   nothing desynchronises; `recordsThatAFlagSplitByAnInterpolatedLiteralIsInvisible` pins the
///   limit so that closing it is a deliberate act rather than an accident.
/// - **`-M` is exempt in one fragment shape**: `commitDiff`'s legitimate
///   `["--no-commit-id", "-p", "-U3", "-M", "-r"]` is itself a fragment and `-M` there means
///   rename detection, so an *array literal* carrying `--no-commit-id` — an option no `branch`
///   or `switch` vector has — does not have `-M` checked against it. One vector, one exemption:
///   appended literals are pooled per file rather than per vector, so they never get it.
///   Everywhere else, fragments included, `-M` is caught. A future `diff -C`/`diff -B` fragment
///   would false-positive for the mirror-image reason and must be written with its subcommand
///   first.
/// - **No idea which arrays reach git**: a non-git array starting with `"clean"`, or one
///   containing `"--force"` for an unrelated reason, is flagged anyway. That false positive
///   is the safe direction and has not come up.
/// - **Text, not Swift.** Multi-line (`"""`) and raw (`#"..."#`) string literals are not
///   understood: one unpaired `"` inside either desynchronises the lexer for the rest of the
///   file, silently. So a file containing either is *not scanned* — `findings` returns one
///   loud refusal naming the construct, and nothing else, rather than a reassuring empty list.
///   `GitCore/Sources` contains neither today.
/// - **A positional rule only sees inside the array literal.** `["reset", "--merge"] + extra`
///   reads as a two-element vector and passes, because the concatenation happens outside the
///   brackets — the same blind spot `doesNotConfuseElementsOfNestedExpressions` records for
///   every other rule. `CLIGitBackend+Abort.swift` spells that vector as a complete literal
///   with nothing appended, which is what makes the rule meaningful there.
///
///   The prefix rule's exemption has the mirror-image shape: it covers the *whole* range of a
///   `push` array literal, so a lease nested inside a sub-expression of one
///   (`["push", extra(["--force-with-lease=x"])]`) is exempted by the sweep. That is why
///   `fragmentFindings` checks the prefix rule too — the inner array is a fragment, and the
///   fragment rule has no exemption. Two findings for one hazard, in the shapes both see.
/// - **The `-d`/`--all`/`--tags`/`-p` group is subcommand-scoped, not file-wide.** Each is
///   dangerous after `push` or `fetch` and innocent after `branch`, `rev-list`, `log` or
///   `diff-tree`, and `GitCore/Sources` uses all four innocently today, so they are in the
///   per-subcommand tables and the fragment union but struck from the sweep (`sweepExempt`).
///   A vector that hides its subcommand from the scanner hides them too.
/// - **`--skip` is in `fileWideForbidden`, and `git log --skip` exists.** Nothing in
///   `GitCore/Sources` pages a log today; when something does, it will spell the option
///   `--skip=<n>` (one token, which does not match) or else be a false positive to resolve
///   here — by moving `--skip` into the per-subcommand tables — rather than by deleting the
///   rule. Same shape as the `-M` exception below.
/// - **`GitCore/Sources` only** — deliberately, since this file's own rule tables would
///   otherwise flag themselves. The app target runs no git commands of its own.
enum ForceFlagScanner {
    /// A human-readable description of each violation found in `source`, empty when clean.
    static func findings(in source: String) -> [String] {
        // Before anything else, and on the RAW text: the lexer pairs `"` characters, so a
        // multi-line or raw literal containing an unpaired quote shifts every element boundary
        // after it — silently, for the rest of the file. A scanner that has lost its place must
        // say so rather than report "clean". See `unlexableConstruct`.
        if let construct = unlexableConstruct(in: source) {
            return [
                "this file cannot be scanned: it contains \(construct), which this scanner "
                    + "does not lex. Rewrite the literal as an ordinary \"…\" string, or teach "
                    + "the lexer about it — do not leave the file unchecked."
            ]
        }

        let code = strippingCommentsAndStringContents(source)
        let arrays = argumentArrays(in: source, code: code)
        var findings: [String] = []

        // Where each classified vector sits, which only the prefix rule needs: it is the one
        // rule whose answer depends on the literal's surroundings rather than on the literal.
        let classified: [(range: Range<Int>, subcommand: String)] = arrays.compactMap {
            guard let first = $0.elements.first?.value, !first.hasPrefix("-") else { return nil }
            return (range: $0.range, subcommand: first)
        }

        for (token, literal) in literals(in: source, code: code) {
            if fileWideForbidden.contains(literal) {
                findings.append("forbidden literal \(literal.debugDescription) (offset \(token))")
            }
            if let rule = prefixRule(matching: literal),
                !classified.contains(where: {
                    $0.range.contains(token) && rule.subcommands.contains($0.subcommand)
                })
            {
                findings.append(
                    "forbidden literal \(literal.debugDescription) (offset \(token)): "
                        + rule.reason)
            }
            if isForceRefspec(literal) {
                findings.append(
                    "forbidden force refspec \(literal.debugDescription) (offset \(token)): "
                        + forceRefspecReason)
            }
        }

        for array in arrays {
            let arguments = array.elements
            // Every literal in every element, not one per element: a flag chosen by a ternary
            // (`cond ? "--squash" : "--merge"`) lives in an element that has no single value,
            // and used to be skipped entirely. Order is preserved, and a classified array's
            // first element holds exactly one literal, so `dropFirst()` below still drops the
            // subcommand and nothing else.
            let literals = arguments.flatMap(\.literals)

            // Classified only when the array begins with a literal that is not itself a flag.
            // Anything else — `a += ["--merge"]`, `[repoFlag, "switch", "--ours"]`,
            // `["-C", dir, "switch", "--merge", b]`, `[cond ? "--ff" : "--no-ff", b]` — is a
            // FRAGMENT: it cannot be attributed to a subcommand, so it is checked against the
            // union instead.
            guard let subcommand = arguments.first?.value, !subcommand.hasPrefix("-") else {
                findings += fragmentFindings(literals, isOneVector: true)
                continue
            }

            if let reason = forbiddenSubcommands[subcommand] {
                findings.append("forbidden git subcommand \(subcommand.debugDescription): \(reason)")
                continue
            }
            // Over ELEMENTS, not over the flat literal list, because one rule is positional:
            // `reset --merge` is safe and `reset --merge <commit>` moves HEAD, and only the
            // element index can tell them apart. A classified array's first element holds
            // exactly one literal (the subcommand), so `dropFirst()` still drops it and
            // nothing else.
            for (index, element) in arguments.enumerated().dropFirst() {
                for flag in element.literals {
                    if let reason = (forbiddenFlags[subcommand] ?? [:])[flag] {
                        findings.append("forbidden `git \(subcommand) \(flag)`: \(reason)")
                    } else if let rule = flagsAllowedOnlyAfter[flag] {
                        findings += rule.findings(
                            for: flag, after: subcommand,
                            isLastElement: index == arguments.count - 1)
                    } else if let rule = prefixRule(matching: flag),
                        !rule.subcommands.contains(subcommand)
                    {
                        findings.append("forbidden `git \(subcommand) \(flag)`: \(rule.reason)")
                    }
                    // Inside a vector that talks to a server, a leading `+` can only be a
                    // refspec — git has no `+`-leading option — so the narrowing
                    // `isForceRefspec` needs elsewhere (where `"+"` is a diff marker) is off
                    // here, and `["push", r, "+" + src + ":" + dst]` is caught by its `"+"`.
                    if refspecSubcommands.contains(subcommand), flag.hasPrefix("+"),
                        !isForceRefspec(flag)
                    {
                        findings.append(
                            "forbidden force refspec \(flag.debugDescription) in a "
                                + "`git \(subcommand)` vector: \(forceRefspecReason)")
                    }
                }
            }
        }

        // `arguments.append("--merge")` is the same hazard written a different way. These
        // literals come from every `.append("…")` in the FILE, pooled, so they are not one
        // vector and get no carve-out — see `fragmentFindings`.
        findings += fragmentFindings(appendedLiterals(in: source, code: code), isOneVector: false)
        return findings
    }

    /// - Parameter isOneVector: whether `literals` are the elements of a single array literal.
    ///   Only then can one of them vouch for another.
    private static func fragmentFindings(_ literals: [String], isOneVector: Bool) -> [String] {
        // The one carve-out, and it is the fragment's own shape rather than a token struck from
        // the union: `--no-commit-id` is a `diff-tree`/`diff-index` option, so an array literal
        // carrying it is one of `commitDiff`/`commitFiles`' argument lists and its `-M` is
        // rename detection. `branch` and `switch` have no such option, so within one vector this
        // cannot excuse a `branch -M` — which the global `.subtracting(["-M"])` it replaces did
        // excuse, everywhere.
        //
        // It applies to array literals only. The appended literals are pooled per file, not per
        // vector, so a `--no-commit-id` appended to one list would otherwise excuse a `-M`
        // appended to an unrelated `branch` one — the same hole in a smaller room. No
        // `.append("…")` in `GitCore/Sources` is part of a `diff-tree` list today (`git grep`:
        // the appended literals there are `--unidiff-zero`, `--reverse`, `-a` and `--amend`), so
        // withholding it costs nothing; a future one must spell its vector as a literal.
        let forbidden =
            isOneVector && literals.contains(diffTreeMarker)
            ? fragmentForbidden.subtracting(diffTreeExempt) : fragmentForbidden
        var result = literals.filter(forbidden.contains).map {
            "forbidden flag \($0.debugDescription) in an argument fragment"
        }
        // A prefixed flag in a fragment. The whole-file sweep catches most of these already —
        // a fragment's literals are the file's literals — but not one nested *inside* a
        // classified vector (`["push", extra(["--force-with-lease=x"])]`), which the sweep
        // exempts by offset. Saying it twice for the shapes both see is the cheaper mistake.
        result += literals.compactMap { literal in
            guard let rule = prefixRule(matching: literal) else { return nil }
            return "forbidden flag \(literal.debugDescription) in an argument fragment: "
                + rule.reason
        }
        return result
    }

    /// The option that identifies a `diff-tree` argument fragment. See `fragmentFindings`.
    private static let diffTreeMarker = "--no-commit-id"

    /// What that fragment is excused: `-M` is rename detection there and `-p` is the patch
    /// option, not `branch -M` and not `fetch -p`. Both tokens are dangerous under their own
    /// subcommands, which is why they are in the union at all.
    private static let diffTreeExempt: Set<String> = ["-M", "-p"]

    /// What the lexer provably cannot read, found in the raw source.
    ///
    /// Deliberately crude, and deliberately over-strict: it looks at the text before comments
    /// are stripped, because stripping is the very step that goes wrong, so a `"""` inside a
    /// doc comment refuses the file too. That is the price of a rule that cannot itself be
    /// fooled, and it is not a price anyone pays today — `GitCore/Sources` contains neither
    /// construct, which `gitCoreSourcesContainOnlyLexableStringLiterals` pins.
    static func unlexableConstruct(in source: String) -> String? {
        if source.contains("\"\"\"") { return "a multi-line string literal (\"\"\")" }
        if source.contains("#\"") { return "a raw string literal (#\"…\"#)" }
        return nil
    }

    /// Every `.swift` file under `GitCore/Sources`, keyed by path relative to that directory.
    static func gitCoreSources(root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return result }
        for case let relativePath as String in enumerator where relativePath.hasSuffix(".swift") {
            let url = root.appendingPathComponent(relativePath)
            result[relativePath] = try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    // MARK: - The rules

    /// Tokens that are fatal wherever they appear, whatever command they belong to.
    ///
    /// `--quit` and `--skip` are the sequencer's other two exits and neither is ever what
    /// Gitter's "Abort" means: `--quit` drops the cherry-pick/revert/rebase state while leaving
    /// its half-applied result staged (an operation the user can no longer see, let alone
    /// abort), and `--skip` throws away the commit git stopped on.
    /// `-B` is here because the README and the design doc have both claimed it was scanned
    /// since the milestone began, and it was not: `git checkout -B` / `git branch -B`
    /// force-creates a branch over an existing one. Nothing in `GitCore/Sources` uses it, so
    /// this costs nothing today. `git diff -B` (break-rewrites) is the future false positive
    /// waiting to happen, and it resolves the same way `-M` did: spell the vector with its
    /// subcommand first, and move the token into the per-subcommand table.
    static let alwaysForbidden: Set<String> = [
        "--force", "-f", "--force-with-lease", "--discard-changes", "--hard", "--ignore-unmerged",
        "--quit", "--skip", "-B",
    ]

    /// Subcommands Gitter must never run at all. `checkout` is here because `git checkout --
    /// <path>` overwrites a file with no confirmation and no recovery; `switch` and `restore
    /// --staged` cover everything Gitter legitimately needs.
    /// `pull` is here from the remote milestone: it fetches and then merges or rebases in one
    /// step decided by config Gitter did not write, so the user is told afterwards what
    /// happened to their work. The store fetches, re-reads tracking, shows a sheet and then
    /// merges or rebases itself, which is the only way the sheet can say what will happen.
    static let forbiddenSubcommands: [String: String] = [
        "clean": "deletes untracked files outright",
        "stash": "moves the user's changes somewhere they did not ask for",
        "checkout": "`checkout -- <path>` discards a file's changes with no undo",
        "pull": "fetches and then merges or rebases in one step the user was never shown",
    ]

    /// Per-subcommand flags. The allow-list is what is *absent* here: `branch -D` (behind a
    /// second confirmation), the `--abort` family, and `reset --merge` (undoing a pending
    /// squash) are all permitted, and later tasks in this milestone add them.
    static let forbiddenFlags: [String: [String: String]] = [
        "switch": [
            "-f": "force", "--force": "force", "--discard-changes": "throws local changes away",
            "-C": "force-creates over an existing branch", "--merge": "merges local changes in silently",
            "--ours": "resolves conflicts by discarding one side",
            "--theirs": "resolves conflicts by discarding one side",
        ],
        "branch": [
            "-M": "force-renames over an existing branch", "-C": "force-copies over an existing branch",
            "--force": "force", "-f": "force",
        ],
        "reset": ["--keep": "can still discard local changes"],  // `--hard` is always forbidden
        "restore": [
            "--worktree": "overwrites files on disk", "-W": "overwrites files on disk",
            "--source": "overwrites files on disk from another commit",
        ],
        "merge": [
            "-f": "force", "--force": "force",
            "-X": "a strategy option resolves conflicts by discarding one side",
            "--strategy-option": "resolves conflicts by discarding one side",
            "--autostash": "moves the user's changes somewhere they did not ask for",
            "--allow-unrelated-histories": "overrides a refusal the user should see instead",
        ],
        // The server-side tables. What is *absent* is again the point: `--porcelain`, `-u` and
        // an explicit `<src>:<dst>` refspec are how every push this milestone makes is written,
        // and `--force-with-lease=<ref>:<sha>` is permitted here and only here (see
        // `flagPrefixesAllowedOnlyAfter`).
        "push": [
            "--force": "discards commits on the remote branch with no lease and no confirmation",
            "-f": "discards commits on the remote branch with no lease and no confirmation",
            "--mirror": "replaces every ref on the remote with the local ones, deletions included",
            "--prune": "deletes remote branches that have no local counterpart",
            "--all": "pushes branches the user never named",
            "--tags": "pushes tags the user never named",
            "--delete": "deletes a remote branch; Gitter does that behind its own confirmation",
            "-d": "deletes a remote branch; Gitter does that behind its own confirmation",
            "--no-verify": "skips the hooks the user installed to stop exactly this",
            "--force-if-includes":
                "weakens a lease into 'force unless I have not fetched', which is not the "
                + "sha the confirmation sheet showed",
        ],
        "fetch": [
            "--force": "overwrites remote-tracking refs that are not ancestors",
            "-f": "overwrites remote-tracking refs that are not ancestors",
            "--prune": "deletes remote-tracking refs behind the user's back",
            "-p": "deletes remote-tracking refs behind the user's back",
            "--prune-tags": "deletes local tags",
            "--tags": "fetches refs the user never asked for, and can clobber local tags",
        ],
        "rebase": [
            "--autostash": "moves the user's changes somewhere they did not ask for",
            "--skip": "throws away the commit git stopped on",
            "--quit": "leaves the rebase's half-applied result behind with no way to abort it",
            "-f": "force",
            "--force-rebase": "rewrites commits that did not need rewriting",
            "--no-verify": "skips the hooks the user installed to stop exactly this",
        ],
    ]

    /// A flag that is safe **only** after certain subcommands — and, for `--merge`, only in a
    /// certain position.
    struct PositionalRule {
        let subcommands: Set<String>
        /// Whether the flag must be the vector's **last** element.
        ///
        /// `git reset --merge` resets the index to HEAD. `git reset --merge <commit>` resets it
        /// to `<commit>` *and moves HEAD there* — a different command entirely, and one that
        /// can lose commits. Nothing but the argument after the flag distinguishes them, so the
        /// allow-list has to be able to say "this flag, and then nothing".
        let mustBeLast: Bool

        func findings(for flag: String, after subcommand: String, isLastElement: Bool) -> [String] {
            if !subcommands.contains(subcommand) {
                return [
                    "forbidden `git \(subcommand) \(flag)`: \(flag) is allowed only after "
                        + subcommands.sorted().joined(separator: ", ")
                ]
            }
            if mustBeLast, !isLastElement {
                return [
                    "forbidden `git \(subcommand) \(flag) …`: \(flag) must be the last argument; "
                        + "what follows it is a revision, and moves HEAD"
                ]
            }
            return []
        }
    }

    /// Flags that are safe **only** after the subcommands listed, and dangerous everywhere
    /// else. This is the allow-list this milestone's abort work needs, written positionally so
    /// that permitting `git merge --abort` did not quietly permit `git switch --abort` too.
    ///
    /// - `--abort` undoes the operation it belongs to, and only those five subcommands have
    ///   one. After anything else it is at best not a flag git knows. It is not `mustBeLast`:
    ///   none of the five accepts an argument after it, so a trailing element would be a git
    ///   usage error rather than a way to lose work.
    /// - `--merge` is how a pending squash is undone (`git reset --merge`, and *only* that
    ///   exact vector — see `mustBeLast`). After `switch` it silently merges local changes into
    ///   a checkout, and after `rebase` it selects a backend Gitter does not choose for the
    ///   user. `switch` keeps its own entry in `forbiddenFlags` as well, for the better
    ///   message; the two never both fire on one element.
    ///
    /// Every key here is also part of `fragmentForbidden`: a fragment cannot say which
    /// subcommand it will be appended to, so it cannot prove it is one of the allowed ones.
    static let flagsAllowedOnlyAfter: [String: PositionalRule] = [
        "--abort": PositionalRule(
            subcommands: ["merge", "cherry-pick", "revert", "rebase", "am"], mustBeLast: false),
        "--merge": PositionalRule(subcommands: ["reset"], mustBeLast: true),
    ]

    /// A flag whose *beginning* is fixed and whose tail is data, safe only after certain
    /// subcommands.
    ///
    /// `PositionalRule` cannot express this: it keys on the whole token, and the whole token
    /// here is `--force-with-lease=refs/heads/x:<40 hex>`, built from the sha the confirmation
    /// sheet showed. Permitting a prefix is a much larger promise than permitting a token, so
    /// it is paid for by pinning the position: only inside an array literal classified `push`.
    struct PrefixRule {
        let prefix: String
        let subcommands: Set<String>

        var reason: String {
            "\(prefix)… is allowed only as an element of a vector classified "
                + subcommands.sorted().joined(separator: ", ")
        }
    }

    /// The one prefix rule, and the reason it has to exist.
    ///
    /// A force push is this milestone's most destructive action, and the lease is what makes it
    /// safe: `--force-with-lease=<ref>:<sha>` tells the server "only if that branch is still at
    /// the sha my sheet showed", so a branch that moved while the sheet was open is refused by
    /// git itself rather than overwritten. The bare `--force-with-lease` is the opposite — it
    /// leases against whatever the last fetch happened to leave in the remote-tracking ref,
    /// which may be minutes stale and was never shown to anyone — so it stays in
    /// `alwaysForbidden` and is a finding wherever it appears, this table notwithstanding.
    ///
    /// Only `push` can be vouched for. `git fetch --force-with-lease` is not a thing git has;
    /// a literal beginning `--force-with-lease=` anywhere else is either a flag about to be
    /// handed to the wrong command or a lease travelling too far from the vector that will use
    /// it to be read in one place, and both are findings.
    static let flagPrefixesAllowedOnlyAfter: [PrefixRule] = [
        PrefixRule(prefix: "--force-with-lease=", subcommands: ["push"])
    ]

    /// The prefix rule a literal falls under, if any.
    static func prefixRule(matching literal: String) -> PrefixRule? {
        flagPrefixesAllowedOnlyAfter.first { literal.hasPrefix($0.prefix) }
    }

    /// Whether a literal is a *force refspec* — `+<src>:<dst>`, which tells the server to
    /// update the ref even when the update is not a fast-forward. The same loss as `--force`,
    /// spelled as data, and no flag table can see it.
    ///
    /// "Any literal beginning `+`" would be the rule, and it is the rule the spec asks for, but
    /// `GitCore/Sources` is full of innocent ones: `PatchBuilder+Markers` writes `"+" + text`
    /// for an added line, `DiffParser` tests `hasPrefix("+++ ")` and `hasPrefix("+")`,
    /// `StatusParser` reads `"+N"` from an ahead count (`git grep '"+'`: six of them, all in
    /// diff and status code). So the rule is narrowed to the two shapes a refspec has and an
    /// ordinary diff marker does not — a `:` separating the two sides, or an explicit
    /// `+refs/…`/`+HEAD` source — and widened again inside `push`/`fetch` vectors, where a
    /// leading `+` cannot be anything else (see `refspecSubcommands`, and `findings(in:)`).
    ///
    /// The interpolated spelling is covered because the lexer keeps a literal's raw text:
    /// `"+\(src):\(dst)"` is the value `+\(src):\(dst)`, which contains a `:`.
    ///
    /// What it cannot catch, stated plainly: `"+" + spec` or `arguments.append("+" + ref)`
    /// *outside* a `push`/`fetch` vector — the literal is just `"+"`, indistinguishable from a
    /// diff marker; a one-sided `"+\(branch)"` in the same place; and anything where the `+`
    /// itself is not a literal (`"\(sign)refs/heads/x"`, `String(plus) + spec`). The vectors
    /// that talk to a server are written as array literals beginning with their subcommand
    /// precisely so the wider rule applies to them.
    static func isForceRefspec(_ literal: String) -> Bool {
        guard literal.hasPrefix("+") else { return false }
        return literal.contains(":") || literal.hasPrefix("+refs/") || literal.hasPrefix("+HEAD")
    }

    /// Where *any* leading `+` is a refspec rather than a diff marker. Git has no `+`-leading
    /// option, so inside these two vectors the narrowing above is not needed.
    static let refspecSubcommands: Set<String> = ["push", "fetch"]

    static let forceRefspecReason =
        "a refspec beginning `+` forces the update git would otherwise refuse, discarding "
        + "commits on the other side with no lease and no confirmation"

    /// What a *fragment* is checked against: the union of every table above, because a
    /// fragment by definition cannot say which subcommand it will be appended to.
    ///
    /// Nothing is subtracted here any more. `-M` used to be, globally, to spare one
    /// `diff-tree` argument list — which meant `branch -M` assembled away from its subcommand
    /// was unreachable by every rule at once. The exemption now lives in `fragmentFindings`
    /// and is keyed on that list's own `--no-commit-id`, so it covers the fragment it was
    /// written for and nothing else. A future `diff -C`/`diff -B` fragment is the mirror image
    /// and resolves the same way: spell the array with its subcommand first so it is
    /// classified, or give it a marker of its own here with the reasoning written down.
    static let fragmentForbidden: Set<String> =
        Set(forbiddenFlags.values.flatMap(\.keys))
        .union(alwaysForbidden)
        .union(flagsAllowedOnlyAfter.keys)

    /// What the whole-file sweep checks every string literal against, wherever it sits.
    ///
    /// The sweep used to be `alwaysForbidden` alone, which left everything a per-subcommand
    /// rule covers invisible the moment it stopped being a literal *inside* an argument array:
    /// `let resolve = "--ours"; run(["merge", resolve, b])` and `a.append("clean")` both
    /// passed. It is now the fragment union plus the forbidden subcommands, less the only two
    /// groups that have legitimate uses in `GitCore/Sources` — and each subtraction is a fact
    /// about this codebase, checked with `git grep`, not a softening of the rule:
    ///
    /// - **`--abort` and `--merge`** are exactly what `CLIGitBackend+Abort.swift` runs. They
    ///   stay dangerous everywhere the *positional* rule can see them, which is the whole
    ///   point of `flagsAllowedOnlyAfter`; a sweep over them would fail on correct code.
    /// - **`-M`, `-p`, `-d`, `--all` and `--tags`** each mean something harmless under a
    ///   subcommand `GitCore/Sources` really uses, and the sweep cannot see the subcommand:
    ///   `-M`/`-p` are `diff-tree`'s rename detection and patch output (`CLIGitBackend.swift`),
    ///   `-d` is `git branch -d`, the safe delete (`+BranchDelete.swift`), and `--all`/`--tags`
    ///   are `rev-list`/`log` selectors in the "would this commit be unreferenced" counts. Each
    ///   was checked with `git grep '"<token>"' -- GitCore/Sources` before the token joined the
    ///   union, and each of those five call sites is an array literal *beginning with its
    ///   subcommand*, so the per-subcommand rules still see them for what they are. Same
    ///   reasoning as `fragmentFindings`' carve-out, which is narrower but cannot help here:
    ///   the sweep has no array to look at.
    ///
    /// Say the consequence plainly, because these subtractions are the sweep's price and it
    /// is not zero: `let flag = "--abort"`, `"--merge"`, `"-M"`, `"-p"`, `"-d"`, `"--all"` or
    /// `"--tags"`, used as a non-literal array element, is seen by **no rule at all** — the
    /// sweep skips the token and the array rules see an element with no literal in it. Seven
    /// tokens wide rather than the whole union it used to be, but narrower, not closed.
    ///
    /// Everything else in the union — `checkout`, `clean`, `stash`, `pull`, `--ours`, `-C`,
    /// `-X`, `--autostash`, `--mirror`, `--prune`, `--prune-tags`, `--delete`, `--no-verify`,
    /// `--force-if-includes`, `--force-rebase` and the rest — appears in no source file, so
    /// widening onto them produced no false positive
    /// (`gitCoreSourcesContainNoForceFlags` is the standing proof).
    static let fileWideForbidden: Set<String> =
        fragmentForbidden
        .subtracting(flagsAllowedOnlyAfter.keys)
        .subtracting(sweepExempt)
        .union(forbiddenSubcommands.keys)

    /// Tokens the sweep must skip because `GitCore/Sources` uses each of them legitimately,
    /// under a subcommand the sweep cannot see. Every entry is a fact about this codebase,
    /// checked with `git grep`, not a softening of the rule — see `fileWideForbidden`.
    static let sweepExempt: Set<String> = ["-M", "-p", "-d", "--all", "--tags"]
}
