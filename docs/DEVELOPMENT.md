# Developing Gitter

How Gitter is built, packaged and tested, how the code is laid out, and the debug harness. What the app does is in the [user guide](GUIDE.md).

## Design decisions

| Area | Decision | Rationale |
|---|---|---|
| UI | SwiftUI, AppKit where SwiftUI falls short | Most Mac-native result |
| Git access | `/usr/bin/git` via `Process`, behind a `GitBackend` protocol | SSH agent, credential helpers, signing and hooks work for free. libgit2 can be added behind the same protocol for hot read paths |
| Deployment | macOS 26.0 minimum, macOS 27 SDK | Dev machine runs 27 |
| Project | xcodegen `project.yml` -> `Gitter.xcodeproj`; `GitCore` local SwiftPM package | Xcode workflow for the app; `swift test` for the core, capped by `scripts/test-gitcore.sh` |
| Staging | Patches built in-process (`PatchBuilder`) and applied with `git apply --cached`, never a hand-rolled index writer | The same command a user would run themselves; hunk- and line-level staging fall out of the same code path as whole-file staging |
| Dirty switch | git's default — carry non-conflicting changes, refuse otherwise. No force; the refusal offers Stash and Continue, never an automatic stash | A refusal that changes nothing is a better answer than a stash the user did not ask for |
| Discard | Record first (a stash entry built from plumbing in a temporary index), then `git restore` or a reverse `git apply`; untracked items to the Trash | Every discard can be undone, and the copy is in a place git and the user already know |
| Delete | `git branch -d` first, then `-D` only from the warning its refusal opened, and only if the tip is still the one that warning named | `-d` is git's own authority on "is this merged", and it changes nothing when it refuses |
| Remotes | git's own transports and credentials; `fetch`, then merge or rebase, instead of `git pull`; an explicit-sha lease on every force; no prune on fetch; one tag at a time, never replaced, the remote delete leased | Nothing to store or ask for; every step of a pull is one Gitter can explain and stop; the lease the automatic fetch cannot arm |
| Conflicts | Blocks rebuilt from the index stages with `git merge-file`, choices composed in memory and written once; git's own `--continue` / `--skip` with the message file written back, behind readiness checks of Gitter's own | The worktree file can hold anything (rerere, hand edits, marker-like code); git keeps the author, the date and the sequence, and Gitter refuses before git runs where git would lose something silently |
| Remotes housekeeping | A dry-run listing on the lane, then a per-ref compare-and-delete on the ids the sheet showed; stranded commits counted once as a union and kept as branches before anything is deleted; URLs read as configured; a failed `remote rename` / `remove` read back, never assumed a no-op | `fetch --prune` deletes whatever the server lacks at that moment; remote-tracking refs have no reflog; `remote -v` shows the rewritten URL; git leaves half-done state under a held lock |
| History actions | A plan read first (order, left out, may be skipped, replayed, already pushed), shown on a sheet, made again by the run and refused on any difference; full commit ids and `refs/…` names in every vector; tags deleted by compare-and-delete with the receipt kept in the app | A sheet is a promise only if the run checks it; a short name can mean a tag; tags have no reflog |
| Navigation | Compare reads both tips to ids once and every count, list and diff from those ids (`log --left-only` / `--right-only` over the symmetric range, the changes by `diff-tree` from the merge base); worktree removal behind Gitter's own check, made again in full before git runs, with git's settings forced; worktrees added only on a branch named in full and read back | A branch can move mid-read; a two-dot `log` disagrees with the count under clock skew; `worktree remove` deletes ignored files, hidden edits and nested repositories without asking, and `worktree add` creates or detaches what it guesses |
| Windows | `WindowGroup(for: RepositoryWindow.self)`, one `RepositoryStore` per window made by `@State private var store = AppModel.windows.makeStore()`; a `WindowRegistry` routes every open; Gitter's own reopen list, restoration off; a window still writing or mid-change hides instead of closing (`WindowCloseProxy` as its delegate) and comes back on the next open of its repository | A store per window keeps sheets, lanes and fetch schedules apart; routing keeps one index to one store; restoration cannot be told what Gitter's list knows, and a killed launch could leave state that restores no window; a hidden window's live store is the one an open finds, so its work is never run twice nor its ending lost |
| Quit | One `QuitFlow` (menu, quit Apple Event, harness), which closes every sheet and waits for AppKit to show none before terminating through `QuitGuard`, which checks every window; the quit Apple Event's reply held until the outcome; its alerts raised from a run-loop timer (`ModalAlert`) | AppKit does not ask the app whether it may quit while a window has a sheet attached; a logout learns only from the reply that the user said Don't Quit; an alert run from a main-queue block would hold up every other window's work |
| Packaging and the log | A script that builds from a clean tree only, with the commit count as the build number and the commit in `Info.plist`, re-signs with the identity you name, checks the result before the DMG and can notarize it; the log fed by a `CommandLog` sink at `CLIGitBackend`'s three git seams, written by one serial queue, never installed under the test host | Every DMG maps to a commit and says which in About; an ad-hoc identity is the binary's hash, so every build would lose macOS's folder grants; one place sees every git call, and a queue keeps the order lines were given in from any thread |
| Scope | Browsing, diffs, staging, commit, branch and remote operations, stash and discard, conflict resolution and continuing an operation, cherry-pick, revert, rebase onto a commit, tags, remotes housekeeping, the sidebar filter, comparing branches and worktrees are done | Each milestone keeps the promise before it adds the next way to lose work |

## Build & run

```sh
brew install xcodegen
xcodegen generate
open Gitter.xcodeproj
```

Or build headlessly:

```sh
xcodegen generate && xcodebuild -project Gitter.xcodeproj -scheme Gitter -configuration Debug -derivedDataPath .build/DerivedData build
```

## Packaging and installing

Gitter is shipped as a DMG for Apple Silicon, made by one script from a clean tree. A release is signed
with a Developer ID and notarized:

```sh
bash scripts/package.sh --sign "Developer ID Application: <name> (<team>)" --notarize "<profile>"
```

For your own Macs, a self-signed build is enough:

```sh
bash scripts/package.sh --sign "Gitter Local Signing"
```

It builds an arm64 Release whose build number is the commit count and whose `Info.plist` holds the
commit, re-signs it with the identity you name (without `--sign` it stays ad-hoc),
checks the signature, the hardened runtime, the architecture, the stamped version and the absence of
the Debug harness, and writes `dist/Gitter-<version>-<build>.dmg`; `GITTER_DIST_DIR` also gets a copy,
moved into place whole, for a synced folder. `--notarize <profile>` needs a Developer ID Application
identity: it signs with a secure timestamp, submits the app to Apple's notary service with the
`notarytool` keychain profile you stored, staples it, builds and signs the DMG, notarizes and staples
that too, and checks both with `spctl` before the DMG takes its final name. Every build also refuses
an app that carries `get-task-allow`. `bash scripts/package-selftest.sh` pins the refusals on a scratch clone, and that a
clean tree and a `--sign` with a value get past them to the build.
[`docs/INSTALL.md`](INSTALL.md) is the whole path: download, the Command Line Tools, updating, keeping one copy
in `/Applications`, the log, and building your own DMG.

The app icon is drawn by `scripts/make-icon.swift`, once per pixel size, and the PNGs and `Contents.json` it writes are committed; after changing the drawing, re-run `swift scripts/make-icon.swift Gitter/Assets.xcassets/AppIcon.appiconset`.

**Which build is this.** Gitter › About Gitter shows the version, the build number and, for a
packaged build, the commit: "Version 0.2.0 (440, 99be6f3)". A build from Xcode shows "Version 0.2.0
(1)".

**The log.** Every git call Gitter makes (its folder, arguments, duration and outcome, and git's own
words when it failed) and every banner, notice and alert it showed go to
`~/Library/Logs/Gitter/gitter.log`, one timestamped line each, beside a launch header and each
window's open and close. A URL's username and password are removed from every argument, and from
every `scheme://` URL in git's words, by structure; what is left is in
[`docs/INSTALL.md`](INSTALL.md) §5 — a password with an unencoded `/`, `?` or `#`, and in git's
words a password with a blank, an address without `://` or a second URL in the same word, which
get a pattern redactor only. The file rotates at 2 MB and keeps five; nothing leaves the Mac, and a
quit waits at most two seconds for its last lines. **Help › Show Logs** opens the folder in Finder. The tests never install the file
(`TestHost`), and a Debug harness launch writes only to the folder its `GITTER_LOG_DIR` names — none
at all without one, where Show Logs says "This launch keeps no log."

## Tests

```sh
bash scripts/test-gitcore.sh
```

That is the GitCore gate: `swift test` in `GitCore/` at a parallel width of 8. It prints the width
and the run's total time, passes any arguments on to `swift test` and exits with its status
(`GITTER_TEST_WIDTH` sets another width). It is capped because Swift Testing runs every test at
once by default, and that saturates the cooperative thread pool inside the test process: each
`await` then waits for a thread, and a test that times its own work fails on the queue, not on
the work. The load comes from the run itself — 28 external `yes` loops left the flaky tests at
their idle times. At width 8 every run was green and faster: five runs at the end of milestone
E1 took 215–218 s, against 264–297 s for the two uncapped ones. The width is Swift Testing's
experimental `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`, so nothing depends on it: a plain
`cd GitCore && swift test` passes too, because no test asserts a wall-clock upper bound that load
can exceed. A hang is caught by a ten-minute `.timeLimit`, a latency is measured on the runner's
own clock, and "it did not happen" is a counted event.

Or both test targets — `GitCoreTests` and the app's `GitterTests` — through the scheme:

```sh
xcodegen generate && xcodebuild -project Gitter.xcodeproj -scheme Gitter -configuration Debug test
```

`GitterTests` (852 tests in 69 suites) is hosted by the app and pins the wording the UI shows
and the decisions made from it: `OperationWording`, `RemoteWording`, `StashWording`,
`DiscardWording`, `ConflictWording`, `ContinueWording`, `HistoryWording`, `TagWording`,
`RemoteAdminWording` (the housekeeping sheets, notices, half-done states and the menus' reasons),
`CompareWording` and the compare menus' reasons, `WorktreeWording` (the rows, marks, menus' reasons,
the Add and Remove sheets and every partial outcome), the sidebar filter (`SidebarFilter`), a linked
worktree's watched paths and discard fingerprint,
when the worktree state's read starts and is written (`WorktreeReadSchedule`), a held branch's
switch refused before anything runs, the no-URL gates, Copy URL's redaction, the banners' height, the commit list's set selection, the deleted tags' receipts in the store, the pull-request link extraction and
the notices' lifetime, which files a discard is offered for and when its sheet reads git again,
which refusals Stash and Continue answers, when the toolbar reveals a lane's activity, the
resolver's choices and previews (the same composition GitCore writes), and every state of the
operation bar and the composer's prefill, and the launch guard's decisions (`DebugLaunchGuard`),
and the diagnostics log: its lines (`LogLine`), the file's order, rotation, recreation and stop
(`LogFileWriter`, in a temporary folder only), the events a store and the window registry write, the
quit question's answer, Show Logs' failures and a launch with no writer through a seam, the quit's
bounded flush with a writer stuck on a hung write, and the About panel's version.
Under a test host the app reopens no repository, starts no automatic fetch and adds nothing to
Open Recent, and keeps no list of open repositories (`TestHost`). Every test's store keeps its settings in a scratch defaults suite of
its own, named by a path inside its own temporary folder and removed with it (`makeTestStore`),
so a run never touches the repository you last had open or the app's real `dev.penzin.Gitter`
defaults, and leaves nothing in `~/Library/Preferences`; `DefaultsIsolationTests` reads the real
domain before and after each of its tests, never writing it, and tests the reopen and Open
Recent decisions.

**One support library for both test targets.** `GitCoreTestSupport`, a library in GitCore's
package with no dependency on GitCore itself (one that had it would link a second, static copy of
GitCore into the app's test bundle), holds what both test targets need: `CallUnderTest`, the wait
every guarded call goes through, and `StuckCall`; `neverCameBack` and `Issue.isNeverCameBack`;
`TestGitEnvironment.isolated`; and `waitForExit`, which waits for a process's exit on kqueue's
`NOTE_EXIT` instead of polling. `GitCoreTests` and `GitterTests` (through `project.yml`) import it,
and the app never links it — the Release build has no trace of it.

**GitterTests runs on isolated real git.** Every git a GitterTest causes runs under
`TestGitEnvironment.isolated`, from that library (your git configuration and system configuration
are not read, no ssh agent or askpass, only the `file` transport): `makeTestStore`, `ScratchRepo`,
`TestBackend` and the scratch registries refuse to run without it, and a control reads `git config
--show-origin --list` through a store's own backend and asserts that nothing comes from outside the
repository. `ScratchRepo` makes a temporary repository (with an optional local bare remote) and
removes only its own directory. `waitUntilIdle` waits for a store's lane, mutation, worktree read
and scheduled refresh to settle, bounded by a ten-minute `.timeLimit` through `CallUnderTest`.
Store-level flows run on that real git:
a stash pop that conflicts, applies partly or is kept after a failed drop, Stash and Continue after
a refused `track`, `detach` and create-and-switch, and a Continue refusal, its sheet and the retry
(including the index changing between the sheet and Continue, and everything unstaged). Two
windows' stores, `WindowRegistry` routing and the reopen list, `QuitFlow` and `QuitGuard` over
several stores, the quit Apple Event's replies (over a recording fake of the reply seam) and a
window closed while its push is still running (a push held by a `receivepack` script until the
test lets it go) are tested the same way.

**A test backend over real git.** `TestBackend` (GitterTests) forwards every one of the twelve
backend protocols' 104 calls to a real `CLIGitBackend` on the test's scratch repository, and lets a
test act at any one call: run code before or after it (`hook`), make the next one throw without
running git (`fail`), park the next one until the test lets it go (`hold`, on a `StuckCall`),
replace the stash pop with one that changes the repository between its apply and its drop
(`replacePop`), and read the calls in order (`calls`); `releaseAll()` ends every hold at teardown.
A call is named by a typed `TestBackend.Call` whose raw value is the method's own `#function`
spelling, so a misspelt name does not compile; the forwarder hands in its own key, which is checked
at run time and, for every forwarder, by a test that reads the source. On it run the stash list
moved before a pop's drop (`StashDropRaceTests`), a reload that fails after a commit
(`InjectedFailureTests`), a window closed during a held commit or push (`HiddenWindowTests`) and
every request made while a change is held (`RequestsDuringChangeTests`).

`GitCoreTests` has 1 706 tests in 145 suites. Most of them run real `git` against a temporary
repository rather than a fake — the remote tests against local bare repositories standing in
for a server, with a second clone as "the colleague" who pushes in between — including one
that greps `GitCore`'s own sources for forbidden force flags. The suite isolates itself from
your git configuration (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`) and never
touches the network: the transports other than `file` (and a fake ssh one test needs) are refused,
and an inherited `GIT_SSH_COMMAND` or `GIT_CONFIG_*` is cleared first.

The run also reports **114 known issues, and they are meant to be there** — please do not
"fix" them. They are deliberate negative controls: tests that make an assertion helper fail
on purpose, inside `withKnownIssue`, to prove it *can* fail.

- Four come from the two controls in `WorktreeAssertions.swift`, which change a file and then
  pass an empty baseline to `assertWorktreeUnchanged`, recording two failures each. Every
  "nothing was touched" claim in this suite rests on that one function, and a bug once made
  it silently vacuous (it compared resolved symlink paths, so every snapshot came back empty
  and every assertion passed).
- Two come from `RemoteAssertionsTests` in `RemoteTestSupport.swift`: a ref that really moved
  on the server, and a baseline with no refs, each recording one failure of
  `assertRemoteUnchanged` — the helper behind every "the server is byte-for-byte what the
  colleague left" assertion.
- Two come from `assertRecordPure` (`StashRecordTests`), the check that building a discard's
  record leaves your real index byte-identical with the same timestamp: an index rewritten
  with identical bytes, and a new branch.
- Three come from `assertWorktreeState` (`DiscardSupport.swift`), the lstat snapshot every
  discard and undo is checked with, which must see what a byte snapshot cannot: a changed
  executable bit, a retargeted link and an emptied directory.
- One comes from `Bystanders`: the unrelated file with both a staged and an unstaged layer that
  every discard must leave alone, its staged layer unstaged on purpose.
- Three come from the staging preimage check's `expectRefused`
  (`PartialStagingPreimageTests`): a patch on a fresh index, which really applies.
- Two come from `OperationStateTests`: `assertOperationUnchanged`, the fingerprint of a
  stopped operation (pseudo-refs, `*_MSG`, `AUTO_MERGE`, the `rebase-merge/` and `sequencer/`
  files, the unmerged stages, HEAD's commit and the branch it names, and the refs) that every
  conflict write, continue and skip test compares, made to fail by deleting `MERGE_MSG` and by
  HEAD naming another branch at the same commit.
- Two come from `WriteBaselineTests`: `assertOnlyThePathChanged`, which lets a conflict write
  change its own path and nothing else, made to fail by another changed file and by a changed
  `MERGE_MSG`.
- One comes from `UntouchedTests`: the `Untouched` capture the continue and skip tests use for
  "the stop is intact".
- One comes from `HistorySnapshotTests`: `HistorySnapshot.assertUnchanged` (the repository's
  state and the worktree's bytes), which every refused cherry-pick, revert, rebase and tag write is
  checked with, made to fail by a new branch.
- One comes from `GitLaunchLogTests`: `GitLaunchLog`, the git wrapper that proves a refusal
  launched no process at all (`assertNothingRan`), made to fail by a real `rev-parse`.
- Two come from `UpstreamTestSupportTests`: `assertConfigUnchanged`, which every refused or
  failed upstream, fast-forward and remote write is checked with, made to fail by a changed
  `branch.<b>.rebase` and by an empty baseline.
- One comes from `RemoteAdminTestSupportTests`: `refTips(under:)`, behind every "nothing fetched"
  and "nothing left" under a remote's prefix, made to fail by a ref created there.
- One comes from `NoURLRemoteTests`: git itself, handed an unconfigured remote name, pushes into
  a directory of that name — the hazard Gitter refuses — and `assertRemoteUnchanged` sees it.
- Six come from `CompareTests`: `assertNothingRan` made to fail by a comparison that really runs
  git (twice); the files, the diff and the count read **by name** after both branches moved, which
  follow the moved refs where the comparison's ids do not (three); and git's two-dot `log` under
  clock skew listing the merge base, which the symmetric walk Gitter uses does not.
- Three come from `WorktreeAddTests`: git adding a worktree inside the main one and creating a
  tracking branch for a remote-only name (R17) — both refused by Gitter before git runs — and the
  launch log made to fail by a `worktree add` that really ran.
- Twenty-four come from `WorktreeRemovalTests`: for every refusal that guards a silent deletion, raw
  `git worktree remove` deletes what Gitter protects — the worktree it is run from, one mid-rebase,
  -merge or -bisect (one per operation), an assume-unchanged and a skip-worktree edit, a repository
  nested in an ignored folder, one spelled `.GIT`, the contents of a `.git` folder `status` skips
  (one per spelling), the files around an unreadable folder, an edit a lying `core.fsmonitor`
  hides, an ignored file swapped for another of the same count (with the count-only compare that
  misses it), an untracked file under `status.showUntrackedFiles=no`, and a commit only the
  worktree's own `refs/worktree/save` holds — unreachable afterwards, on a branch worktree, a
  detached one, a missing one and in a reftable repository; plus the count-only compare that misses
  stranded commits swapped for others of the same count; plus the launch log made
  to fail by a `worktree remove` that really ran, a worktree off the list that is not a removed one
  (a folder git could not delete, and one replaced by a link), and `rev-list --all` counting the
  worktree being removed (R22).
- Twelve come from the hang guards that replaced wall-clock bounds (milestone E1). A
  time-limit failure cannot itself be a known issue, so each control cancels its waiter and
  shows the stuck call reported as "never came back". Three are `TimeLimitSupportTests`, on
  `CallUnderTest`, the wait every guarded call goes through: a call that never returns, a wait
  started after the cancel, and the first of two waits on one call (the second still gets the
  answer). Nine stand for a `.timeLimit` in `StreamingRunnerTests`, `FetchTests`, `PushTests`
  and `LeasePushTests`: the 300-cancel stress loop, a call that waits out a child ignoring
  SIGTERM (two shapes), one the abandonment never ends (three), and a fetch, a push and a force
  push the cancel did not stop.
- One comes from `aDeliverySpreadOverMoreThanThreeSecondsFailsTheBound`: the stderr delivery
  bound, measured on the pipe's own queue, fails on pieces 3.2 s apart.
- One comes from `withoutAForkTheStormsProofFails`: the fork-storm test proves its race by
  counting the SIGKILLs the runner sends a reaped leader's group, and a leader that forks
  nothing gives none.
- Three come from the runner's escalation in `StreamingRunnerTests`: a reap recorded only
  after the call came back leaves a helper that ignores SIGTERM running (the residual the
  "Own the reap" gap names), and an escalation one grace early and one past the
  margin each fail the latency check, which is taken on the runner's own clock.
- Four come from the scoped process checks (`OwnProcessTests`, `StreamingRunnerTests`): a leak
  check fails on a process of the test's still running, a cleanup whose query fails is
  recorded rather than swallowed, and the stress marker that outlives its SIGTERM is killed by
  its group — two of them, since milestone E3: the wait for its reap, now on `NOTE_EXIT`, is
  reported as never having come back when the test is cancelled, and the marker is named as having
  outlived its SIGTERM.
- One comes from `ProcessExitTests`: `waitForExit`, the shared wait on kqueue's `NOTE_EXIT`, on a
  process that never exits is reported as never having come back once the test is cancelled.
- Twenty-two come from `ConfigCountTests`: the cross-check every row of `GIT_CONFIG_COUNT`'s table
  goes through, which asks the real git how it reads the value, catches a parse that is not git's —
  Swift's `Int(_:)`, the parse before E3, disagrees with git on twenty-two rows (a leading space, a
  count git refuses, which that parse read as 0, a count over `INT_MAX`, a negative that wraps). Only
  the comparison's own failures are the known issue: anything else the cross-check records fails.
- Two come from `UpstreamStateTests`: `TestRepo.upstream(of:)` treats a branch that does not
  exist, and one whose name is only a prefix of another's, as a failure rather than "no
  upstream".
- Two come from `WorkingCopyBackendTests`: a `restore` that recurses into a registered
  submodule really loses the work inside it — the hazard the unstage's
  `--no-recurse-submodules` keeps away, so the fixture can show it.
- Seven come from `CommandLogTests` (milestone P1): a recording log that was not passed to the
  backend gets no entry; the prose redactor alone — the only one before the structural strip — hands
  a password with a parenthesis back in an argument, and in each of the two lines of git's words the
  final review probed; and three pins of what is still kept: an scp-form password with a parenthesis
  in git's words, and a password with an unencoded `/` in two URLs.

`GitterTests` reports **forty-eight known issues** of its own, as deliberate. `WorktreeHeldSwitchTests`
shows that the operation gate alone lets a branch another worktree holds through, which is why
the switch asks about the hold first. Three come from `DefaultsIsolationTests`: the check that
the real defaults are unchanged fails when a store writes the domain it watches (a scratch
suite standing in for the real one), directly, inside a test's scope, and in a test that writes
and then throws. Twelve are the controls of the helpers added in milestone E2:
- Nine come from `ScratchGitTests`: a config include from outside the repository is caught by the
  isolation check; `waitUntilIdle` on a store held busy and on a stuck refresh is reported as
  "never came back" instead of freezing; a failed open is recorded instead of hanging; the shared
  hang guard reports a stuck call; a transport that never starts, a condition that never holds, a
  lane that never frees and a store that never leaves the registry are each caught by the waits
  built on `waitUntil`.
- One comes from `HarnessControlsTests`: the control modifier applied outside the control's
  `.disabled` reads the control as enabled.
- One comes from `DebugLaunchGuardTests`: a `linkedRepo` that is a plain directory and not a link
  to the repository is another path.
- One comes from `OpenRoutingTests`: before the launch has taken it, an open is held, not handed to
  the window opener.

Nineteen come from milestone E3:
- Five come from `ModalAlertTests`: a test expecting the alert to have run by the time `raise`
  returns fails, since it is raised from a timer; the
  modal-panel spin the tests use cannot run a main-queue block, nor fire a timer added in `.default`
  alone (why the alert's timer is in both modes); under an alert run from a main-queue block,
  `QuitGuard`'s old form, no other main-actor job runs; and a timer added in `.common` does run
  inside a menu's tracking (`.eventTracking`), which is why the alert's is not.
- One comes from `QuitEventReplyTests`: a called-off quit answers −128, so a test expecting 0 fails
  against the recording fake.
- Five come from `TestBackendTests`: a call keyed by another method's name is recorded; the call log
  holds no call the store never made, and not in the reverse order (two); the hooks run before, then
  after, whatever order they were added in; a hold nobody releases is caught by the hang guard; and
  a store whose push is still held never settles (`waitUntilSettled`, the teardown's wait).
- Six come from `HiddenWindowTests`: the recorder of a hidden window's AppKit calls records nothing it
  was not asked (two); a hidden store whose alert closed it, judged by its window alone, would be told
  twice under a held quit; the hidden ending's alert gives Return to Show alone, not to Close nor to a
  button given Escape (two); and one is a known defect, not a control — a store closed through E2's
  path in the middle of a commit stays mutating (a known defect), now reachable only when a
  window was never attached.
- One comes from `StagedSideTests`: setting the side and then the path, the old two steps, loads the
  same diff twice.

Six come from milestone P1: `LogFileWriterTests` expects six rotated files where five are kept in
all, so four are rotated, and an idle writer's bounded flush to have timed out, and its wait for the
queue (`settle`) on a writer stuck on a hung write is reported as never having come back; `AppLogTests` expects
a banner's line from a store that was not given the recorder, and a window's close line where no quit
began; `LogLineTests` expects a backslash kept as it is, where it is doubled.

Seven come from the window polish: `AppIconTests` looks up an icon the bundle does not have and an
icon name its `Info.plist` does not give (two); `SplitViewAutosaveTests` expects the outer split
view, the sidebar's, where the one a pane sits in is the nearest, expects a split view that already
has an autosave name to be the one it names, expects a name to be given under the test host, and
expects a hosted view told it is not under the test host to give none (four); and
`CommitSelectionTests` expects the history table's write to leave the selection alone with no
comparison up (one).

Deleting any of them would take the proof away and the suite would go on looking green.

## Project layout

Every `.swift` file in the two product targets and the test-support library beside GitCore — 211
of them, which is what `find GitCore/Sources Gitter -name '*.swift' | wc -l` prints — with the ones
inside `Models/`, `Parsers/` and `Views/` named in prose rather than one per line. The 203 test files
(137 in `GitCore/Tests`, 66 in `GitterTests`) and `GitCore/Package.swift` are summarised rather than
listed, which is also why the check is that command and not a bare `find . -name '*.swift'`:
that one reaches them too, and the generated sources under `.build` as well.

```
GitCore/                  SwiftPM package, no SwiftUI dependency
  Sources/GitCore/
    GitBackend.swift            Read-only protocol: snapshot, log, refs, diffs
    GitWorkingCopyBackend.swift Staging/commit/amend protocol and its contract
    GitBranchBackend.swift      Branch/merge/abort protocol and its contract
    GitRemoteBackend.swift      Fetch/push/lease/rebase protocol and its contract
    GitStashBackend.swift       Stash list/push/apply/pop/drop protocol, its outcomes and refusals
    GitConflictBackend.swift    Read a conflict, resolve/take/delete/keep, Mark Resolved, Reopen;
                                ConflictError, ConflictReceipt, ReopenedFile
    GitOperationBackend.swift   Progress, the pending message, the operation's paths, Continue,
                                Skip and their readiness, halted and stale ranges
    GitHistoryBackend.swift     Cherry-pick, revert and rebase onto a target: plan, then run
    GitTagBackend.swift         Tag names, create, compare-and-delete and restore, push one,
                                leased remote delete; TagNameProblem, TagReceipt, TagOperationError
    GitRemoteAdminBackend.swift Prune and gone branches, fast-forward and upstream of a branch,
                                add, set-url, rename and remove a remote
    GitCompareBackend.swift     Compare two branches: counts, lists, merge bases, the changes
    GitWorktreeBackend.swift    List worktrees, their changes, the removal check, add and remove
    DiscardTypes.swift          DiscardRequest, DiscardReceipt, the refusals and undo outcomes
    Trasher.swift               Moving an untracked item to the Trash and back
    GitError.swift              commandFailed, launchFailed, and the two pre-flight refusals
    CommandLog.swift            The sink every git call is reported to once, after it ended:
                                CommandLogEntry (outcome, arguments and stderr redacted and cut,
                                a URL's userinfo stripped by structure), NoCommandLog
    FetchRefspec.swift          Which configured fetch refspecs write outside refs/remotes/
    BranchOperationTypes.swift  MergeMode, MergeOutcome, BranchDeletion, the typed refusals
    RemoteOperationTypes.swift  PushOutcome, PushResult, RebaseOutcome, RemoteOperationError,
                                PullPlan, PushTarget (where a push goes), StopClick
    CLIGitBackend.swift         The implementation over /usr/bin/git, plus
      +WorkingCopy.swift          staging (and its preimage check), commit, amend (and the
                                  amend-mid-operation refusal)
      +Environment.swift          rerere turned off through the environment, for every apply
      +Stash.swift                the stash list, an entry's contents, push, apply, pop, drop
      +StashRecord.swift          the path-limited record in a temporary index, and stashPaths
      +Discard.swift              discard and its undo; every worktree `git apply`
      +Pathspecs.swift            path lists in a pathspec file, reads in batches
      +ConflictRead.swift         the two rebuilds, the whole-file kinds, what git wrote,
                                  `AUTO_MERGE`'s staleness, canReopen, reopenedFile
      +ConflictWrite.swift        resolve, take, delete, keep, Mark Resolved, Reopen
      +Continue.swift             progress, the message, operationPaths, Continue, Skip,
                                  halted and stale ranges
      +ContinueMessage.swift      the pure message helpers: the merged name, the message file,
                                  comments and their character, scissors, empty after cleanup
      +Branches.swift             create, switch, detach, track, rename
      +BranchDelete.swift         `branch -d`, and `-D` only against an expected tip
      +Merge.swift                the three merge modes and the name/tag comparison
      +Abort.swift                the five `--abort`s and `reset --merge`
      +Operation.swift            which of the six operations is part-way through
      +Remotes.swift              fetch, commit lists, the "held only there" count
      +Push.swift                 push, publish, the leased force push and delete
      +Rebase.swift               the pull's rebase, the rebase-onto plan and run, and what a
                                  stopped one means
      +History.swift              the cherry-pick and revert plans, the run and its read-back
      +Tags.swift                 tag names, create, delete, restore, the remote read, push and
                                  leased delete, the remotes that fetch no tags
      +Prune.swift                the dry-run listing, the stranded union, kept branches, the
                                  per-ref compare-and-delete, gone branches
      +Upstream.swift             fast-forward of a branch that is not checked out (and the
                                  worktree scan), set and unset upstream with the read-back
      +RemoteAdmin.swift          remote names, URLs as configured, add, set-url, rename, the
                                  removal impact and remove, each failure read back
      +Compare.swift              the tips resolved once, the count, the two lists over the
                                  symmetric range, merge bases, the changes from the merge base
      +Worktrees.swift            the list, changes, the removal check (the walk, the forced
                                  settings), add and remove, each read back
    ProcessRunner.swift         Process spawning with LC_ALL=C and captured stderr
      +Streaming.swift            the cancellable runner: progress, SIGTERM then SIGKILL, and
                                  whether git exited or was killed
    GraphLayout.swift           gitk-style commit lane assignment
    PatchBuilder.swift          Builds a hunk- or line-level patch from a parsed diff, with
      +Markers.swift / +Paths.swift
    Models/                     RepoSnapshot, Commit, FileStatus, Diff, Branch (and Tag), Graph,
                                Remote, Stash, Conflict, OperationProgress, History,
                                RemoteAdmin, Compare, Worktree (with WorktreePaths)
    Parsers/                    Status, Log, Ref, Diff (+Paths), BranchRefusal, Remote,
                                PushPorcelain, RemoteFailure, StashList, StashFailure,
                                Conflict and WorktreeList parsers, and GitLines (git's output
                                split at the newline byte)
  Sources/GitCoreTestSupport/   The test-support library both test targets import, never the
                                app, with no GitCore dependency: CallUnderTest, StuckCall and
                                neverCameBack (TimeLimitSupport), TestGitEnvironment.isolated,
                                waitForExit (ProcessExit, kqueue's NOTE_EXIT)
  Tests/GitCoreTests/           145 suites; ForceFlagScanner(+Lexing) is the force-flag grep

Gitter/                   macOS app (SwiftUI)
  GitterApp.swift            App entry point, `AppModel` (the window registry), the menus
                              (File, Repository, Remotes, Quit), Open Recent, the quit Apple
                              Event and the Finder and Dock hooks (`AppDelegate`)
  RepositoryWindow.swift     What a window shows (`RepositoryWindow`) and the window's view,
                              which owns its store and takes the launch
  WindowRegistry.swift       Every window's store: open routing, the reopen list, closing a
                              window, hiding one still working and its ending (HiddenEnding),
                              the launch plan
  WindowCloseProxy.swift     The window delegate that answers a close: hide a busy window,
                              forward everything else to SwiftUI's own delegate
  RepositoryStore.swift      @Observable @MainActor store: snapshot + selection state
  RepositoryStore+Opening.swift   Opening a repository, checking git is there
  RepositoryStore+Refresh.swift   Debounced, coalesced snapshot reloading
  RepositoryStore+Detail.swift    Loading the detail pane's files and diff
  RepositoryStore+Staging.swift   Stage/unstage whole files, hunks and lines; `mutate`
  RepositoryStore+Commit.swift    Commit, amend, and the amend gates
  RepositoryStore+WorkingCopyState.swift  Derived staged/unstaged state and button titles
  RepositoryStore+Branches.swift  Switch, track, detach, create, rename, merge
  RepositoryStore+BranchSheets.swift  Opening the sheets, delete, abort, name validation
  RepositoryStore+BranchState.swift   HEAD, refs and what is allowed right now
  RepositoryStore+Errors.swift    Turning a refusal into the sentence the banner shows
  RepositoryStore+Remotes.swift   The network lane: fetch, pull, push, cancel, blocked reasons
  RepositoryStore+RemoteSheets.swift  Pull, publish, force push and delete-on-remote sheets
  RepositoryStore+Notices.swift   The transient and the sticky notice, and their buttons
  RepositoryStore+Stash.swift     Stash, apply, pop and drop; the Pop Stash notice by sha
  RepositoryStore+Discard.swift   The discard sheet's model, the gates, discard and Undo
  RepositoryStore+StashAndContinue.swift  Which refusals a stash answers, and the retry
  RepositoryStore+Conflicts.swift The resolver: its document, choices, writes, Reopen
  RepositoryStore+Continue.swift  The operation bar, Continue, Skip, Stage All's question,
                                  the composer's prefill
  RepositoryStore+History.swift   The commit set, cherry-pick, revert, rebase onto: plan, sheet,
                                  run, notices
  RepositoryStore+Depth.swift     History's depth: load older commits, reveal one not loaded
  RepositoryStore+Tags.swift      New, delete, restore, push and remote-delete a tag; the
                                  deleted tags' receipts
  RepositoryStore+RemoteAdmin.swift  Prune, clean-up, push / fast-forward another branch,
                                  upstream, and the remote sheets: requests, gates, notices
  RepositoryStore+Compare.swift   Compare mode: the comparison, its staleness, Swap, Refresh,
                                  Done, the menus' reasons
  RepositoryStore+Worktrees.swift The worktree state, Open, Add and Remove (and Remove All
                                  Missing), the folder check, the held-branch reasons, the title
  SidebarFilter.swift        Which rows the sidebar filter leaves, and its words
  AutoFetchScheduler.swift   When the quiet automatic fetch runs (the store decides what it does)
  QuitGuard.swift            Quitting while a lane is busy, in any window: stop, or ask first
  QuitFlow.swift             The one way to quit: close every sheet, wait for AppKit to show
                              none, then terminate
  QuitEventReplies.swift     The quit Apple Event's held replies and the seam that answers them
  AppLog.swift               The diagnostics log at the composition root: the writer (none under
                              the test host), GitCore's sink and the stores' EventLog, the launch
                              header, Help › Show Logs
  LogFileWriter.swift        gitter.log on one serial queue: append, rotate, recreate, stop
  LogLine.swift              The log's words: the time, escaping, a git call's line and stderr
  AboutPanel.swift           Gitter › About Gitter's version, build and commit from Info.plist
  ModalAlert.swift           An app-modal alert raised from a run-loop timer, so other work goes
                              on under it
  RemoteActivity.swift       What the lane is running, a refused push, the progress relay
  RemoteWording.swift        Every sentence about the network, and making server text plain
  StashWording.swift         Every sentence about a stash and Stash and Continue
  DiscardWording.swift       Every sentence a discard, its sheet and its Undo show
  ConflictWording.swift      Every sentence of the resolver and its sheets; side labels
  ContinueWording.swift      Every sentence of the operation bar, Continue, Skip and the
                              halted and stale ranges
  HistoryRows.swift          The commit table's rows, built once per snapshot, with the end
                             row and the graph column's width (H1)
  HistoryWording.swift       Every sentence of the cherry-pick, revert and rebase sheets,
                              refusals and notices
  TagWording.swift           Every sentence about a tag; the rows, the pills, the receipts
                              (DeletedTags) and the remotes seen holding a tag (RemoteTagsSeen)
  RemoteAdminWording.swift   Every sentence of remotes housekeeping: the sheets, the menus'
                              reasons, the notices and the half-done states
  CompareWording.swift       Every sentence of compare mode, its sheet and its menus
  WorktreeWording.swift      Every sentence about a worktree: rows, marks, menus, the Add and
                              Remove sheets, notices and partial outcomes
  Notice.swift               A notice's text, links and buttons, and the link extraction
  BranchSheet.swift          Which confirmation or form the store wants on screen
  CommitDraft.swift          The commit message + amend toggle being edited
  RepositoryWatcher.swift    FSEvents-based debounced refresh trigger, with the paths a linked
                              worktree needs (its git directory and the shared refs)
  OperationWording.swift     Every sentence the UI says about an operation in progress,
                              including the abort confirmation's five wordings
  DebugLaunchHooks.swift     Debug-only launch hooks for screenshot verification (see below),
    +Events.swift              posted clicks, keys and the responder dump
    +Branches.swift            the `GITTER_DEBUG_BRANCH_ACTION` step list
    +Quit.swift                its `quitevent` step
    +Stash.swift               its stash steps
    +Discard.swift             its discard steps
    +Conflicts.swift           its resolver steps
    +Continue.swift            its operation bar and composer steps
    +History.swift             its history and tag steps
    +RemoteAdmin.swift         its remotes housekeeping steps
    +Navigation.swift          its filter, compare, worktree and window steps
    +Controls.swift            its sheet-control steps (`controls`, `press:`, `tick:`, `fill:`,
                               `choose:`)
    +Layout.swift              its window layout steps (`split`, `togglesidebar`, `resize:`,
                               `divider:`, `sidebarwidth:`)
  HarnessControls.swift      Debug-only: the registry sheets put their controls in, by label
  DebugLaunchGuard.swift     Debug-only: a scripted launch never reaches the last repository
  Views/                     MainWindow, SplitViewAutosave, SidebarView, SidebarMenus,
                              StashesSection, CommitListView, CommitGraphCell, DetailView,
                              StashDetailView,
                              WorkingCopyFileList, CommitComposerView, DiffView, DiffHunkView,
                              DiffLineSelection, Banners, BranchToolbar, BranchNameValidator,
                              BranchSheetHost, RemoteToolbar, TrackingBadge, CompareListView,
                              WorktreesSection,
                              ConflictResolverView, ConflictBlockView, OperationBar (with the
                              halted bar), KeepBranchList (with RefIDList, the ref and id list
                              both sheets share) and the thirty-four sheets (NewBranch,
                              Rename, Merge, DeleteBranch, Abort, LeaveDetached, Pull, Publish,
                              ForcePush, DeleteRemoteBranch, Stash, DropStash, Discard,
                              ReplaceHandEdited, MarkResolved, ReopenConflict, ContinueEmpty,
                              Skip, StageAll, HistoryAction, RebaseOnto, NewTag, DeleteTag,
                              DeleteRemoteTag, Prune, GoneBranches, Upstream, AddRemote,
                              EditRemoteURL, RenameRemote, RemoveRemote, CompareBranches,
                              AddWorktree, RemoveWorktree)

GitterTests/              The app's tests (Swift Testing, hosted by Gitter.app): wording,
                          notices and links, the discard (and its sheet's stale check) and
                          Stash and Continue decisions, the toolbar's activity reveal, the
                          resolver's choices, the operation bar's states and the prefill,
                          the history and tag wording, the commit set and the deleted tags'
                          receipts, remotes housekeeping's wording and menu reasons, the
                          no-URL gates, Copy URL's redaction, the banners' height, the
                          launch guard, compare's and the worktrees' wording and menu
                          reasons, the sidebar filter, a linked worktree's watched paths
                          and fingerprint, the worktree read's schedule, a held branch's
                          switch, the test-host check, and the scratch defaults every test
                          store is built on (`TestStoreSupport`, `DefaultsIsolationTests`);
                          and on isolated real git (`TestGitEnvironment` from the support
                          library, `ScratchRepo`, `StoreIdle`, `HeldTransport`, `TestBackend`):
                          the stash and continue flows, the stash drop race and an injected
                          failure, the window registry, open routing and the reopen list,
                          closing and hiding a window, requests during a change, `QuitFlow`,
                          `QuitGuard` and the quit event's replies, `ModalAlert`, the
                          diagnostics log's events, and the harness's control registry; the
                          log's lines, file and About panel need no git
```

## Debug launch hooks

`Gitter/DebugLaunchHooks.swift`, `DebugLaunchHooks+Events.swift`,
`DebugLaunchHooks+Branches.swift`, `DebugLaunchHooks+Quit.swift`, `DebugLaunchHooks+Stash.swift`,
`DebugLaunchHooks+Discard.swift`, `DebugLaunchHooks+Conflicts.swift`,
`DebugLaunchHooks+Continue.swift`, `DebugLaunchHooks+History.swift`,
`DebugLaunchHooks+RemoteAdmin.swift`, `DebugLaunchHooks+Navigation.swift`,
`DebugLaunchHooks+Controls.swift`, `DebugLaunchHooks+Layout.swift`, `HarnessControls.swift` and
`DebugLaunchGuard.swift` exist only in Debug builds
(`#if DEBUG`, compiled out of Release) and drive the UI from environment variables, read once at
startup. They exist because the verification environment has Screen Recording but not
Accessibility, so nothing outside the process can click — without these, a diff can never be put
on screen from a script, and a focus bug can never be reproduced.

**The launch guard.** A launch with any `GITTER_DEBUG_*` variable set is a script's, and it never
reaches the repository you last had open: it does not reopen it, starts no automatic fetch
(unless `GITTER_DEBUG_AUTOFETCH` asks for one), opens `GITTER_DEBUG_OPEN` first, and runs no
selection, staging, click, key or step unless the repository on screen is that path (compared
with links resolved). Before this guard the app reopened the last repository and
a script's steps ran against whatever had loaded — measured with a scratch stand-in: a script
with no `GITTER_DEBUG_OPEN`, or whose own open failed, force-deleted a branch of the reopened
repository. Each refusal is logged as `BRANCH_ACTION launch guard: refused: …`, and the app then quits
by itself, through the same quit as ⌘Q (a refused step does the same, and so does a launch
whose repository has no snapshot loaded before the steps or before `GITTER_DEBUG_THEN`), so a
refused launch no longer waits for a watchdog. A scripted launch does not add the repositories it opens
to Open Recent. A scripted launch also keeps its windows out of the reopen list (`openRepositoryPaths`) and, in
a second window, acts only on a repository the launcher named (`GITTER_DEBUG_ALSO_OPEN`, below).
A launcher should still write `lastRepositoryPath` and
`autoFetchEnabled=false` (and read them back) before it starts the app, export the app's
defaults first and restore them afterwards — `defaults import` only merges, so the restore step
is: import the export, compare the key sets of the export and of the domain after the run, run
`defaults delete dev.penzin.Gitter <key>` for each key that was absent before (never delete the
domain), export again and `cmp` the two exports. The keys are not only the launcher's own:
AppKit writes its own, and a second window adds
`NSSplitView Subview Frames main-AppWindow-2, SidebarNavigationSplitView`; the first launch with a
repository open adds `NSSplitView Subview Frames CommitListDetail`, where the commit list / detail
divider is kept. The launcher also passes `-ApplePersistenceIgnoreState YES`, so a
launch that has to be killed — a refused one, or one whose quit a sheet held — cannot leave your
saved window state restoring to no window (B3 Task 4, measured). And it sets `GITTER_LOG_DIR` to a
folder in its own scratch directory (P1), where the launch's diagnostics log goes instead of
`~/Library/Logs/Gitter`; a scripted launch without it keeps no log at all, so a script can never
write your real one.

| variable | effect |
|---|---|
| `GITTER_DEBUG_SELECT_PATH=<path>` | select that file in the working copy |
| `GITTER_DEBUG_STAGED=1` | select it on the staged side instead |
| `GITTER_DEBUG_SELECT_COMMIT=<rev>` | select a commit (`HEAD` = the newest) and, with no `SELECT_PATH`, its first file |
| `GITTER_DEBUG_SELECT_LINES=3,4` | pre-select those line ids in the first hunk |
| `GITTER_DEBUG_APPLY=hunk:0` or `lines` | then stage/unstage that hunk, or those lines |
| `GITTER_DEBUG_WINDOW=1400x1400` | resize the window, past the screen if asked |
| `GITTER_DEBUG_OPEN=<path>` | the fixture: opened first, as "Open Repository…" would, and the only repository any hook acts on (the launch guard above), apart from the ones `GITTER_DEBUG_ALSO_OPEN` names. A failed open leaves nothing to act on, so every step is refused |
| `GITTER_DEBUG_ALSO_OPEN=<path>[:<path>…]` | the other windows' repositories: the only paths a `newwindow:` step may open, and, once a window shows one of them, repositories the guard accepts as that window's own. Any other path is refused |
| `GITTER_DEBUG_APPEARANCE=light\|dark` | force the app's appearance, so a screenshot pass can shoot both without changing the machine's setting |
| `GITTER_DEBUG_CLICK=x,y[:2\|:shift\|:right][;…]` | click those points, in points from the top-left of the *frontmost* window's content area — the sheet's own, while one is up; `:2` double-clicks, `:shift` shift-clicks, a `type=text` step types between two clicks, and `:right` posts a right-click, which is kept as a recorded negative result: it does not open a SwiftUI `.contextMenu` |
| `GITTER_DEBUG_KEYS=space,return,cmd+return` | then press those keys (`space`, `return`, `tab`, `escape`, `up`, `down`, `period`, `f`, `l`, `p`, `r`, `delete` (⌫), `q`, with `cmd+`/`shift+`/`opt+`/`ctrl+`; `cmd+q` reaches Gitter's own Quit Gitter item and quits as ⌘Q does, with a sheet up as well). A key with `cmd+` is dispatched as AppKit dispatches one — the window's views, then the main menu — because a *posted* command key never reaches a menu's key equivalent (measured: a posted ⌘R ran no Refresh) |
| `GITTER_DEBUG_TYPE=text` | then type that text into whatever has focus |
| `GITTER_DEBUG_DUMP_RESPONDER=1` | print the first-responder chain, the window geometry and whether the window is key to stderr, after every click and key; a count instead of `1` repeats the final dump that many times, 200 ms apart, which is how you tell "never focused" from "focused, then lost it" |
| `GITTER_DEBUG_BRANCH_ACTION=<step>[;<step>…]` | run branch actions and open their sheets (see below) — the sidebar's context menus are AppKit menus that in-process clicks cannot open |
| `GITTER_DEBUG_THEN=<step>[;<step>…]` | more branch steps, run **after** the clicks and keys — what a click on a toolbar button did: `idle;snapshot:after-click` |
| `GITTER_DEBUG_AUTOFETCH=<interval>[,<timeout>]` | run the automatic fetch every `<interval>` seconds instead of 10 minutes, stopping each one after `<timeout>` seconds (default 120) instead of 2 minutes — so a script sees several ticks. Every tick and every ending prints an `AUTOFETCH …` line, naming the store (`store 1`); `STORES built: <n>, registered: <m>` lines at launch and on every open event say how many stores were built and how many the window registry made — each window has one, so built and registered must be equal, and the line says so when a store was built outside the registry |
| `GITTER_DEBUG_QUIT_WAIT=<seconds>` | how long **Wait**, in the quit alert, waits for a write before calling the quit off with a banner, instead of 10 minutes — so a script can reach the bound with a slow scratch transport |
| `GITTER_LOG_DIR=<dir>` | write the diagnostics log (`gitter.log` and its rotations) there instead of `~/Library/Logs/Gitter`; read only in Debug. A scripted launch without it writes no log |
| `GITTER_DEBUG_SNAPSHOT_DIR=<dir>` | where a `snapshot:<name>` step writes `<name>.png`: the window and any sheet on it, drawn by the app itself — no Screen Recording needed, and it works for a window on a Space nobody is looking at |

The branch steps run in order, each waiting for the mutation the one before it started:

| step | effect |
|---|---|
| `switch:<branch>` / `track:<remote>/<branch>` / `detach:<rev>` | move HEAD, through the same guards the menus use |
| `create:<name>[:<start>]` / `createswitch:<name>[:<start>]` | create a branch, optionally switching to it |
| `rename:<old>:<new>` | rename a branch |
| `delete:<branch>` | **acts**: `git branch -d`; an unmerged branch opens the confirmation instead |
| `forcedelete:<branch>` | **acts**: `-d` first, then `-D` from the warning it opened — the two steps a user takes |
| `merge:<branch>:<ff\|noff\|squash>` | merge in that mode, remembering it once the merge really runs |
| `abort` | open the abort confirmation and answer it |
| `confirmleave` | answer the "leaving a detached HEAD" confirmation a previous step opened |
| `wait:<seconds>` | hold whatever is on screen (fractions allowed), so a terminal can change the repository *underneath* a confirmation — the only way to check what a stale sheet does. Clamped to 0…120 |
| `sheet:new` / `sheet:rename:<b>` / `sheet:merge:<b>` / `sheet:delete:<b>` / `sheet:abort` / `sheet:pull` / `sheet:stash` | open a sheet without acting — `sheet:delete` reads the warning's count and tip instead of letting `git branch -d` refuse, so it never deletes anything; `sheet:pull` opens the pull sheet from the tracking on screen, without fetching; `sheet:stash` opens Stash Changes… without answering it |
| `fetch[:<remote>]` | fetch one remote, or all |
| `pull` / `pull:merge` / `pull:rebase` | pull; the two with a mode also answer the pull sheet if one opened |
| `push` / `publish:<remote>` | push, or publish — `publish:` answers the publish sheet with that remote when there are several |
| `forcepush` / `confirmforcepush` | open the force push sheet (only possible after a rejected `push`), and answer it |
| `deleteremote:<remote>/<branch>` / `confirmdeleteremote` | open the delete-on-remote sheet, and answer it |
| `cancel` | stop what the network lane is running, and wait for it to say so |
| `start:<step>` / `idle` | run a step without waiting for its network lane, so the next steps run *during* it; `idle` then waits for the lane to free — a lane an automatic fetch holds does not count (below) |
| `stageall` / `commit:<subject>` | stage everything — during an operation, when files outside it would be added, it opens Stage All's question instead (`confirmstageall`) — and commit through the composer's own path |
| `snapshot:<name>` | draw the window into `GITTER_DEBUG_SNAPSHOT_DIR/<name>.png` |
| `panelsnapshot:<name>` | find the visible panel that is neither a sheet nor the app-modal alert — the About panel, after `menuitem:Gitter:About Gitter` — log its text fields and draw that panel's own window into `GITTER_DEBUG_SNAPSHOT_DIR/<name>.png` (`snapshot failed: … (no panel)` without one) |
| `open:<path>` | open that repository in this window as "Open Repository…" does — mid-script, e.g. while a push is running. The launch guard refuses every step after it unless the path is one `GITTER_DEBUG_ALSO_OPEN` names |
| `newwindow:<path>` / `inwindow:<n>` | open `<path>` in a window of its own, as Open Recent or a Finder open does (or bring the window already showing it to the front), wait for its first snapshot and list every registered store with `[target]` and `[key]` marks (and `(hidden)` or `(closed)`), then `NSApp.windows: <n>, on screen: <m>` — a window closed for real leaves that count; refused, and the app quits, unless `<path>` is one of `GITTER_DEBUG_ALSO_OPEN`'s. `inwindow:` makes the n-th store (1-based, in the order made) the **target**. Every step acts on the target — the first window's store until `inwindow:` — and its guard, wait and result line are the target's; so are `snapshot:`, `views` and the title lines, which draw and read the target's window. The menus act on the **front** window, and `menu:` says which |
| `closewindow` | close the target's window as a user does (`performClose`, what the close button, ⌘W and File › Close send) and log `closewindow: hidden \| closed \| <store> \| windows on screen: <n> of <m>`: `hidden` when its work keeps it (a write on its lane, a change running), `closed` otherwise. A hidden window's store is still the target, so `inwindow:`, `newwindow:` and the alert steps go on; after a real close the launch guard refuses the next step (`the window is closed`) and the app quits |
| `controls` / `press:<label>` / `tick:<label>[=on\|off]` / `fill:<label>=<text>` / `choose:<label>=<option>` | drive the target's sheet through its own controls: each sheet registers its buttons, toggles, fields and pickers by the label on screen (a field's or picker's without its colon) in a Debug-only registry, so a step runs exactly what the control does. `controls` logs `control: <kind> "<label>" = "<state>" [enabled\|disabled]` for each (a picker's with `[options: a\|b]`) in the order their views registered, `control: none (store N)` when there are none; the others split the label from the value at the first `=` (a `fill:` text may hold `=` and `:`, never `;`; a bare `tick:` is on). Each sleeps 300 ms (the time a sheet takes to re-register), then waits up to 5 seconds for exactly one enabled control of that kind and label — a sheet still appearing, a name still being checked — and logs `control: pressed "…"`, `ticked "…" on`, `filled "…" = "…"` or `chose "…" = "…"`, or `control refused: <kind> <why>` (not on screen, more than one, disabled, or a value it does not take; an option label two options share is ambiguous) and runs nothing. A control is the sheet's it was drawn in, so one still being dismissed cannot be pressed. Every sheet registers Cancel and its default or destructive button; Keep All, Keep None and each keep box and name (Prune, Remove Remote, Remove Worktree), Add Worktree's kind, branch, name and folder, Compare's branch lists, Stash's options, Clean Up Gone Branches' rows, and Add Remote, Edit URL and Rename Remote's fields are fully covered. A Choose… folder panel stays the panel's: fill the folder field instead. The `confirm…` steps and `prefill:` stay |
| `menu:<title>` | log every item of that main-menu menu — title, shortcut, enabled — as it would be when opened, then `front window: store N <repo>[, sheet up]` (the window the menus act on); a script cannot open a menu. The menus follow the front window, so when no Gitter window is key the step first brings the app to the front, as the click hooks do — a scripted launch with `menu:` or `menuitem:` comes to the front on your screen. As the **very first** step it can read stale state (seen: every item `enabled=false` before the first snapshot had loaded), so put `wait:1` before it |
| `views[:<class>]` | log the window's view tree with frames in click coordinates; a toolbar item is a `ToolbarItemHostingView`, above the content area (negative y) — the centre of its frame is where `GITTER_DEBUG_CLICK` aims |
| `badges` | log what each local branch's tracking badge draws, its tooltip and its VoiceOver text — the snapshot cannot draw the sidebar |
| `copyurls` | for every configured remote, take the items its sidebar menu offers ("Copy URL", "Copy Push URL"), copy each through the menu's own call onto a *private* pasteboard and log `copy <remote> "<title>": <raw address> -> <what was copied>` — how the credential redaction is checked. It prints the raw address, so point it only at scratch remotes |
| `autofetchfailed:<reason>` | set the failure the Fetch item's quiet mark stands for, without waiting for a real automatic fetch to fail |
| `menuitem:<menu>:<title>` | choose that main-menu item (`NSMenu.performActionForItem`) — how "Fetch Automatically" is toggled; `menu:<title>` a second later shows its tick as `state=on`. Like `menu:` it brings the app to the front first, and the item acts on the **front** window's store, while the step's wait and result line describe the target |
| `quit` | quit as ⌘Q does (`QuitFlow`, so with a sheet up the sheets are closed first and the quit then goes ahead), from the run loop, so the steps after it run while the quit is held: `start:push;wait:1;quit;wait:1;start:snapshot:alert;alert;alertbutton:Wait`. `QUIT …` lines say what was decided and when |
| `quitevent` | quit as the Dock, a logout or a shutdown does: send the quit Apple Event (`kCoreEventClass`/`kAEQuitApplication`) from a background thread, wait up to 30 s for the reply and log `quit event reply: <keyErrorNumber>` — −128 once the quit is called off, 0 when it goes ahead — or `quit event send failed: <error>`. The next step does not wait for the reply: `start:push;wait:1;quitevent;wait:1;alert;alertbutton:Don't Quit`. The event goes to the app's **own Apple Event Mach port** (`AEGetRegisteredMachPort()`), never to its pid or `kCurrentProcess`: sent that way it is handled on the sending thread, where AppKit answers −128 without asking anyone and Gitter's handler traps on `MainActor.assumeIsolated`; to the Mach port it arrives through the main run loop as the Dock's does (measured in a probe app) |
| `notice` | log both notice slots, the transient one and the sticky one: each one's text, links and button titles |
| `openlink` | press the sticky notice's **Open** through the store's own call, with an opener that only logs `openlink: <url>` — the harness never starts a browser |
| `stash:<msg>[:u]` / `stashpaths:<p,p>:<msg>` | **acts**: Stash Changes… with every change (`:u` ticks "Include untracked files"), or as if those files were selected with "Selected files" — the sheet, then its Stash. An empty `<msg>` is git's default (all changes) or the files' names (selected) |
| `stashes` | log the list: `stash@{n} <sha> <kind> branch: … untracked: … message: …` |
| `selectstash:<n>[:<path>]` | show the entry at position n in the detail pane, and that file's diff; logs its tracked and untracked files |
| `apply:<n>` / `pop:<n>` | **act**: the row menu's Apply / Pop on the entry at position n |
| `dropstash:<n>` / `confirmdropstash` | open Drop Stash… for the entry at position n, and answer it for the entry the sheet names |
| `noticepop` | press the sticky notice's **Pop Stash** through the store's own call; logs the entry it holds |
| `discard:<path>` / `discardstaged:<path>` / `discardall` | open the unstaged row's "Discard Changes…" (or "Move to Trash…" for an untracked path), the staged row's "Discard Staged and Unstaged Changes…", or the header's "Discard All…" — the sheet only |
| `discardhunk:<n>` | open the discard sheet for hunk n of the diff on screen: "Discard Hunk…", with `GITTER_DEBUG_SELECT_LINES` "Discard N Lines…", or "Discard File…" where that is what the hunk offers; logs the offer first |
| `confirmdiscard` | **acts**: the discard sheet's destructive button, for the model the sheet shows |
| `discardstale` | log whether the discard sheet on screen is out of date now — every read again, which its orange line runs when an `lstat` fingerprint of the files, the index and HEAD has moved |
| `undodiscard` | **acts**: the sticky notice's **Undo Discard**; logs each receipt (kind, paths, record, Trash URLs) |
| `stashcontinue[:merge\|:rebase]` | **acts**: the error banner's **Stash and Continue**, waiting for the stash and the retry; with a mode, then answers the pull sheet if the retry opened one. Logs `stashcontinue: not offered` when the banner offers nothing |
| `alert` / `alertbutton:<title>` / `alertsnapshot:<name>` | log every text and button (with its key equivalent) of each alert sheet on screen and of the app-modal alert if one is up (`app-modal …`: the quit question with no window to ask on, a hidden window's ending), and for the app-modal alert how it is presented (`state: app active: … \| panel key: … \| default button cell: …`) — the snapshot draws an alert's buttons but not its text — and click one of its buttons, the app-modal alert's first; `alertsnapshot:` draws the app-modal alert's own window, text included, into `GITTER_DEBUG_SNAPSHOT_DIR/<name>.png`. A hidden window's ending alert also logs its buttons as built (`alert built: …`) |
| `activate` | make Gitter the active app (`NSApp.activate()`), as a click on it would, and log whether it is and which window is key |
| `select:<path>` / `resolver` | select a working-copy file (a conflicted file's unstaged row, a resolved one's staged row) and wait for the resolver's read; `resolver` logs its state: kind, blocks or the whole-file reason, whether the file is what git wrote, the hash, the side names, the actions offered |
| `blocks:<path>:<O\|T\|B\|b\|.…>` | choose each block in turn — Ours, Theirs, Both (ours first), Both (theirs first), `.` none — and log the composed file and its SHA-256; writes nothing |
| `resolve` / `take:ours\|theirs:<path>` / `keep:<path>` / `deletefile:<path>` / `markresolved:<path>` | **act**: Resolve File, Take Ours / Theirs, Keep … Version, Delete the File (`delete:` is the branch step), Mark Resolved — each through the resolver's own entry point, which logs the offer first, so a refused one shows |
| `confirmreplace` / `confirmmarkers` | answer the "changed since the conflict" sheet and the leftover-markers sheet |
| `reopen:<path>` / `confirmreopen` | open Reopen Conflict… for a resolved file (logs `reopen: not offered` when it is not), and answer it |
| `noticeshow` / `cancelsheet` | press the sticky notice's **Show Copy**; close the sheet on screen as its Cancel does — `quit` closes a sheet itself now, so this is only for a script that wants the sheet gone before it goes on |
| `bar` | log the operation bar: its sentence, Continue's and Skip's state and reason, the stop as read, the halted or stale list, the draft and the composer's note |
| `message:<text>` | replace the composer's draft (`\n` for a line break) |
| `continue` / `confirmempty` / `confirmothers` | **acts**: the bar's Continue, which runs or opens the sheet the stop needs; answer the empty-result sheet and the other-staged-files sheet |
| `skip` / `confirmskip` | open Skip This Commit…, and answer it for the commit it names |
| `confirmstageall` | answer Stage All's question |
| `commitdraft` / `usemessage` / `keepmessage` | commit the draft as it is (a merge's or squash's prefill); the composer note's "Use <sha>'s Message" and "Keep This Message" |
| `selectcommits:<rev,…>` | select those commits as a set, as ⌘-clicks would — each `HEAD` or a prefix of exactly one listed commit (`select:` is the resolver's file step); logs the set, in the order shown, and the detail pane's "N commits selected" line |
| `historymenu` | log the commit menu's history items for the selection, and each branch's "Rebase … onto …", with the reasons the disabled ones show |
| `pick` / `revert` / `rebaseonto:<rev>` | Cherry-Pick / Revert N Commits… on the selection, or Rebase … onto… a full ref name (`refs/heads/x`), `HEAD` or a listed commit: the plan, then the sheet (every line it draws) or the refusal |
| `confirmhistory` / `confirmrebase` | **act**: the history or rebase sheet's button, with the plan it shows |
| `newtag:<name>:<rev>[:<msg>]` | New Tag… on that commit, the field's live verdict logged, then Create Tag — annotated with a message (`\n` for a line break), lightweight without; `newtag::<rev>` only opens the sheet |
| `deletetag:<n>` / `confirmdeletetag` | open Delete Tag… for that tag (it opens after a config read, and the step waits for it), and **act**: its Delete Tag |
| `restoretag[:<n>]` | **acts**: the sticky notice's Restore Tag(s), or with a name that deleted tag's row's Restore Tag |
| `pushtag:<n>:<r>` / `deleteremotetag:<n>:<r>` / `confirmdeleteremotetag` | **act**: Push Tag to <r>; Delete from <r>…'s read, then its sheet (the id it is leased on, or "no such tag"), and its button |
| `prune:<remote>` / `confirmprune[:none\|:<ref>=<name>,…]` | Prune <remote>…: the listing on the lane, then the sheet — every ref with its id, the stranded count and commits, the holders, the default keep boxes with their names and verdicts, `<remote>/HEAD`'s target — or the notice; and **act**: its Prune with the default boxes, none, or those (each ref in full). A box, Keep All and Keep None are `tick:`, `press:` steps now |
| `cleanup` / `confirmcleanup[:<b,…>]` | Clean Up Gone Branches…: the rows (detail, ticked, where checked out, the unmerged warning) or the notice; and **act**: its button with the default ticks or those names |
| `pushbranch:<b>` / `confirmpublish:<remote>` / `ffbranch:<b>` | **act**: Push / Publish… / Re-publish of a branch from its menu, the publish sheet's button with that remote, and Fast-Forward |
| `upstream:<b>` / `setupstream:<b>:<ref>` / `unsetupstream:<b>` | Set / Change Upstream…'s sheet and its choices; **act**: the sheet's button with that full ref, and Unset Upstream |
| `adminmenu` | log every local branch's and remote's housekeeping items as their menus build them, with the reasons the disabled ones show, each remote's sidebar badge and tooltip ("no URL"), and the menu bar's Remotes menu |
| `prefill:<key>=<value>` / `prefill:clear` | what the next remote sheet's fields start with (`name`, `url`, `fetch`, `push`, `own` = 0\|1) — kept for old scripts, since `fill:` now types into a sheet; `bannerAnchor=bottom` starts a scrolling banner at its end |
| `addremote` / `confirmaddremote:<name>=<url>[=nofetch]` | Add Remote…'s sheet; and **act**: its button, fetching the new remote after unless `nofetch` |
| `editurl:<remote>` / `confirmediturl[:<key>=<value>\|…]` | Edit URL…: the read, then the sheet — each configured URL as shown, the fields' starting text, the "git connects to" line, the several-URLs notes; and **act**: its Save with the fields as `prefill` keys say |
| `renameremote:<remote>` / `confirmrenameremote:<new>` | Rename…'s sheet; and **act**: its button |
| `removeremote:<remote>` / `confirmremoveremote[:<keep>]` | Remove…: the impact's read, then the sheet — every ref with its id, the stranded count, the keep defaults, each sentence about upstreams, push redirects and refs left behind; and **act**: its button, `<keep>` as for `confirmprune` |
| `split` | log the window's width, the sidebar's width and whether it is collapsed, the commit list's and the detail's panes, the divider between them and its autosave name: `split: window w=… \| sidebar shown x=… \| commit list x=a..b … \| detail x=… \| divider x=… \| autosave …`, in `views` coordinates |
| `togglesidebar` / `resize:<w>x<h>` / `divider:<x>` / `sidebarwidth:<x>` | hide or show the sidebar as its toolbar button does (which a click cannot reach once a narrow window puts it in the toolbar's overflow menu), resize the target's window as `GITTER_DEBUG_WINDOW` resizes the first one, or move the commit list / detail divider, or the sidebar's edge, to x as a drag does (`setPosition`, which the splits' minimums constrain); each then logs the `split` line |
| `filter:<text>` / `sidebar` | set the sidebar filter's text as typing would (`filter:` empties it), and log every section the sidebar draws after it — each remote group and whether it is expanded, "No matches", and the count VoiceOver hears |
| `worktrees` / `worktreemenu` / `pills` | log every worktree row (folder, branch line, marks and their tooltips, the changes read, this window's path and both titles — and the window number a window-scoped `screencapture -l` needs, since the snapshot cannot draw the sidebar); every worktree menu and every branch's held icon with Switch, Delete and Fast-Forward and their reasons; every "worktree:" pill |
| `openworktree:<folder>` | Open Worktree on that row, then the root and the titles. It is routed like any open: a window already showing that worktree comes to the front, otherwise this window switches. The launch guard refuses every step after it — another repository is open — and the app quits |
| `watchloads:<seconds>` | for that long, one line per finished snapshot load (HEAD, files, stashes, every branch's tip) — how a terminal's change in a linked worktree is checked against git |
| `reloadtiming` | a snapshot load, timed: when it landed, whether the worktree state was then still the one before, and when the worktree state's own read landed. Every step waits for a worktree read in flight before it runs |
| `comparewith:<full ref>` / `compare:<a>:<b>` | "Compare with "<current>"" on that branch, or a comparison of two full refs; then `comparestate`: the bar and its buttons, the moved line, the changes row, each group with its count and listed ids, the header, the selection, the files |
| `comparesheet` / `comparefilter:<text>` / `confirmcompare:<a>:<b>` | Compare Branches…'s presets and options, the options a filter leaves, and its Compare with those refs |
| `compareselect:<id\|changes>` / `comparepath:<path>` / `compareswap` / `comparerefresh` / `comparedone` / `comparemenu` / `comparecopy:<id>` | click a commit or the changes row, a file of the changes; Swap, Refresh, Done; log every branch's compare items with their reasons; Copy Commit ID onto a private pasteboard, read back |
| `sidebarclick:<branch>` / `reload` | a sidebar branch row's click (which ends compare mode); a snapshot load, as the watcher would start one |
| `loadolder` / `reveal:<branch\|tag\|id>` | one page more of History (what the end row scrolling in does), waited and timed; a sidebar click on that commit, waited until the table has scrolled to it or a notice ended the reveal, with whether it was selected at once and the times. Both log the history line, `depth=<n> complete=<bool>` with the end row's state, which `comparestate` logs too with no comparison |
| `addworktree[:<b>]` / `folderproblem:<path>` / `confirmaddworktree:existing:<b>:<path>` (or `new:<name>:<start>:<path>`, `tracking:<name>:<remote ref>:<path>`) | Add Worktree… and what it offers; the folder field's live check for that text; and **acts**: its Add with that choice — the sheet's own controls are `press:`, `tick:`, `fill:` and `choose:` — then the notice or banner and the worktree list |
| `removeworktree:<folder>` / `removeworktreestart:<folder>` / `removeallmissing` / `worktreesheet` / `confirmremoveworktree[:none\|:<name>]` | Remove Worktree… (after the check, or at once so the progress state can be shot), Remove All Missing…, the sheet's every line; and **acts**: its button with the keep boxes as they start, none, or the one kept as `<name>` |
| `noticeopen` | the sticky notice's **Open** after an add (routed like Open Worktree); the launch guard then refuses the rest, and the app quits |
| `tags` | log every tag row as the sidebar draws it (icon, tooltip, VoiceOver), its menu with the reasons, the deleted tags' rows, and each commit's pills beside `%D` — the snapshot cannot draw the sidebar |

A step that starts network work waits for the lane to free as well, for up to 120 seconds, and a wait that runs out logs `BRANCH_ACTION wait timed out after <s>s: <what>`; a
step taken while the lane is already busy waits only for the mutation slot, so a second
network action is refused and logged at once. After each step a second line reports the lane
(its kind, remote and progress line), whether the banner offers Force Push and Stash and
Continue (with the stash's message, `-u` and the reason it is off), the three blocked reasons, the push button's title, the
tracking, the counts the Push and Pull buttons draw (`pushCount`, `pullCount`), the Push
tooltip, the remembered pull mode, how many snapshot loads have run, whether "Fetch
Automatically" is on and the last automatic fetch's failure. An automatic fetch on the lane
does not count as busy for this: the user's actions stop it and go ahead. Nor does a step wait it out: the default wait is for no blocking network activity and no write running, so `idle` and a `snapshot:` taken during an automatic fetch return at once (they used to wait for it to end); `start:snapshot:<name>` still shoots a running push or fetch. `quit` with a sheet on screen quits: AppKit does not ask the app whether it may quit while a window has a sheet attached (seen with the new-branch sheet and the delete-on-remote sheet alike), so `QuitFlow` closes every window's sheet and waits until AppKit shows none (0.27–0.29 s measured), then terminates. A refused launch or step quits the same way. If a write is running the quit is held and asked about. A click on the
toolbar's Stop that the double-click guard drops logs `stop click ignored`.

A slow transport, for cancelling and for working during a fetch, is configuration in the
scratch repository and not a hook: point `remote.<name>.uploadpack` (fetch) or
`remote.<name>.receivepack` (push) at a script that sleeps and then `exec`s
`git-upload-pack "$@"` / `git-receive-pack "$@"` — the same fixture GitCore's cancellation
tests use. Only ever against local bare repositories.

The clicks and keys in `GITTER_DEBUG_CLICK`/`KEYS`/`TYPE` run **once, after the last
step**, so a `wait:` step is what puts a click on a sheet that has gone out of date.

After every step one line goes to stderr, which is what a shell asserts on. `head` and
`selection` ride along because neither can be read out of git, and "the selection returns to
the working copy" is part of what these actions promise:

```
BRANCH_ACTION result: <sheet or nil> | notice: <…> | error: <…> | head: <…> | selection: <…>
```

The click and key variables wait for the window to actually become key first, and activate
the app, because an inactive window draws its selection in the unemphasized grey whatever
has focus. Start the binary itself, from `bash`, so that it inherits exactly the script's
environment — `open -a` passes only the `--env` variables it is given, none of a script's network
guards — with the fixture named, inside the script's own scratch directory:

```sh
unset SSH_AUTH_SOCK
GIT_ALLOW_PROTOCOL=file GIT_SSH_COMMAND=/usr/bin/false GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_NOSYSTEM=1 GITTER_DEBUG_OPEN="${fixture:?}" GITTER_DEBUG_CLICK=684,170 \
  GITTER_DEBUG_DUMP_RESPONDER=1 GITTER_LOG_DIR="${scratch:?}/logs" \
  .build/DerivedData/Build/Products/Debug/Gitter.app/Contents/MacOS/Gitter 2> harness.log
```

## Status / roadmap

Stages files, hunks and lines; commits, amends and commits all tracked changes; creates,
switches, merges, renames and deletes branches, checks out remote branches and tags, and
aborts an operation or undoes a pending squash; fetches, pulls (merge or rebase) and pushes
the current branch, publishes and re-publishes it, force-pushes behind a lease and a
confirmation, deletes a branch on a remote, and keeps ahead/behind current with a quiet
automatic fetch.

Stashes (all changes or selected files, with or without untracked files), applies, pops and
drops them behind a confirmation; discards files, hunks and lines on either side and untracked
files into the Trash, every discard recorded first and undoable; offers Stash and Continue
when a switch, merge or pull is refused over local changes; and keeps a pushed branch's
pull-request link on screen until it is used.

Resolves conflicts in the app (milestone A2) — block by block, by whole file, or in your editor
and then Mark Resolved, with Reopen Conflict… while the operation lasts — and continues a
stopped rebase, cherry-pick or revert with the stopped commit's message, skips a commit with
its changes recorded first, and commits a merge or squash with git's prepared message.

Cherry-picks and reverts one or several selected commits as one git sequence and rebases the
current branch onto a commit or a branch (milestone B1), each behind a sheet the run checks
again; creates, deletes (with Restore Tag), pushes and remotely deletes tags, one at a time.

Keeps the remotes tidy (milestone B2): prunes a remote behind a sheet that names every ref with
its id and keeps a branch at the commits only they hold, cleans up branches whose upstream is
gone, pushes and fast-forwards a branch that is not checked out, sets, changes and unsets an
upstream, and adds, renames, re-points and removes remotes — a half-done rename or removal read
back and worded with how to finish.

Finds its way around (milestone B3): filters the sidebar's branches and tags as you type,
compares two branches — the commits only on each side and the changes one brings, from ids read
once — and lists, opens, adds and removes worktrees, a removal only behind Gitter's own check of
what git would delete, made again before git runs.

Shows the whole history (milestone H1): older commits load 500 at a time as you scroll, to the
first commit and a "Start of history" row, every refresh keeps the depth, and a sidebar click on
an old branch or tag loads down to it, selects it and scrolls to it — up to 50,000 commits back.
Reading the log is faster at every depth: a refresh of the newest 500 on a 100,000-commit
repository went from 0.32 s to 0.26 s.

Its tests are green on their first run (milestone E1): the GitCore gate is capped and the tests
pass uncapped too, no test has a wall-clock upper bound that load can exceed, a test signals only
processes it started, and the app's tests never touch your real defaults. A Stop ends a helper
of git's that ignores SIGTERM even when git itself has already exited, and a git killed by a
signal is reported as killed, never as an exit code (the corners left are the "Own the
reap" gap).

Works in several windows and quits with a sheet up (milestone E2): File › New Window opens a
second, independent repository window, each with its own sheets, lane and automatic fetch;
every open is routed to a window and a repository is never open twice; the open windows come
back at the next launch; and ⌘Q, the Dock's Quit and a logout close every sheet and quit, asking
first when a write is running in any window. The debug harness drives the controls inside
sheets and a second window, and the app's own tests run its store flows on isolated real git.

Answers a logout honestly and keeps a closed window's work (milestone E3): the quit Apple Event's
reply waits for Gitter's decision, so a logout learns that Don't Quit called it off; a window
closed while it is still writing or changing hides until its work ends, comes back when its
repository is opened again, and says with an alert if the work ended with something to read. The
app's tests gained a test backend over real git that can hold, fail or replace any one call, and
both test targets share one support library; requests that would start a change are refused while
one runs, A2's largest files are split, and GitCore reads a spaced `GIT_CONFIG_COUNT` as git
does, sees an operation in a worktree whose main checkout's path holds a newline, and no longer
lets a symbolic ref hide the commits a delete would strand.

Can be installed on other Macs, and keeps a log you can carry back: one script,
`scripts/package.sh`, turns a clean tree into an arm64 DMG signed with a Developer ID and notarized, or
with your own self-signed certificate (so macOS's folder grants survive an update), stamped with the build number and the
commit that About Gitter shows, and checked before it is wrapped; and every git call and every
message Gitter showed goes to a rotating `~/Library/Logs/Gitter/gitter.log`, with a URL's credentials
removed (the few exceptions are in `docs/INSTALL.md` §5), which Help › Show Logs opens.
[`docs/INSTALL.md`](INSTALL.md) covers installing, updating, the log and building your own DMG.
