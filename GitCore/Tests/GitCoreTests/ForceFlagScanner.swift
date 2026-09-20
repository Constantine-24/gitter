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
/// - **`-M` is not in the fragment union**, because `commitDiff`'s legitimate
///   `["--no-commit-id", "-p", "-U3", "-M", "-r"]` is itself a fragment and `-M` there means
///   rename detection. `branch -M` is still caught in a classified array. A future
///   `diff -C`/`diff -B` fragment would false-positive for the mirror-image reason and must
///   be written with its subcommand first.
/// - **No idea which arrays reach git**: a non-git array starting with `"clean"`, or one
///   containing `"--force"` for an unrelated reason, is flagged anyway. That false positive
///   is the safe direction and has not come up.
/// - **Text, not Swift.** Multi-line (`"""`) and raw (`#"..."#`) string literals are not
///   understood and could shift element boundaries; `GitCore/Sources` contains neither, and
///   the whole-file sweep for always-forbidden tokens still fires wherever they sit.
/// - **A positional rule only sees inside the array literal.** `["reset", "--merge"] + extra`
///   reads as a two-element vector and passes, because the concatenation happens outside the
///   brackets — the same blind spot `doesNotConfuseElementsOfNestedExpressions` records for
///   every other rule. `CLIGitBackend+Abort.swift` spells that vector as a complete literal
///   with nothing appended, which is what makes the rule meaningful there.
/// - **`--skip` is in `alwaysForbidden`, and `git log --skip` exists.** Nothing in
///   `GitCore/Sources` pages a log today; when something does, it will spell the option
///   `--skip=<n>` (one token, which does not match) or else be a false positive to resolve
///   here — by moving `--skip` into the per-subcommand tables — rather than by deleting the
///   rule. Same shape as the `-M` exception below.
/// - **`GitCore/Sources` only** — deliberately, since this file's own rule tables would
///   otherwise flag themselves. The app target runs no git commands of its own.
enum ForceFlagScanner {
    /// A human-readable description of each violation found in `source`, empty when clean.
    static func findings(in source: String) -> [String] {
        let code = strippingCommentsAndStringContents(source)
        var findings: [String] = []

        for (token, literal) in literals(in: source, code: code) where alwaysForbidden.contains(literal) {
            findings.append("forbidden literal \(literal.debugDescription) (offset \(token))")
        }

        for arguments in argumentArrays(in: source, code: code) {
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
                findings += fragmentFindings(literals)
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
                    }
                }
            }
        }

        // `arguments.append("--merge")` is the same hazard written a different way.
        findings += fragmentFindings(appendedLiterals(in: source, code: code))
        return findings
    }

    private static func fragmentFindings(_ literals: [String]) -> [String] {
        literals.filter(fragmentForbidden.contains).map {
            "forbidden flag \($0.debugDescription) in an argument fragment"
        }
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
    static let alwaysForbidden: Set<String> = [
        "--force", "-f", "--force-with-lease", "--discard-changes", "--hard", "--ignore-unmerged",
        "--quit", "--skip",
    ]

    /// Subcommands Gitter must never run at all. `checkout` is here because `git checkout --
    /// <path>` overwrites a file with no confirmation and no recovery; `switch` and `restore
    /// --staged` cover everything Gitter legitimately needs.
    static let forbiddenSubcommands: [String: String] = [
        "clean": "deletes untracked files outright",
        "stash": "moves the user's changes somewhere they did not ask for",
        "checkout": "`checkout -- <path>` discards a file's changes with no undo",
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

    /// What a *fragment* is checked against: the union of every table above, because a
    /// fragment by definition cannot say which subcommand it will be appended to.
    ///
    /// `-M` is the one deliberate omission. `CLIGitBackend.commitDiff` and `commitFiles`
    /// build `["--no-commit-id", "-p", "-U3", "-M", "-r"]` — a leading-flag fragment whose
    /// `-M` is `diff-tree`'s rename detection, nothing like `branch -M`. Including it would
    /// mean a permanent false positive on existing, correct code, so `-M` stays dangerous
    /// only in a `branch`-classified array. Same reasoning would apply to a future
    /// `diff -C`/`diff -B` fragment: those two ARE in the union today (nothing in
    /// `GitCore/Sources` uses them), and adding such a fragment would mean spelling the array
    /// with its subcommand first so it gets classified.
    static let fragmentForbidden: Set<String> =
        Set(forbiddenFlags.values.flatMap(\.keys))
        .union(alwaysForbidden)
        .union(flagsAllowedOnlyAfter.keys)
        .subtracting(["-M"])
}
