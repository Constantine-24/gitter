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
/// milestone, where the things that can destroy work stop being tokens:
///
/// - **A lease.** `--force-with-lease=refs/heads/x:<sha>` is what makes a force push safe (the
///   server refuses if the branch moved since the sheet showed that sha), and its tail is data.
///   So there is one *prefix* rule — `flagPrefixesAllowedOnlyAfter` — and, because permitting a
///   prefix promises much more than permitting a token, both the literal's **shape** and its
///   **position** are pinned: `isPermittedLease` demands one literal with a non-empty ref, a
///   `:` where git splits on one, and an expected value that is exactly one interpolation, and
///   `findings(in:)` demands that it stand as a **lone-literal element** of an array literal
///   classified `push`. Everything else beginning
///   `--force-with-lease=` — a bare `=<ref>` leasing against the remote-tracking ref this app's
///   own fetch rewrites, an empty `=<ref>:` meaning "must not exist", a hard-coded sha that
///   cannot have come from the sheet, a concatenated `"--force-with-lease=" + x`, a lease that
///   is one arm of a ternary and so a lease only half the time — is a
///   finding. The bare `--force-with-lease` stays in `alwaysForbidden` on top of that.
/// - **A force refspec.** `+refs/heads/x:refs/heads/x` discards the other side's commits with
///   no flag involved. `isForceRefspec` reads it out of the literal's shape; the narrowing it
///   needs, and the spellings it cannot see, are written up there.
/// - **A delete refspec.** `:refs/heads/x` deletes the branch on the server — `push --delete`
///   with no flag to deny. `deleteRefspecPrefix` catches it file-wide; as an *element* of a
///   `push` vector *any* leading `:` counts, unless that same vector carries a permitted lease
///   of its own, which is how Gitter's own "Delete on <remote>" is written. See
///   `deleteRefspecReason`.
/// - **A word.** `git remote prune|remove|rm|set-url|rename|add|update|set-head|set-branches`
///   rewrites the user's remotes, and not one of them is a flag. Two rules, because one cannot
///   do it: `allowedShapes` inverts the rule for a vector the scanner managed to classify —
///   the permitted vectors are listed whole, and `["remote", "-v"]` is the only `remote` one
///   (`stash` and `restore` joined the table in the working-copy milestone) — while
///   `remoteWordsForbiddenEverywhere` and `remoteWordsForbiddenInFragments` forbid the words
///   themselves, because a vector that hides its shape (`[repoFlag, "remote", "rm", r]`, or a
///   word appended on its own) is beyond any shape rule by construction.
/// - **A file.** `read-tree`, `update-index` and `write-tree` rewrite whichever index
///   `GIT_INDEX_FILE` names — the real one when it names none — and no scanner can see an
///   environment. They are findings in every file but `recordFile`, the one that owns the
///   temporary index: the first rule here that asks *where* a literal is written, which is why
///   `findings` takes a file name.
/// - **A file that runs `stash`.** A shape is read from one array literal, so in a file that
///   names `stash` every git vector — stash or not — is written as one array literal,
///   optionally followed by `+ paths`, and each stash vector inline in `run(`/
///   `runWithEnvironment(`. There, `--`, `--staged`/`-S`, `--all`/`-a`, `--keep-index`/`-k`,
///   `-p`/`--patch` and `--index` added in a fragment, an `.append` or an `.insert` are findings
///   even when the vector they join is, say, `update-index`: this scanner cannot tell which
///   vector they join. See `stashWordsForbiddenOutsideAVector` and `isInlineArgumentOfRun`.
/// - **A format.** A `git diff` that prints a patch is parsed, and staged or discarded from, so
///   the user's `diff.*` config must not reshape it: every such classified vector carries
///   `diffFormatPins` before its `--`, and nothing that takes one back. Not a force flag, but
///   the same kind of absence. See `diffFormatFindings`.
/// - **A hiding place.** `["-c", "push.default=matching", "push", r]` is a complete git command
///   that this scanner reads as a fragment, losing every per-subcommand rule at once. An array
///   literal beginning with one of `globalOptionsBeforeSubcommand` is therefore a finding
///   outright: pass a working directory instead.
///
/// Both work on the interpolated spelling, because the lexer keeps a literal's *raw* text:
/// `"+\(src):\(dst)"` and `"--force-with-lease=\(ref):\(sha)"` are single literals whose values
/// still contain the `+`, the `=` and the `:`. That is what the real code will write, and
/// `readsAnInterpolatedLiteralAsOneLiteralWithItsRawText` pins it.
///
/// **What this scanner covers, said plainly, because a list is not a proof.** It knows a list
/// of subcommands and a list of flags, both written out below by hand. Everything git can do
/// that is not on those lists is **unchecked**: `git update-ref -d` deletes a ref with no
/// reflog entry and no confirmation; `git reflog expire --expire=now --all` destroys the very
/// history that makes an accidental reset recoverable; `git gc --prune=now` then collects the
/// objects. None of the three is a finding today, and each would pass this suite. They are in
/// `docs/BACKLOG.md` under the scanner entry. The rule for adding one is the rule every entry
/// below followed: `git grep` the sources for false positives first, then a failing probe,
/// then the table. Treat this as "the ways we have thought of", not "the ways there are".
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
///
///   **Unicode escapes are the one road now closed.** `"\u{2d}\u{2d}force"` has the raw value
///   `\u{2d}\u{2d}force` and matched no table; `spellings(of:)` now checks the decoded text as
///   well, which cost nothing because every `\u{…}` in `GitCore/Sources` is `"\u{0}"`. A flag
///   split *across* two escaped literals is still a concatenation, and still invisible.
/// - **`-M` and `-p` are exempt in one fragment shape**: `commitDiff`'s legitimate
///   `["--no-commit-id", "-p", "-U3", "-M", "-r"]` is itself a fragment and those tokens there
///   mean rename detection and patch output, so an *array literal* carrying `--no-commit-id` —
///   an option no `branch` or `switch` vector has — does not have them checked against it.
///   Narrowly: appended literals are pooled per file rather than per vector, so they never get
///   the exemption, and a fragment that names a subcommand of its own does not get it either
///   (`[repoFlag, "branch", "--no-commit-id", "-M", a, b]` was clean until fix round 1, while
///   this comment claimed it could not be — a `diff-tree` list carries options only, so
///   refusing the carve-out to any fragment containing a subcommand name costs it nothing).
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
///   The two *permissions* used to have the mirror-image shape, and no longer do. Each covered
///   the whole offset range of a `push` array literal, so anything nested in a sub-expression
///   of one — a lease in `["push", extra(["--force-with-lease=x"])]`, a delete refspec in
///   `["push", lease, extra([":refs/heads/x"])]` — was exempted by the sweep while being no
///   element of the vector at all (and the inner array, classified by its own first element,
///   is not even a fragment). Both now ask for a lone-literal *element* of the vector, which is
///   the only thing a vector can speak for. `fragmentFindings` still checks the prefix rule as
///   well: two findings for one hazard, in the shapes both see, is the cheaper mistake.
/// - **The `-M`/`-p`/`-d`/`--all`/`--tags` group is subcommand-scoped, not file-wide.** Five
///   tokens, one per entry in `sweepExempt`. Each is dangerous after one subcommand (`branch
///   -M`, `fetch -p`, `push -d`, `push --all`, `push --tags`) and innocent after another
///   (`diff -M`, `diff-tree -p`, `branch -d`, `log --all`, `rev-list --tags`), and
///   `GitCore/Sources` uses all five innocently today, so they are in the per-subcommand
///   tables and the fragment union but struck from the sweep. A vector that hides its
///   subcommand from the scanner hides them too.
/// - **`--skip` is in `fileWideForbidden`, and `git log --skip` exists.** Nothing in
///   `GitCore/Sources` pages a log today; when something does, it will spell the option
///   `--skip=<n>` (one token, which does not match) or else be a false positive to resolve
///   here — by moving `--skip` into the per-subcommand tables — rather than by deleting the
///   rule. Same shape as the `-M` exception below. Since A2 Task 3 the sweep stands down for
///   it in exactly three whole vectors, `skipShapes` — Skip's `rebase|cherry-pick --skip`
///   and `revert --skip --no-reference` — and nowhere else.
/// - **`GitCore/Sources` only** — deliberately, since this file's own rule tables would
///   otherwise flag themselves. The app target runs no git commands of its own.
enum ForceFlagScanner {
    /// A human-readable description of each violation found in `source`, empty when clean.
    ///
    /// - Parameter fileName: the file's path relative to `Sources/GitCore`, for the one rule
    ///   that is per file (`recordOnlySubcommands`). Nil is a file that is not the record's.
    static func findings(in source: String, fileName: String? = nil) -> [String] {
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

        // Which arrays match one of their subcommand's allowed shapes, decided once, before the
        // sweep: an element a matched shape pins (`"--worktree"` in a discard literal) is
        // vouched for by that shape, and the sweep stands down for it and for nothing else.
        let matchedShapes = arrays.map(matchesAllowedShape)
        var vouched = Set<Int>()
        for (array, shape) in zip(arrays, matchedShapes) {
            guard let shape else { continue }
            // The subcommand too: `stash` is a finding file-wide (a `let sub = "stash"` would
            // otherwise run any shape at all), so the shape that matched speaks for its own.
            if let offset = array.elements.first?.valueOffset { vouched.insert(offset) }
            for (slot, element) in zip(shape.slots, array.elements.dropFirst()) {
                if case .data = slot { continue }
                if let offset = element.valueOffset { vouched.insert(offset) }
            }
        }

        let isRecordFile = fileName == recordFile
        // Whether this file runs `stash` at all: then the words that turn an allowed stash shape
        // into a forbidden one are findings wherever no vector holds them. See
        // `stashWordsForbiddenOutsideAVector`.
        let namesStash = literals(in: source, code: code)
            .contains { spellings(of: $0.1).contains("stash") }
        var outsideAVector: [String] = []

        // Which literals a `push` vector can speak for, which is what the two position-dependent
        // rules need: the lease's permission, and the delete refspec's stand-down in favour of
        // the array rule that can see the lease guarding it.
        //
        // "Inside a `push` array literal" was the old answer, by offset range, and it is too
        // generous by exactly one shape: a literal nested in a sub-expression of the vector
        // (`["push", lease, extra([":refs/heads/x"])]`) sits inside the range while being no
        // element of the vector at all, so the sweep stood down for it and the array rule
        // excused it by the lease. Both rules are *permissions*, and a permission has to name
        // the element it is given to — so it is the vector's own lone-literal elements.
        let pushVectorElements: Set<Int> = Set(
            arrays
                .filter { $0.elements.first?.value.map(decoded) == "push" }
                .flatMap { $0.elements.compactMap(\.valueOffset) })

        for (token, literal) in literals(in: source, code: code) {
            let isAPushElement = pushVectorElements.contains(token)
            let isVouched = vouched.contains(token)
            for spelling in spellings(of: literal) {
                if fileWideForbidden.contains(spelling), !isVouched {
                    let why =
                        remoteWordsForbiddenEverywhere.contains(spelling)
                        ? ": \(remoteWordReason)"
                        : stashWordsForbiddenEverywhere.contains(spelling)
                            ? ": \(stashWordReason)" : ""
                    findings.append(
                        "forbidden literal \(spelling.debugDescription) (offset \(token))\(why)")
                }
                if spelling.hasPrefix(restoreSourcePrefix), !isVouched {
                    findings.append(
                        "forbidden literal \(spelling.debugDescription) (offset \(token)): "
                            + restoreReason)
                }
                if recordOnlySubcommands.contains(spelling), !isRecordFile {
                    findings.append(
                        "forbidden literal \(spelling.debugDescription) (offset \(token)) outside "
                            + "\(recordFile): \(recordOnlyReason)")
                }
                // Wherever it sits: a vector, a fragment, an append, a `let`. No rule has to
                // read the vector, because no vector may carry it.
                if isUnidiffZero(spelling) {
                    findings.append(
                        "forbidden literal \(spelling.debugDescription) (offset \(token)): "
                            + unidiffZeroReason)
                }
                if prefixRule(matching: spelling) != nil,
                    !(isAPushElement && isPermittedLease(spelling))
                {
                    findings.append(
                        "forbidden literal \(spelling.debugDescription) (offset \(token)): "
                            + leaseReason)
                }
                if isForceRefspec(spelling) {
                    findings.append(
                        "forbidden force refspec \(spelling.debugDescription) (offset \(token)): "
                            + forceRefspecReason)
                }
                // A delete refspec that is not an element of a `push` vector. For one that is,
                // the array rule decides, because only there can a lease in the same array
                // vouch for it; saying it here as well would report one hazard twice.
                if spelling.hasPrefix(deleteRefspecPrefix), !isAPushElement {
                    findings.append(
                        "forbidden delete refspec \(spelling.debugDescription) (offset \(token)): "
                            + deleteRefspecReason)
                }
            }
        }

        for (arrayIndex, array) in arrays.enumerated() {
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
            //
            // `decoded` because classification has exactly one right answer and the escapes are
            // part of it: `["\u{72}emote", "rm", r]` is `git remote rm`, and reading the raw
            // text named the subcommand `\u{72}emote`, which is in no table, so every rule that
            // keys on `remote` was lost. Elsewhere both spellings are checked; here the decoded
            // one is simply what git receives.
            guard let subcommand = arguments.first?.value.map(decoded), !subcommand.hasPrefix("-")
            else {
                // A *global* option before the subcommand is worse than an unclassified vector:
                // it is the one shape that reliably turns a complete git command into one, and
                // it does so silently. No vector in `GitCore/Sources` is written that way, so
                // the rule is simply "don't" — see `globalOptionsBeforeSubcommand`.
                if let first = arguments.first?.value.map(decoded),
                    globalOptionsBeforeSubcommand.contains(first)
                {
                    findings.append(
                        "forbidden global option \(first.debugDescription) before the "
                            + "subcommand: \(globalOptionReason)")
                }
                findings += fragmentFindings(literals, isOneVector: true)
                outsideAVector += literals
                continue
            }

            if let reason = forbiddenSubcommands[subcommand] {
                findings.append("forbidden git subcommand \(subcommand.debugDescription): \(reason)")
                continue
            }
            // Not a flag that destroys work but a format the parser cannot read, which a
            // stage or discard would then act on. See `diffFormatPins`.
            if subcommand == "diff" { findings += diffFormatFindings(array) }
            // A subcommand whose dangerous forms no flag table can see: the permitted vectors
            // are listed whole. See `allowedShapes`. A matched shape is complete — every pinned
            // element is exactly what the table says, and a data slot holds no flag — so there
            // is nothing left for the per-element rules to read.
            // A shape is matched on the array literal alone, so a stash vector bound to a name can
            // be extended afterwards where no shape can see it (`a += paths`). It has to be
            // written inline, as an argument of the call that runs it.
            if subcommand == "stash", !isInlineArgumentOfRun(code: code, open: array.open) {
                findings.append(
                    "forbidden `git stash` vector that is not written inline as an argument of "
                        + "`run(` or `runWithEnvironment(`: \(stashInlineReason)")
            }
            if let shapes = allowedShapes[subcommand] {
                if matchedShapes[arrayIndex] == nil {
                    findings.append(
                        "forbidden `git \(subcommand)` vector: the only permitted forms are "
                            + spelling(of: subcommand, shapes) + ", because "
                            + (shapeReasons[subcommand] ?? "") + shapeConcatenationNote)
                    for word in literals.dropFirst().flatMap(spellings(of:)) {
                        if let reason = (shapeWordReasons[subcommand] ?? [:])[word] {
                            findings.append("forbidden `git \(subcommand) … \(word)`: \(reason)")
                        }
                    }
                }
                // A matched shape is complete. A mismatched vector of a subcommand that also
                // keeps its deny table (`shapedSubcommandsWithDenyTables`) goes on to the per-element
                // rules, so the finding names the offending flag (`rebase --autostash`,
                // `cherry-pick --merge`) as well as the shape it missed.
                if matchedShapes[arrayIndex] != nil || !shapedSubcommandsWithDenyTables.contains(subcommand) { continue }
            }
            // One of `skipShapes`: every element is a pinned literal, vouched for above.
            if matchedShapes[arrayIndex] != nil { continue }
            if subcommand == "read-tree" {
                for flag in literals.dropFirst().flatMap(spellings(of:)) {
                    if let reason = readTreeForbiddenFlags[flag] {
                        findings.append("forbidden `git read-tree \(flag)`: \(reason)")
                    }
                }
            }
            // Over ELEMENTS, not over the flat literal list, because one rule is positional:
            // `reset --merge` is safe and `reset --merge <commit>` moves HEAD, and only the
            // element index can tell them apart. A classified array's first element holds
            // exactly one literal (the subcommand), so `dropFirst()` still drops it and
            // nothing else.
            let carriesLease = arguments.contains(where: vouchingLease)
            for (index, element) in arguments.enumerated().dropFirst() {
                for flag in element.literals.flatMap(spellings(of:)) {
                    if let reason = (forbiddenFlags[subcommand] ?? [:])[flag] {
                        findings.append("forbidden `git \(subcommand) \(flag)`: \(reason)")
                    } else if let rule = flagsAllowedOnlyAfter[flag] {
                        findings += rule.findings(
                            for: flag, after: subcommand,
                            isLastElement: index == arguments.count - 1)
                    } else if let rule = prefixRule(matching: flag),
                        !rule.subcommands.contains(subcommand) || !vouchingLease(element)
                    {
                        findings.append("forbidden `git \(subcommand) \(flag)`: \(leaseReason)")
                    }
                    // A delete refspec — `:refs/heads/x`, or a bare `":"` that some expression
                    // completes — is `push --delete` written as data. It is permitted only when
                    // the same array carries a lease naming the sha the sheet showed, which is
                    // what makes the deletion conditional on the branch not having moved.
                    // `push … tag <name>` is git's keyword form for
                    // `refs/tags/<name>:refs/tags/<name>` (B20): a short name, and a shape no
                    // measurement covered. Gitter spells a tag's refspec in full.
                    if subcommand == "push", flag == "tag" {
                        findings.append("forbidden `git push … \(flag) <name>`: \(pushTagKeywordReason)")
                    }
                    if subcommand == "push", flag.hasPrefix(":"), !carriesLease {
                        findings.append(
                            "forbidden delete refspec \(flag.debugDescription) in a `git push` "
                                + "vector: \(deleteRefspecReason)")
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
        let appended = appendedLiterals(in: source, code: code)
        findings += fragmentFindings(appended, isOneVector: false)
        outsideAVector += appended
        if namesStash {
            for word in Set(outsideAVector.flatMap(spellings(of:))).sorted()
            where stashWordsForbiddenOutsideAVector.contains(word) {
                findings.append(
                    "in a file that runs `git stash`, write every git vector as one array "
                        + "literal (optionally `+ paths`): \(word.debugDescription) added "
                        + "outside one cannot be attributed to a command. \(stashOutsideAVectorReason)")
            }
        }
        // The append pool is not one vector, so it cannot say which vector a `-m` joins. In a
        // file that names `read-tree` at all, that is enough: the three are findings there.
        let namesReadTree = literals(in: source, code: code)
            .contains { spellings(of: $0.1).contains("read-tree") }
        if namesReadTree {
            for flag in appended.flatMap(spellings(of:)) {
                if let reason = readTreeForbiddenFlags[flag] {
                    findings.append(
                        "forbidden appended \(flag.debugDescription) in a file that runs "
                            + "`git read-tree`: \(reason)")
                }
            }
        }
        return findings
    }

    /// - Parameter isOneVector: whether `literals` are the elements of a single array literal.
    ///   Only then can one of them vouch for another.
    private static func fragmentFindings(_ rawLiterals: [String], isOneVector: Bool) -> [String] {
        let literals = rawLiterals.flatMap(spellings(of:))
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
        // `.append("…")` in `GitCore/Sources` is part of a `diff-tree` list today
        // (`git grep -E '\.append\("' -- GitCore/Sources`: nine hits — `--exclude=` and
        // `--remotes` on a `rev-list` in `+Remotes.swift`, `--reverse`, `-a` and `--amend` in
        // `+WorkingCopy.swift`, and `PatchBuilder+Markers`' four `"+"`/`"-"` diff markers, which
        // are text being written rather than arguments),
        // so withholding it costs nothing; a future one must spell its vector as a literal.
        //
        // And it applies only to a fragment that names no subcommand of its own. `[repoFlag,
        // "branch", "--no-commit-id", "-M", a, b]` is a `branch -M` with a decoy in it: the
        // leading non-literal is what kept it a fragment, and `--no-commit-id` then excused the
        // `-M`. A `diff-tree` list carries options only, so refusing the carve-out to any
        // fragment containing a subcommand name costs it nothing.
        let namesASubcommand = literals.contains {
            forbiddenFlags.keys.contains($0) || forbiddenSubcommands.keys.contains($0)
                || allowedShapes.keys.contains($0)
        }
        let forbidden =
            isOneVector && literals.contains(diffTreeMarker) && !namesASubcommand
            ? fragmentForbidden.subtracting(diffTreeExempt) : fragmentForbidden
        var result = literals.filter(forbidden.contains).map {
            "forbidden flag \($0.debugDescription) in an argument fragment"
        }
        // A prefixed flag in a fragment. The whole-file sweep catches most of these already —
        // a fragment's literals are the file's literals — but not one nested *inside* a
        // classified vector (`["push", extra(["--force-with-lease=x"])]`), which the sweep
        // exempts by offset. Saying it twice for the shapes both see is the cheaper mistake.
        result += literals.compactMap { literal in
            guard prefixRule(matching: literal) != nil else { return nil }
            return "forbidden flag \(literal.debugDescription) in an argument fragment: "
                + leaseReason
        }
        // A fragment has no vector, so it can never carry the lease that would excuse a delete
        // refspec; the narrowing to `:refs/` is the same one the sweep uses.
        result += literals.compactMap { literal in
            guard literal.hasPrefix(deleteRefspecPrefix) else { return nil }
            return "forbidden delete refspec \(literal.debugDescription) in an argument "
                + "fragment: \(deleteRefspecReason)"
        }
        // And it can never prove its *shape*, which is the whole of the `remote` rule: the
        // allowed-shape check runs on classified arrays only, so one leading non-literal
        // (`[repoFlag, "remote", "rm", r]`) or one `.append("rm")` walked past it. The words
        // that can only be `git remote`'s are findings file-wide instead (see
        // `remoteWordsForbiddenEverywhere`); these two are the ones `GitCore/Sources` writes as
        // the first element of a classified vector, where no fragment rule looks.
        result += literals.filter(remoteWordsForbiddenInFragments.contains).map {
            "forbidden literal \($0.debugDescription) in an argument fragment: "
                + remoteFragmentReason
        }
        // `stash` the same way, and for the same reason: its shape is the whole rule.
        result += literals.filter(stashWordsForbiddenInFragments.contains).map {
            "forbidden literal \($0.debugDescription) in an argument fragment: "
                + stashFragmentReason
        }
        // And `tag` (B1 Task 2): its shapes are the whole rule too, and in a `push` it is the
        // keyword form. `[flag, "tag", "-m", m, n, sha]` is a `tag -m` that signs under
        // `tag.forceSignAnnotated` and that no shape or table could read.
        result += literals.filter { $0 == "tag" }.map {
            "forbidden literal \($0.debugDescription) in an argument fragment: \(tagFragmentReason)"
        }
        // Within one vector a fragment can still speak for itself: `[flag, "read-tree", "-m",
        // t]` is a `read-tree -m`. The append pool is not one vector, so this is not asked of it.
        if isOneVector, literals.contains("read-tree") {
            result += literals.compactMap { flag in
                readTreeForbiddenFlags[flag].map {
                    "forbidden `git read-tree \(flag)` in an argument fragment: \($0)"
                }
            }
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
    /// abort), and `--skip` throws away the commit git stopped on. `--skip` is vouched for in the
    /// three whole vectors of `skipShapes` (A2 Task 3's Skip, which files the stopped commit's
    /// changes first) and stays a finding everywhere else; `--quit` has no exception.
    /// `-B` is here because the README and the design doc have both claimed it was scanned
    /// since the milestone began, and it was not: `git checkout -B` force-creates a branch over
    /// an existing one. (`git branch` has **no** `-B` — this comment said it did until fix
    /// round 1; `branch` force-creates with `-f`, and force-renames and force-copies with `-M`
    /// and `-C`, all three of which are in its table.) Nothing in `GitCore/Sources` uses `-B`,
    /// so this costs nothing today. `git diff -B` (break-rewrites) is the future false positive
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
    ///
    /// `stash` was here until the working-copy milestone, which runs five shapes of it; it is in
    /// `allowedShapes` now, where everything else it can do is still a finding. `hash-object`
    /// joined then: it follows a symlink and hashes the target's content rather than the link
    /// (M 8), so a record built with it would restore the wrong thing. The record is built with
    /// `update-index` on a temporary index instead.
    static let forbiddenSubcommands: [String: String] = [
        "clean": "deletes untracked files outright",
        "checkout": "`checkout -- <path>` discards a file's changes with no undo",
        "pull": "fetches and then merges or rebases in one step the user was never shown",
        "hash-object":
            "follows a symlink and hashes its target instead of the link (M 8); build a record "
            + "with `update-index` on a temporary index",
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
            "--follow-tags": "pushes tags the user never named, silently, alongside the branch",
            "--no-force-with-lease":
                "cancels a lease written earlier in the same vector, leaving a plain force "
                + "push behind and a reader who believes otherwise",
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
        // B1 Task 2. `tag` is shape-governed (`allowedShapes`); this table names the flag in a
        // finding for a vector that misses, and feeds `fragmentForbidden`. `-s` and `-u` are
        // `ls-files`' and `push`'s too, so the sweep skips them (`sweepExempt`).
        "tag": [
            "-f": "moves an existing tag to another commit with no confirmation",
            "--force": "moves an existing tag to another commit with no confirmation",
            "-s": "signs the tag with a key the user never chose here; no signed tags (B1)",
            "--sign": "signs the tag with a key the user never chose here; no signed tags (B1)",
            "-u": "signs the tag with a key the user never chose here; no signed tags (B1)",
            "--local-user": "signs the tag with a key the user never chose here; no signed tags (B1)",
            "-d": "deletes a tag with no expected value; Gitter deletes one with `update-ref -d` on the id the sheet showed",
            "--delete": "deletes a tag with no expected value; Gitter deletes one with `update-ref -d` on the id the sheet showed",
        ],
        "rebase": [
            "--autostash": "moves the user's changes somewhere they did not ask for",
            "--skip": "throws away the commit git stopped on",
            "--quit": "leaves the rebase's half-applied result behind with no way to abort it",
            "-f": "force",
            "--force-rebase": "rewrites commits that did not need rewriting",
            "--no-verify": "skips the hooks the user installed to stop exactly this",
            "--update-refs":
                "moves every other local branch that points into the rewritten commits, "
                + "branches the sheet never named",
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

    /// Whether a literal is a lease of the one shape Gitter is allowed to write.
    ///
    /// Matching the prefix is not enough, and treating it as enough was the hole this rule was
    /// meant to close. `--force-with-lease=<ref>` with **no** `:<sha>` does not lease against
    /// the sha anybody was shown: it leases against the remote-tracking ref, which Gitter's own
    /// auto-fetch rewrites — possibly seconds before the push, from the branch that is about to
    /// be overwritten. It is precisely the "force push that felt safe" this milestone exists to
    /// prevent, and it matched the prefix rule and passed.
    ///
    /// So four things are required, and all four are readable from the literal alone:
    ///
    /// 1. **One string literal**, beginning `--force-with-lease=`. `"--force-with-lease=" + x`
    ///    is a finding: what is on the other side of the `+` is not something this scanner can
    ///    read, so it cannot be vouched for.
    /// 2. A `:` in the remainder — the separator between the ref and the expected value, and
    ///    the **first** one outside an interpolation, because that is the one git splits on.
    /// 3. **Both sides non-empty.** `--force-with-lease=<ref>:` is a *legal and different*
    ///    command: an empty expected value means "only if that ref does not exist", which is
    ///    never what Gitter wants. `--force-with-lease=:<sha>` names no ref.
    /// 4. Everything after the **first** `:` — see `leaseSeparator(in:)`, which is where git
    ///    splits — is exactly one interpolation, `\(…)`, and nothing else. A hard-coded sha
    ///    cannot have come from the sheet the user just read, and the sheet is the whole
    ///    mechanism: it shows a tip, the user agrees to overwrite *that* tip, and the lease is
    ///    how git is told which tip that was. Only an interpolation can carry it.
    ///
    /// Position is still pinned on top of all this (a lone-literal element of an array literal
    /// classified `push`), by `findings(in:)` — permission to spell a prefix is much larger than
    /// permission to spell a token, and shape alone does not say the literal is about to be
    /// handed to `git push`.
    static func isPermittedLease(_ literal: String) -> Bool {
        guard let rule = prefixRule(matching: literal) else { return false }
        let value = literal.dropFirst(rule.prefix.count)
        guard let separator = leaseSeparator(in: value) else { return false }
        let ref = value[value.startIndex..<separator]
        guard !ref.isEmpty else { return false }
        return isWholeInterpolation(value[value.index(after: separator)...])
    }

    /// Where git splits a lease: the **first** `:` that is not inside an interpolation.
    ///
    /// Measured rather than assumed. `git push --force-with-lease=refs/heads/feature:a:b`
    /// answers `error: cannot parse expected object name 'a:b'` — git takes everything after
    /// the first `:` as the expected value, and refuses when that is not an object name. This
    /// scanner split on the *last* one, so it read that literal as a lease on the ref
    /// `refs/heads/feature:a` with the expectation `b`, and a
    /// `"--force-with-lease=\(a):\(b):\(c)"` that git will never honour was permitted.
    ///
    /// Interpolations are skipped because a `:` can legitimately sit inside one — a ternary, a
    /// dictionary literal — and the lexer keeps the literal's raw text, so the `\(` and `)`
    /// marks are there to be counted.
    static func leaseSeparator(in value: Substring) -> Substring.Index? {
        var depth = 0
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(after: index)
            if value[index] == "\\", next < value.endIndex, value[next] == "(" {
                depth += 1
                index = value.index(after: next)
                continue
            }
            if depth > 0 {
                if value[index] == "(" { depth += 1 }
                if value[index] == ")" { depth -= 1 }
            } else if value[index] == ":" {
                return index
            }
            index = next
        }
        return nil
    }

    /// Whether `text` is exactly one `\(…)` — balanced, non-empty inside, and with nothing
    /// after the closing parenthesis.
    ///
    /// "Begins `\(` and ends `)`" was the old test, and it let the rest of the literal ride
    /// along in between: `\(sha)extra)` satisfies it while handing git the expected object name
    /// `<sha>extra)`, and `\()` satisfies it while interpolating nothing at all. Both were
    /// permitted leases.
    static func isWholeInterpolation(_ text: Substring) -> Bool {
        guard text.hasPrefix("\\(") else { return false }
        let inner = text.index(text.startIndex, offsetBy: 2)
        var depth = 1
        var index = inner
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index > inner && text.index(after: index) == text.endIndex }
            }
            index = text.index(after: index)
        }
        return false
    }

    /// Whether an element of an argument vector is a lease this scanner will honour — which is
    /// the one place it *grants* permission, so it is the one place that must read the element's
    /// value rather than the literals inside it.
    ///
    /// `force ? "--force-with-lease=\(ref):\(tip)" : "--dry-run"` contains a permitted lease and
    /// is a lease only when `force` is true; the delete refspec it was vouching for is pushed
    /// either way. Reading every literal is right for a deny table — both arms can reach git —
    /// and exactly wrong here. So a lease counts only as a lone-literal element, which is how
    /// `allowsTheRemoteOperationsThisMilestoneNeeds` writes every one of them.
    ///
    /// Both sites that ask this question call it, so they cannot drift apart: the lease's own
    /// permission inside a classified vector, and `carriesLease`.
    static func vouchingLease(_ element: ArrayElement) -> Bool {
        guard let value = element.value else { return false }
        return spellings(of: value).contains(where: isPermittedLease)
    }

    static let leaseReason =
        "the only permitted lease is one string literal `--force-with-lease=<ref>:\\(sha)` — "
        + "non-empty before the first `:`, and after it exactly one interpolation carrying the "
        + "sha the confirmation sheet showed — standing alone as an element of an array literal "
        + "classified `push`. A bare `--force-with-lease=<ref>` leases against the "
        + "remote-tracking ref "
        + "that this app's own fetch rewrites, an empty expected value means `must not exist`, "
        + "and a concatenated flag cannot be read here at all"

    /// Every spelling of a literal this scanner will judge: the raw text, plus the text with
    /// its `\u{…}` escapes decoded when that differs.
    ///
    /// The lexer keeps a literal's *raw* source text, which is what makes the interpolated
    /// spellings readable — and what makes `"\u{2d}\u{2d}force"` unreadable, since its value is
    /// the eighteen characters `\u{2d}\u{2d}force` and no table holds that. Decoding costs
    /// nothing here: every `\u{…}` in `GitCore/Sources` is `"\u{0}"`, git's `-z` record
    /// separator (`git grep -F '\u{' -- GitCore/Sources`: four, in `CLIGitBackend` and three
    /// parsers), and NUL matches no rule.
    ///
    /// It does not close the class — `"\u{2d}" + "\u{2d}force"` is still two literals, like
    /// every other concatenation — but it removes the one spelling that looks deliberate.
    static func spellings(of literal: String) -> [String] {
        guard let decoded = decodingUnicodeEscapes(literal) else { return [literal] }
        return [literal, decoded]
    }

    /// The one spelling git will actually be handed: escapes decoded, since Swift decodes them
    /// before the string ever reaches a process.
    ///
    /// The rules consult *both* spellings, because the raw text is what makes an interpolated
    /// literal readable. Classification cannot: an array literal has one subcommand, and
    /// `["\u{72}emote", "rm", r]` runs `git remote rm` however this scanner reads it. Reading it
    /// raw named the subcommand `\u{72}emote` and lost every rule keyed on `remote` at once.
    static func decoded(_ literal: String) -> String {
        decodingUnicodeEscapes(literal) ?? literal
    }

    /// `literal` with every `\u{<hex>}` replaced by the character it denotes, or nil when there
    /// is nothing to decode, the escape is malformed, or decoding changes nothing.
    static func decodingUnicodeEscapes(_ literal: String) -> String? {
        let marker = "\\u{"
        guard literal.contains(marker) else { return nil }
        var decoded = ""
        var rest = Substring(literal)
        while let escape = rest.range(of: marker) {
            decoded += rest[rest.startIndex..<escape.lowerBound]
            guard let end = rest[escape.upperBound...].firstIndex(of: "}"),
                let value = UInt32(rest[escape.upperBound..<end], radix: 16),
                let scalar = Unicode.Scalar(value)
            else { return nil }
            decoded.append(Character(scalar))
            rest = rest[rest.index(after: end)...]
        }
        decoded += rest
        return decoded == literal ? nil : decoded
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

    /// A *delete* refspec: an empty source side (`:refs/heads/x`) asks the server to delete
    /// that ref. It is `git push --delete` spelled as data, and `--delete`/`-d` being findings
    /// means nothing while this shape walks past every table.
    ///
    /// Two rules, because the narrowing that is safe file-wide is not the one that is useful
    /// inside a vector:
    ///
    /// - **File-wide and in fragments**, only a literal beginning `:refs/` counts. The one
    ///   `:`-leading literal in `GitCore/Sources` is `CLIGitBackend.swift:119`'s
    ///   `":(literal)" + path`, pathspec magic rather than a refspec, and it must not be
    ///   flagged. `git grep -nE '"[:][^"]*"' -- GitCore/Sources` returns **two** lines and this
    ///   comment used to call them "those two" literals: the second, `Models/Commit.swift:10`,
    ///   is a doc comment (`/// … split on ", ": e.g. "HEAD -> main" …`) and not a literal at
    ///   all — the scanner never sees it, because comments are stripped before anything is
    ///   lexed.
    /// - **As an element of an array literal classified `push`**, *any* literal beginning `:`
    ///   counts, including the bare `":"` of `":" + ref` — a leading colon there can only be a
    ///   refspec — **unless the same array carries a permitted lease** as an element of its own
    ///   (`vouchingLease`). That exception is the whole design: Gitter deletes a remote branch
    ///   with `["push", …, "--force-with-lease=refs/heads/x:\(tip)", …, ":refs/heads/x"]`,
    ///   where the lease makes the deletion conditional on the tip the sheet showed, so a
    ///   branch someone pushed to while the sheet was open is refused by git rather than
    ///   deleted. A `:refs/…` that is *not* an element of the vector — nested in a
    ///   sub-expression of it — is left to the file-wide rule above, which no lease excuses.
    static let deleteRefspecPrefix = ":refs/"

    static let deleteRefspecReason =
        "an empty source side deletes the ref on the server — the same command as `push "
        + "--delete`, written as data. Gitter deletes a remote branch only in a vector that "
        + "also carries `--force-with-lease=<ref>:\\(tip)`, so the tip the sheet showed is "
        + "what the deletion is conditional on"

    /// Options that go *before* the subcommand, which is the one shape that turns a complete
    /// git command into an unclassified fragment: `["-c", "push.default=matching", "push", r]`
    /// loses the `push` table, the lease rule, the wide `+`/`:` rules and the positional rules
    /// all at once, and reads as clean.
    ///
    /// `git grep -nE '\[\s*"(-c|-C|--git-dir|--work-tree)"' -- GitCore/Sources Gitter` finds
    /// none, so the rule can be a flat refusal rather than a "skip the pair and carry on" that
    /// would have to understand each option's argument. Every backend call already passes a
    /// working directory; a repository is named that way, not with `-C`.
    ///
    /// `"-c"` itself appears **twice**, not once as this comment claimed until fix round 2, and
    /// both are `switch`'s create flag rather than git's `-c`: `git grep -nE '"-c"' --
    /// GitCore/Sources Gitter` gives `CLIGitBackend+Branches.swift:31` (`arguments = ["switch",
    /// "-c", name]`) and `:67` (`["switch", "-c", local, "--track", "--end-of-options",
    /// remoteBranch]`). Neither is the array's first element, which is all this rule looks at.
    static let globalOptionsBeforeSubcommand: Set<String> = [
        "-c", "-C", "--git-dir", "--work-tree", "--exec-path", "--namespace",
    ]

    static let globalOptionReason =
        "a global option before the subcommand hides the subcommand from this scanner, so "
        + "every per-subcommand rule is lost. Pass a working directory instead, and put the "
        + "subcommand first"

    /// Subcommands whose dangerous forms are **words, not flags**, listed by the whole shapes
    /// that are permitted.
    ///
    /// `git remote` was unconstrained: `remote prune`, `remote remove`, `remote rm`, `remote
    /// set-url`, `remote rename`, `remote add`, `remote update`, `remote set-head` and `remote
    /// set-branches` each rewrite or delete the user's remote configuration, and not one of
    /// them is a flag, so no deny table can ever see them. A deny list would also have to be
    /// guessed forward into git's next release. So the rule is inverted: `["remote", "-v"]` —
    /// reading the remotes, which is all Gitter does — and nothing else.
    ///
    /// The shape is matched over element *values*, so a non-literal element never matches:
    /// `["remote", subcommand]` is a finding whatever `subcommand` holds.
    ///
    /// **What this rule does not reach, because saying "listed whole … and nothing else" was
    /// the claim fix round 2 found untrue.** It runs on *classified* arrays only, and one
    /// leading non-literal demotes a complete command to a fragment: `[repoFlag, "remote",
    /// "rm", r]` was clean, and so was `var a = ["remote", "-v"]; a.append("prune")`, where the
    /// word never shares a vector with anything. `remote` is not in `namesASubcommand` either,
    /// so such a fragment could even collect the `diff-tree` carve-out. Three things close
    /// that, and none of them is this table: `allowedShapes`' keys now join `namesASubcommand`;
    /// `remoteWordsForbiddenInFragments` makes `remote` and `rm` findings in any fragment or
    /// append; and `remoteWordsForbiddenEverywhere` makes the rest of the words findings
    /// file-wide. Read together: **the shape rule constrains a vector that names `remote`
    /// first, and the word rules constrain everything that does not.**
    ///
    /// **The working-copy milestone widened the rule to `stash` and `restore`**, and gave it the
    /// two things those need: a *data* slot (a message, a sha, `stash@{\(n)}` — any element
    /// with no flag in it) and an *interpolated* slot (`--source=\(sha)^2`). A shape also says
    /// whether anything may be concatenated after the array literal: only after a trailing
    /// `"--"`, where whatever follows is a path. `["stash", "push", "-q", "--message", m] +
    /// paths` would be a pathspec on `stash push`, which is exactly what the shape forbids.
    ///
    /// **B1 made `cherry-pick`, `revert` and `rebase` shape-governed**, to pin a *presence*: the
    /// vector that starts each action must carry the flag that keeps the user's config from
    /// rewriting it, and a deny table cannot see a flag left out. Their shas follow a trailing
    /// `"--end-of-options"`, the second place concatenation is allowed (revisions, never
    /// options). They keep their deny tables for a vector that misses (`shapedSubcommandsWithDenyTables`).
    static let allowedShapes: [String: [Shape]] = [
        "remote": [Shape(.literal("-v"))],
        "stash": [
            Shape(.literal("list"), .literal("-z"), .literal(stashListFormat)),
            Shape(.literal("push"), .literal("-q"), .literal("--message"), .data),
            Shape(
                .literal("push"), .literal("-q"), .literal("--message"), .data,
                .literal("--include-untracked")),
            Shape(.literal("store"), .literal("-q"), .literal("-m"), .data, .data),
            Shape(.literal("apply"), .literal("-q"), .literal("--no-index"), .data),
            Shape(.literal("drop"), .literal("-q"), .data),
        ],
        // Unstage, then the discard section's three literals. Every one carries
        // `--no-recurse-submodules`: under `submodule.recurse=true`, `restore --worktree -- sub`
        // checks the submodule out and discards the work inside it (M A.5). Ruling 26: each
        // takes its paths from a pathspec file (`withPathspecFile`), never `-- + paths` — one
        // argument per path crashed `Process` past 4096, and batches would end the all-or-nothing
        // refusal (M A.5). The file slot is one interpolation (a path, never `-`, stdin).
        "restore": [
            Shape(.literal("--no-recurse-submodules"), .literal("--staged")) + pathspecFile,
            Shape(.literal("--no-recurse-submodules"), .literal("--worktree")) + pathspecFile,
            Shape(
                .literal("--no-recurse-submodules"), .literal("--source=HEAD"),
                .literal("--staged"), .literal("--worktree")) + pathspecFile,
            Shape(
                .literal("--no-recurse-submodules"),
                .interpolated(prefix: restoreSourcePrefix, suffix: "^2"),
                .literal("--staged")) + pathspecFile,
            // A2 Task 2's conflict writes, each of exactly one path the write has just checked:
            // `--ours`/`--theirs` delete a file whose stage is missing and exit 0, and discard an
            // unstaged change on a path that is not conflicted (M 27); `--merge` overwrites the
            // resolution (M 11). Nothing may be appended.
            Shape(.literal("--no-recurse-submodules"), .literal("--ours"), .literal("--"), .data),
            Shape(.literal("--no-recurse-submodules"), .literal("--theirs"), .literal("--"), .data),
            Shape(.literal("--no-recurse-submodules"), .literal("--merge"), .literal("--"), .data),
        ],
        // `rm` without `--cached` deletes files on disk, and `-r` whatever is under a directory:
        // Stage and Unstage's two index-only vectors, and Delete's one path (M 28).
        "rm": [
            Shape(.literal("--cached"), .literal("-q"), .literal("--ignore-unmatch")) + pathspecFile,
            Shape(.literal("--cached"), .literal("-r"), .literal("-q"), .literal("--"), .literal(".")),
            Shape(.literal("-q"), .literal("--"), .data),
        ],
        // A2 Task 1's conflict reads. `merge-file` without `--object-id` writes its result over
        // its first argument (M 2), so both rebuilds are listed whole: the compare rebuild (the
        // user's style, git's marker size) and the parse rebuild (`--diff3`, the safe size),
        // both diffing with histogram as a merge does (fix round 1: myers rebuilt other blocks).
        // Stages 2 and 3 are `:n:<path>` object names; the base is `:1:<path>` or, for an
        // add/add with no stage 1, the empty blob — a data slot.
        "merge-file": [
            Shape(
                .literal("--object-id"), .literal("--diff-algorithm=histogram"),
                .interpolated(prefix: "--marker-size=", suffix: ""),
                .literal("-L"), .literal("ours"), .literal("-L"), .literal("base"), .literal("-L"),
                .literal("theirs"), .interpolated(prefix: ":2:", suffix: ""), .data,
                .interpolated(prefix: ":3:", suffix: "")),
            Shape(
                .literal("--object-id"), .literal("--diff-algorithm=histogram"), .literal("--diff3"),
                .interpolated(prefix: "--marker-size=", suffix: ""),
                .literal("-L"), .literal("ours"), .literal("-L"), .literal("base"), .literal("-L"),
                .literal("theirs"), .interpolated(prefix: ":2:", suffix: ""), .data,
                .interpolated(prefix: ":3:", suffix: "")),
        ],
        // The rebuilt blob or a stage in worktree form (`--filters --path=`), and the discard
        // section's two reads of a record's blob.
        "cat-file": [
            Shape(.literal("--filters"), .interpolated(prefix: "--path=", suffix: ""), .data),
            Shape(.literal("--filters"), .data),
            Shape(.literal("blob"), .data),
        ],
        // `check-attr` takes path names, not pathspecs: `:(literal)f.txt` is looked up as a file
        // of that name (measured, A2 Task 1), so the path after `--` is plain.
        "check-attr": [
            Shape(
                .literal("-z"), .literal("merge"), .literal("conflict-marker-size"), .literal("--"),
                .data),
        ],
        // B1 Task 1: the vectors that start a history action, each with the pin that keeps the
        // user's config from rewriting it — `--empty=drop` (an already-applied commit would
        // stop the pick as "empty", B4), `--no-reference` (`revert.reference=true` commits git's
        // placeholder comment as the subject, B9), `--no-rebase-merges` (`rebase.rebaseMerges`
        // recreates merges the replay list flattened, B13) — and the two ways out A2 runs
        // (`--skip` is `skipShapes`'). The shas follow `--end-of-options`, concatenated. A
        // revert's `--continue` carries `--no-reference` too (final fix wave I1): git keeps
        // `--no-edit` in `sequencer/opts` but not it, so the rest of a stopped range would be
        // committed with the placeholder subject.
        "cherry-pick": [
            Shape(.literal("--abort")), Shape(.literal("--continue")),
            Shape(.literal("--empty=drop"), .literal("--end-of-options")),
        ],
        "revert": [
            Shape(.literal("--abort")), Shape(.literal("--continue"), .literal("--no-reference")),
            Shape(.literal("--no-edit"), .literal("--no-reference"), .literal("--end-of-options")),
        ],
        "rebase": [
            Shape(.literal("--abort")), Shape(.literal("--continue")),
            Shape(
                .literal("--no-autostash"), .literal("--no-update-refs"), .literal("--no-rebase-merges"),
                .literal("--end-of-options"), .data),
        ],
        // B1 Task 2: the two creates — the restore is the lightweight one, naming the tag
        // object — each with the pins that keep config from rewriting it: `--no-sign`
        // (`tag.gpgSign=true` signs even a lightweight tag), an explicit `-a`
        // (`tag.forceSignAnnotated=true` beats `--no-sign` without it) and
        // `--cleanup=verbatim` (`-F` strips `#` lines) (B17). The name, the target and the
        // message file are expressions — values the code checked — never literals: a literal
        // target would be a short name (`HEAD`, `main`) where RF2 wants a full id.
        "tag": [
            Shape(.literal("--no-sign"), .literal("--end-of-options"), .expression, .expression),
            Shape(
                .literal("--no-sign"), .literal("-a"), .literal("-F"), .expression,
                .literal("--cleanup=verbatim"), .literal("--end-of-options"), .expression, .expression),
        ],
        // B1 Task 2: the compare-and-delete, and nothing else `update-ref` can do — move a
        // branch, delete with no check, read a transaction from stdin. The ref is a full
        // `refs/tags/` name, and the expected value one interpolation: an empty or all-zero
        // literal deletes **unconditionally** (B19), and the code checks the value it
        // interpolates is a full, non-zero id before it builds the vector. `--no-deref` (fix
        // round 1): without it a symbolic ref under `refs/tags/` is followed, and the branch it
        // names is deleted instead.
        "update-ref": [
            Shape(
                .literal("--no-deref"), .literal("-d"), .literal("--end-of-options"),
                .interpolated(prefix: "refs/tags/", suffix: ""), .interpolated(prefix: "", suffix: "")),
        ],
    ]

    /// The shape-governed subcommands that also keep a deny table (`forbiddenFlags`) and the
    /// positional rules (`--abort`, `--merge`): a vector of theirs that misses every shape is
    /// also read flag by flag, so its finding names the flag. Their tables still feed
    /// `fragmentForbidden` either way. The three sequencer commands since B1 Task 1, `tag` since
    /// Task 2.
    static let shapedSubcommandsWithDenyTables: Set<String> = ["cherry-pick", "revert", "rebase", "tag"]

    /// The only three vectors that may carry `--skip` (A2 Task 3's Skip), each whole and with
    /// nothing concatenated: `["rebase", "--skip"]`, `["cherry-pick", "--skip"]` and
    /// `["revert", "--skip", "--no-reference"]` — the pin, as on `revert --continue`, because
    /// `sequencer/opts` does not keep it (final fix wave I1).
    ///
    /// `--skip` stays in `alwaysForbidden`, so the sweep still reports it in every literal but an
    /// element of an array literal matching one of these shapes (`vouched` in `findings`), and a
    /// matched array is complete: no per-element rule has anything left to read. Since B1 the
    /// three subcommands are shape-governed as well (`allowedShapes`: `--abort`, `--continue`
    /// and the vector that starts each action), and they keep their deny tables and positional
    /// rules (`rebase --autostash`, `cherry-pick --merge`) for a vector that misses every shape
    /// (`shapedSubcommandsWithDenyTables`), which is what names the offending flag in their findings. What makes the flag safe is not the vector but what
    /// runs before it: `skip(_:stoppedAt:at:)` refuses unless every change is the stopped
    /// commit's and files them first (M 17, M 31, M 32).
    static let skipShapes: [String: [Shape]] = [
        "rebase": [Shape(.literal("--skip"))],
        "cherry-pick": [Shape(.literal("--skip"))],
        "revert": [Shape(.literal("--skip"), .literal("--no-reference"))],
    ]

    /// The two slots that end a vector whose paths are in a pathspec file (Ruling 26):
    /// `"--pathspec-from-file=\(file)"`, exactly one interpolation, then `--pathspec-file-nul`.
    /// Nothing may follow, and nothing be concatenated: git refuses a pathspec beside the file.
    static let pathspecFile: [ShapeSlot] = [
        .interpolated(prefix: "--pathspec-from-file=", suffix: ""), .literal("--pathspec-file-nul"),
    ]

    /// One element of an allowed shape.
    enum ShapeSlot {
        /// Exactly this string literal (escapes decoded).
        case literal(String)
        /// Any element in which no literal begins with `-`: a message, a sha, a position.
        /// `keep ? "--keep-index" : m` is not data, because one arm is a flag.
        case data
        /// One literal: `prefix`, then exactly one interpolation, then `suffix`.
        case interpolated(prefix: String, suffix: String)
        /// An element with no string literal in it at all — a name or an id the code computed
        /// and checked (`name`, `receipt.objectID`, `file.path`). Stricter than `.data`, which
        /// lets a hard-coded value through.
        case expression

        func matches(_ element: ArrayElement) -> Bool {
            switch self {
            case .expression:
                return element.literals.isEmpty
            case .literal(let text):
                return element.value.map(ForceFlagScanner.decoded) == text
            case .data:
                return !element.literals.flatMap(ForceFlagScanner.spellings(of:))
                    .contains { $0.hasPrefix("-") }
            case .interpolated(let prefix, let suffix):
                guard let value = element.value, value.hasPrefix(prefix), value.hasSuffix(suffix),
                    value.count > prefix.count + suffix.count
                else { return false }
                let middle = value.dropFirst(prefix.count).dropLast(suffix.count)
                return ForceFlagScanner.isWholeInterpolation(middle)
            }
        }
    }

    /// A whole permitted vector, after its subcommand.
    struct Shape {
        let slots: [ShapeSlot]
        init(_ slots: ShapeSlot...) { self.slots = slots }
        private init(slots: [ShapeSlot]) { self.slots = slots }

        static func + (shape: Shape, tail: [ShapeSlot]) -> Shape { Shape(slots: shape.slots + tail) }

        /// Whether `+ …` may follow the array literal: only after a trailing `"--"` (paths) or
        /// `"--end-of-options"` (revisions — git reads nothing after it as an option, B25).
        var allowsConcatenation: Bool {
            if case .literal(let last) = slots.last { return last == "--" || last == "--end-of-options" }
            return false
        }

        func matches(_ array: ArrayLiteral) -> Bool {
            let tail = array.elements.dropFirst()
            guard tail.count == slots.count else { return false }
            guard !array.followedByConcatenation || allowsConcatenation else { return false }
            return zip(slots, tail).allSatisfy { $0.matches($1) }
        }
    }

    /// The shape `array` matches, or nil when it matches none — or is not classified under a
    /// subcommand that has shapes at all.
    static func matchesAllowedShape(_ array: ArrayLiteral) -> Shape? {
        guard let subcommand = array.elements.first?.value.map(decoded) else { return nil }
        let shapes = (allowedShapes[subcommand] ?? []) + (skipShapes[subcommand] ?? [])
        return shapes.first { $0.matches(array) }
    }

    /// Why each subcommand in `allowedShapes` is a shape rule rather than a deny table.
    static let shapeReasons: [String: String] = [
        "remote":
            "remote's other forms are words rather than flags and no flag table can see them",
        "stash":
            "stash's other forms move or delete the user's changes: `pop` drops an entry after "
            + "any apply, `clear` and `drop` without a verified position delete entries, "
            + "`--index`/`--keep-index`/`--staged`/`-p`/`--all`/a pathspec each save or restore "
            + "something the sheet did not name",
        "restore": restoreReason,
        "rm":
            "`rm` without `--cached` deletes files on disk, and a conflicted file's edits with no "
            + "refusal (M 28); the only permitted vectors are the index-only two and one path",
        "merge-file":
            "without `--object-id` merge-file overwrites its first argument in the worktree (M 2), "
            + "and the conflict reader parses only the two rebuilds it was measured with",
        "cat-file":
            "the conflict reader and the discard section parse exactly these reads; `-p`, "
            + "`--textconv` or a read without `--filters` gives them bytes in another form",
        "check-attr": "the conflict reader asks for exactly these two attributes, of one plain path",
        "cherry-pick":
            "a pick without `--empty=drop` stops on an already-applied commit as an empty pick (B4), "
            + "and every other option (`-x`, `-n`, `-m`, `--empty=keep`) changes what the sheet showed",
        "revert":
            "a revert without `--no-reference` commits git's placeholder comment as its subject under "
            + "`revert.reference=true` (B9), and without `--no-edit` it may open an editor",
        "rebase":
            "a rebase without `--no-rebase-merges` recreates merges under `rebase.rebaseMerges=true` "
            + "(B13), and the autostash and update-refs pins keep config from moving work and branches "
            + "the sheet never named",
        "tag":
            "a tag without `--no-sign` is signed under `tag.gpgSign=true` — a lightweight one too — "
            + "and `-m` or `-F` without `-a` under `tag.forceSignAnnotated=true` whatever `--no-sign` "
            + "says; `-F` without `--cleanup=verbatim` strips the message's `#` lines (B17); and "
            + "`-f`, `-d`, `-s`, `-u` move, delete or sign tags with no confirmation",
        "update-ref":
            "`update-ref` moves or deletes any ref; the one permitted form deletes a tag only while it "
            + "holds the id the sheet showed, and an empty or all-zero expected value deletes with no "
            + "check at all (B19); without `--no-deref` a symbolic tag's branch is deleted instead",
    ]

    static let shapeConcatenationNote =
        ". Nothing may be concatenated after the array literal unless it ends with \"--\""

    /// The words a failed `stash` shape is most likely to contain, named in the finding.
    static let shapeWordReasons: [String: [String: String]] = [
        "stash": [
            "pop": "drops the entry after an apply git itself decided was good enough",
            "clear": "deletes every stash entry",
            "create": "makes a stash commit no ref holds",
            "branch": "checks out a new branch and drops the entry",
            "show": "prints a diff shaped by the user's diff config (M A.6); use diff-tree",
            "--index": "restores the index too, and refuses the whole apply when it cannot",
            "--keep-index": "saves the staged changes but leaves them in place",
            "-k": "saves the staged changes but leaves them in place",
            "--staged": "saves only the staged changes",
            "-S": "saves only the staged changes",
            "--all": "stashes ignored files too",
            "-a": "stashes ignored files too",
            "-p": "stashes a selection the sheet never showed",
            "--patch": "stashes a selection the sheet never showed",
        ],
    ]

    /// The `stash --format` the list is read with; `--date` would turn `%gd` into a date (M 1).
    static let stashListFormat = "--format=%H%x1f%gd%x1f%gs%x1f%ct%x1f%P"

    /// `stash`'s words that `GitCore/Sources` never needs (`git grep`: zero hits), so they are
    /// findings wherever a literal holds one. `show` and `branch` are left to the shape rule:
    /// both name subcommands this code could reasonably run on their own.
    ///
    /// `stash` itself is here too (fix round 1): it was a forbidden subcommand until this
    /// milestone and so a finding file-wide, and without that `let sub = "stash"; run([sub,
    /// "push", "--", p])` read as clean. The one place it may stand is as the subcommand of an
    /// array that matched a shape, which vouches for it (`vouched` in `findings`).
    static let stashWordsForbiddenEverywhere: Set<String> = [
        "stash", "pop", "clear", "create", "--keep-index", "--index",
    ]

    static let stashWordReason =
        "`git stash` is run only in the whole shapes `allowedShapes` lists, and `pop`, "
            + "`clear`, `create`, `--keep-index` and `--index` never"

    /// In a file that runs `stash`, the words that would turn an allowed stash shape into a
    /// forbidden one are findings in a fragment, an `.append` or an `.insert` — anywhere no
    /// vector holds them, because nothing there can say which vector they join. `--` is how a
    /// pathspec starts; the rest are the forms `shapeWordReasons` names. Files that do not name
    /// `stash` are untouched: `--` introduces every pathspec in this code base.
    static let stashWordsForbiddenOutsideAVector: Set<String> = [
        "--", "--staged", "-S", "--all", "-a", "--keep-index", "-k", "-p", "--patch", "--index",
    ]

    static let stashOutsideAVectorReason =
        "It could be joining a stash vector as a pathspec or a forbidden option, and this "
            + "scanner can only vouch for what a single literal shows"

    static let stashInlineReason =
        "a shape is read from the array literal, so a vector bound to a `var` or `let` (or "
            + "returned) can be extended afterwards where no shape sees it"

    /// Whether the array literal opening at `open` is, through nothing but a ternary, an
    /// argument of `run(` or `runWithEnvironment(`: walking back over `code` at depth 0, the
    /// first unmatched bracket must be a `(` right after one of those names, with no `=`
    /// (a binding or an assignment) and no `;` on the way. `run(cond ? [a] : [b], …)` is
    /// inline; `let a = cond ? [a] : [b]`, `return [a]`, `other([a])` and `run(([a]) + x)`
    /// are not.
    static func isInlineArgumentOfRun(code: [Character], open: Int) -> Bool {
        var depth = 0
        var index = open - 1
        while index >= 0 {
            let c = code[index]
            if ")]}".contains(c) {
                depth += 1
            } else if "([{".contains(c) {
                if depth == 0 {
                    return c == "(" && runNames.contains(identifier(endingBefore: index, in: code))
                }
                depth -= 1
            } else if depth == 0 {
                if c == ";" { return false }
                if c == "=" {
                    let before = index > 0 ? code[index - 1] : " "
                    let after = index + 1 < code.count ? code[index + 1] : " "
                    if !"=!<>".contains(before), after != "=" { return false }
                }
            }
            index -= 1
        }
        return false
    }

    static let runNames: Set<String> = ["run", "runWithEnvironment"]

    private static func identifier(endingBefore index: Int, in code: [Character]) -> String {
        var end = index
        while end > 0, code[end - 1] == " " { end -= 1 }
        var start = end
        while start > 0, code[start - 1].isLetter || code[start - 1].isNumber || code[start - 1] == "_" {
            start -= 1
        }
        return String(code[start..<end])
    }

    /// `stash` itself in a fragment or the append pool, where no shape can be read.
    static let stashWordsForbiddenInFragments: Set<String> = ["stash"]

    static let stashFragmentReason =
        "a fragment cannot prove its shape, and `stash`'s permitted shapes are the whole rule. "
            + "Spell the vector as one array literal beginning with its subcommand"

    /// `restore`'s prefix that overwrites from another commit, vouched for only by a shape.
    static let restoreSourcePrefix = "--source="

    static let restoreReason =
        "`restore` overwrites files on disk through `--worktree` and `--source=…`, and without "
            + "`--no-recurse-submodules` it discards work inside a submodule under "
            + "`submodule.recurse=true` (M A.5); the only permitted vectors are the unstage "
            + "vector, the discard section's three literals — each with its paths in a pathspec "
            + "file (Ruling 26) — and a conflict write's `--ours`, `--theirs` or `--merge` of one "
            + "path"

    /// The scanner's first per-file rule. Without `GIT_INDEX_FILE`, `read-tree HEAD` overwrites
    /// the real index and drops every staged change, and this scanner cannot see an
    /// environment — so the three subcommands that write an index are confined to the file
    /// that owns the temporary one.
    static let recordFile = "CLIGitBackend+StashRecord.swift"
    static let recordOnlySubcommands: Set<String> = ["read-tree", "update-index", "write-tree"]

    /// Final review M6: each `read-tree`, `update-index` and `write-tree` vector in `source`
    /// (the record's file), and a finding for every one not passed inline to
    /// `runWithEnvironment(` with `extra: index`.
    ///
    /// Read from the array literal like every rule here: a vector bound to a name first is a
    /// finding too, because what it is passed to can no longer be read off the call.
    static func indexWritingVectorsOutsideTheTemporaryIndex(in source: String) -> (checked: [String], findings: [String]) {
        let code = strippingCommentsAndStringContents(source)
        var checked: [String] = []
        var findings: [String] = []
        for array in argumentArrays(in: source, code: code) {
            guard let subcommand = array.elements.first?.value.map(decoded),
                recordOnlySubcommands.contains(subcommand)
            else { continue }
            checked.append(subcommand)
            guard let call = enclosingCall(code: code, open: array.open) else {
                findings.append("`git \(subcommand)` (offset \(array.open)) is not written inline as an argument of `runWithEnvironment(`")
                continue
            }
            let arguments = String(call.arguments).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if call.name != "runWithEnvironment"
                || arguments.range(of: #"extra: index\b"#, options: .regularExpression) == nil
            {
                findings.append(
                    "`git \(subcommand)` (offset \(array.open)) runs through `\(call.name)(` without `extra: index`: "
                        + "without GIT_INDEX_FILE it writes the real index")
            }
        }
        return (checked, findings)
    }

    /// The call the array literal opening at `open` is an argument of, through nothing but a
    /// ternary or a `+`: its name and its whole argument list. Nil for a vector bound to a name,
    /// returned, or nested in anything else (see `isInlineArgumentOfRun`, which this follows).
    private static func enclosingCall(code: [Character], open: Int) -> (name: String, arguments: ArraySlice<Character>)? {
        var depth = 0
        var index = open - 1
        while index >= 0 {
            let c = code[index]
            if ")]}".contains(c) {
                depth += 1
            } else if "([{".contains(c) {
                if depth == 0 {
                    guard c == "(" else { return nil }
                    var close = index
                    var level = 0
                    while close < code.count {
                        if "([{".contains(code[close]) { level += 1 }
                        if ")]}".contains(code[close]) {
                            level -= 1
                            if level == 0 { break }
                        }
                        close += 1
                    }
                    return (identifier(endingBefore: index, in: code), code[(index + 1)..<min(close, code.count)])
                }
                depth -= 1
            } else if depth == 0 {
                if c == ";" { return nil }
                if c == "=" {
                    let before = index > 0 ? code[index - 1] : " "
                    let after = index + 1 < code.count ? code[index + 1] : " "
                    if !"=!<>".contains(before), after != "=" { return nil }
                }
            }
            index -= 1
        }
        return nil
    }

    static let recordOnlyReason =
        "`read-tree`, `update-index` and `write-tree` rewrite whichever index GIT_INDEX_FILE "
            + "names, and the real one when it names none; only the record's own file, which "
            + "owns the temporary index, may run them"

    /// `read-tree`'s forms that write the worktree or merge, forbidden even in the record file.
    static let readTreeForbiddenFlags: [String: String] = [
        "-u": "updates the worktree from the index it reads",
        "-m": "merges trees into the index",
        "--reset": "discards unmerged entries, and with `-u` the worktree too",
    ]

    static let unidiffZero = "--unidiff-zero"

    /// The shortest abbreviation git 2.54's `apply` accepts for `--unidiff-zero`: `--uni` and
    /// `--un` are refused as ambiguous with `--union`, `--unid` runs the flag (measured).
    static let unidiffZeroShortestAbbreviation = "--unid"

    /// Whether git would read `literal` as `--unidiff-zero`: the flag itself, or any
    /// abbreviation of it that parse-options accepts.
    static func isUnidiffZero(_ literal: String) -> Bool {
        literal.hasPrefix(unidiffZeroShortestAbbreviation) && unidiffZero.hasPrefix(literal)
    }

    static let unidiffZeroReason =
        "without it git anchors a hunk with no context line to the whole file; with it such a "
            + "hunk applies at an offset, which removed the wrong line from a worktree (M 9) and "
            + "staged lines nobody selected into an index that changed after the diff was "
            + "loaded (A1 Task 3, Step 5). Gitter never passes it, `--cached` or not"

    /// `git remote`'s destructive words, as literals, anywhere in a file.
    ///
    /// The allowed-shape rule above can only speak for a vector it managed to classify. These
    /// are the words that make such a vector destructive, and a survey says each one can simply
    /// be forbidden outright here: `git grep -nE
    /// '"(prune|rm|remove|set-url|rename|set-head|set-branches|add|update)"' -- GitCore/Sources`
    /// returns **four** hits, all in `CLIGitBackend+WorkingCopy.swift` — `["add", "--"] + …`
    /// (:8), `["rm", "--cached", "-q", "--ignore-unmatch", "--"] + …` (:23), `["add", "-A"]`
    /// (:29) and `["rm", "--cached", "-r", "-q", "--", "."]` (:42) — so `prune`, `remove`,
    /// `set-url`, `rename`, `set-head`, `set-branches` and `update` appear in `GitCore/Sources`
    /// **zero** times and a file-wide rule on them costs nothing today.
    ///
    /// `add` and `rm` are the two that cost something, and they are not here. `git add` and
    /// `git rm --cached` are commands this app really runs; both are written as the first
    /// element of a classified vector, so `rm` is confined to the fragment list below and `add`
    /// is left out altogether — `git remote add` adds a remote rather than destroying one, and
    /// a word that names a subcommand the code uses four lines away is the wrong thing to make
    /// fatal file-wide.
    ///
    /// The future false positive is `update` (or `rename` in a rename-detection parser), and it
    /// resolves the way `--skip`'s does: move the word into the fragment list, with the grep
    /// that made it necessary written down.
    static let remoteWordsForbiddenEverywhere: Set<String> = [
        "prune", "remove", "set-url", "rename", "set-head", "set-branches", "update",
    ]

    /// `remote`'s words that `GitCore/Sources` also uses legitimately as the **first** element
    /// of a classified vector, which is a position no fragment rule looks at. So they are
    /// forbidden there, and only there: in an argument fragment or the append pool, where the
    /// shape rule cannot reach and nothing can prove what the vector is.
    ///
    /// `remote` itself is one of them — `["remote", "-v"]` is the vector Gitter runs, and
    /// `[repoFlag, "remote", …]` is the shape that hid `git remote rm`.
    ///
    /// The price of keeping these two out of the sweep, said plainly: `var a = ["remote"];
    /// a += ["rm", r]` puts `rm` in an array literal that is *classified* — by `rm` itself —
    /// rather than in a fragment, so no word rule sees it. It is a finding anyway, because the
    /// seed `["remote"]` fails the shape rule on its own, and so is every other literal
    /// spelling of that seed (`[repoFlag, "remote"]` is a fragment holding `remote`;
    /// `["remote", word]` fails the shape). What is left is the standing "only literals" hole:
    /// a seed whose `remote` is not a literal at all.
    static let remoteWordsForbiddenInFragments: Set<String> = ["remote", "rm"]

    static let remoteWordReason =
        "`git remote prune|remove|rm|set-url|rename|set-head|set-branches|update` each rewrite "
        + "or delete the user's remote configuration, and not one of them is a flag any table "
        + "can see. The only `remote` vector Gitter runs is [\"remote\", \"-v\"]"

    static let pushTagKeywordReason =
        "the keyword form names the tag by its short name; write the refspec in full, "
        + "\"refs/tags/<name>:refs/tags/<name>\" (B20)"

    static let tagFragmentReason =
        "a fragment cannot prove its shape, and `tag`'s two permitted shapes are the whole rule "
        + "(see `allowedShapes`); in a `push` it is the keyword form. Spell the vector as one array "
        + "literal beginning with its subcommand"

    static let remoteFragmentReason =
        "a fragment cannot prove its shape, and `remote`'s permitted shape — [\"remote\", "
        + "\"-v\"] and nothing else — is the whole rule. Spell the vector as one array literal "
        + "beginning with its subcommand, so the shape can be read"

    static func spelling(of subcommand: String, _ shapes: [Shape]) -> String {
        shapes.map { shape in
            let slots = shape.slots.map { slot -> String in
                switch slot {
                case .literal(let text): return text.debugDescription
                case .data: return "<data>"
                case .expression: return "<expression>"
                case .interpolated(let prefix, let suffix): return "\"\(prefix)\\(…)\(suffix)\""
                }
            }
            let tail: String
            if case .literal("--end-of-options") = shape.slots.last {
                tail = " + revisions"
            } else {
                tail = shape.allowsConcatenation ? " + paths" : ""
            }
            return "[" + ([subcommand.debugDescription] + slots).joined(separator: ", ") + "]" + tail
        }
        .joined(separator: " or ")
    }

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
    /// - **`-s` and `-u`** joined with B1 Task 2's `tag` table (sign; sign with a key): they are
    ///   `ls-files -s`/`-u` (the index and unmerged-entry reads in six files) and `push -u` (set
    ///   the upstream), checked with `git grep '"-s"\|"-u"' -- GitCore/Sources`. `tag` is
    ///   shape-governed, so a `tag` vector carrying either misses its shapes; a fragment carrying
    ///   either is still a finding.
    /// - **`-M`, `-p`, `-d`, `--all` and `--tags`** each mean something harmless under a
    ///   subcommand `GitCore/Sources` really uses, and the sweep cannot see the subcommand:
    ///   `-M`/`-p` are `diff`'s and `diff-tree`'s rename detection and patch output
    ///   (`CLIGitBackend.swift`), `-d` is `git branch -d`, the safe delete
    ///   (`+BranchDelete.swift`), and `--all`/`--tags` are `rev-list`/`log` selectors in the
    ///   "would this commit be unreferenced" counts. Each was checked with
    ///   `git grep '"<token>"' -- GitCore/Sources` before the token joined the union.
    ///
    ///   What that grep actually returns, counted again in fix round 1 because this comment
    ///   used to claim something untrue ("each of those five call sites is an array literal
    ///   beginning with its subcommand"): **eight hits across seven array literals** — `-M`
    ///   three, `--all` two, and `-p`, `-d`, `--tags` one each. **Five** of the seven are
    ///   classified — `["diff", …, "-M", …]`, `["branch", "-d", …]`, two `["rev-list", …]` and
    ///   `["log", "--exclude=refs/stash", "--all", …]` — so the per-subcommand rules see them
    ///   for what they are. The other **two** are the leading-flag `diff-tree` fragments
    ///   (`["--no-commit-id", "--name-status", "-z", "-r", "-M"]` and
    ///   `["--no-commit-id", "-p", "-U3", "-M", "-r"]`), which no per-subcommand rule can
    ///   reach: they are covered by `fragmentFindings`' `--no-commit-id` carve-out instead.
    ///   That carve-out is narrower than this subtraction but cannot replace it, because the
    ///   sweep has no array to look at.
    ///
    /// Say the consequence plainly, because these subtractions are the sweep's price and it
    /// is not zero: `let flag = "--abort"`, `"--merge"`, `"-M"`, `"-p"`, `"-d"`, `"--all"` or
    /// `"--tags"`, used as a non-literal array element, is seen by **no rule at all** — the
    /// sweep skips the token and the array rules see an element with no literal in it. Seven
    /// tokens wide rather than the whole union it used to be, but narrower, not closed.
    ///
    /// `--worktree` is the one token in the union that `GitCore/Sources` now writes on
    /// purpose (the discard literals, from the working-copy milestone), and it is not
    /// subtracted: the sweep stands down only for an element of an array that matched one of
    /// `allowedShapes`, at that element's own offset (`vouched` in `findings`).
    ///
    /// Everything else in the union — `checkout`, `clean`, `pull`, `--ours`, `-C`,
    /// `-X`, `--autostash`, `--mirror`, `--prune`, `--prune-tags`, `--delete`, `--no-verify`,
    /// `--force-if-includes`, `--force-rebase` and the rest — appears in no source file, so
    /// widening onto them produced no false positive
    /// (`gitCoreSourcesContainNoForceFlags` is the standing proof).
    static let fileWideForbidden: Set<String> =
        fragmentForbidden
        .subtracting(flagsAllowedOnlyAfter.keys)
        .subtracting(sweepExempt)
        .union(forbiddenSubcommands.keys)
        .union(remoteWordsForbiddenEverywhere)
        .union(stashWordsForbiddenEverywhere)

    /// Tokens the sweep must skip because `GitCore/Sources` uses each of them legitimately,
    /// under a subcommand the sweep cannot see. Every entry is a fact about this codebase,
    /// checked with `git grep`, not a softening of the rule — see `fileWideForbidden`.
    static let sweepExempt: Set<String> = ["-M", "-p", "-d", "--all", "--tags", "-s", "-u"]

    // MARK: - A patch read pins its format

    /// What every `git diff` vector that prints a patch must carry as lone-literal elements
    /// before its `--`, because porcelain `diff` reads the user's config and `DiffParser` reads
    /// only git's default output (fix/diff-config-prefix, measured on git 2.54):
    ///
    /// - `--src-prefix=a/`, `--dst-prefix=b/`: `diff.mnemonicPrefix`, `diff.noprefix`,
    ///   `diff.srcPrefix` and `diff.dstPrefix` each rename the `a/` `b/` the parser reads, and
    ///   every diff vanished. Explicit rather than `--default-prefix`, which needs git 2.41.
    /// - `--no-ext-diff`: `diff.external` or `GIT_EXTERNAL_DIFF` runs another program in git's
    ///   place, and each read died with exit 128.
    /// - `--no-textconv`: a textconv driver prints its own output where the file's lines go,
    ///   with the real blob ids on the `index` line — a patch built from it would pass the
    ///   preimage check with lines that are not in the file.
    /// - `--submodule=short`: `diff.submodule=log|diff` prints a gitlink as a log or as the
    ///   submodule's own files instead of its two `Subproject commit` lines.
    ///
    /// `diff-tree` is plumbing and ignores all of these (measured), so it is not in this rule.
    /// `diff.suppressBlankEmpty` has no command-line override; `DiffParser` reads its empty
    /// context line instead.
    static let diffFormatPins = [
        "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/",
    ]

    /// A `diff` vector carrying one of these prints no patch, unless it also carries one of
    /// `diffPatchOutputs`.
    static let diffNonPatchOutputs: Set<String> = [
        "--quiet", "--name-only", "--name-status", "--raw", "--stat", "--numstat", "--shortstat",
        "--summary", "--check", "--no-patch", "-s",
    ]
    static let diffPatchOutputs: Set<String> = ["-p", "-u", "--patch", "--patch-with-raw", "--patch-with-stat"]

    /// Whether a literal takes a pin back: git reads the last of each option, so a pin followed
    /// by one of these in the same vector pins nothing.
    static func undoesADiffPin(_ literal: String) -> Bool {
        if diffFormatPins.contains(literal) { return false }
        return ["--ext-diff", "--textconv", "--no-prefix"].contains(literal)
            || literal.hasPrefix("--src-prefix=") || literal.hasPrefix("--dst-prefix=")
            || literal == "--submodule" || literal.hasPrefix("--submodule=")
    }

    static func isPatchDiff(_ array: ArrayLiteral) -> Bool {
        guard array.elements.first?.value.map(decoded) == "diff" else { return false }
        let flags = Set(array.elements.dropFirst().flatMap(\.literals).flatMap(spellings(of:)))
        return flags.isDisjoint(with: diffNonPatchOutputs) || !flags.isDisjoint(with: diffPatchOutputs)
    }

    /// The findings for one array literal classified `diff`.
    ///
    /// Classified arrays only, like every per-subcommand rule: a `diff` vector hidden in a
    /// fragment (`[flag, "diff", …]`) is the standing "only literals" hole, and none exists.
    /// `["diff"] + format` is caught, because the array literal itself carries no pin.
    static func diffFormatFindings(_ array: ArrayLiteral) -> [String] {
        var findings: [String] = []
        let tail = array.elements.dropFirst()
        for flag in tail.flatMap(\.literals).flatMap(spellings(of:)) where undoesADiffPin(flag) {
            findings.append("forbidden `git diff \(flag)`: \(diffPinReason)")
        }
        guard isPatchDiff(array) else { return findings }
        let options = tail.prefix { $0.value != "--" }.compactMap { $0.value.map(decoded) }
        for pin in diffFormatPins where !options.contains(pin) {
            findings.append(
                "a `git diff` vector that prints a patch lacks \(pin.debugDescription) as an element "
                    + "of its own before `--`: \(diffPinReason)")
        }
        return findings
    }

    static let diffPinReason =
        "porcelain `diff` reads the user's config, and `DiffParser` reads git's default output "
        + "only: every patch read carries `--no-ext-diff --no-textconv --submodule=short "
        + "--src-prefix=a/ --dst-prefix=b/` and nothing that takes one of them back"

    /// How many array literals in `source` the rule read as patch-printing `diff` vectors.
    static func patchDiffVectorCount(in source: String) -> Int {
        guard unlexableConstruct(in: source) == nil else { return 0 }
        let code = strippingCommentsAndStringContents(source)
        return argumentArrays(in: source, code: code).filter(isPatchDiff).count
    }
}
