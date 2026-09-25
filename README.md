# Gitter

Gitter is a simpler native Git client for macOS — an alternative to Tower and GitKraken
without the feature bloat. It opens a repo, browses branches and the commit graph, and
shows diffs, all live-refreshed as the working copy changes. It stages files, hunks and
even single lines, and commits — including amend and "commit all tracked" — from those
diffs. It now also creates, switches, merges, renames and deletes branches, checks out
remote branches and tags, and ends an operation the repository is stuck part-way through.
There is still no discard and no push/pull/fetch; those are next.

![Gitter's main window: the branch button, the sidebar, the lane graph and a diff](docs/screenshots/branches.png)

## What it can do

- Browse commit history with a lane graph (gitk-style)
- View diffs of a commit, or of the working copy, with wrapping long lines
- Stage and unstage whole files, individual hunks, or a hand-picked set of lines
- Commit, amend the last commit, or commit every tracked change in one step
- Create, switch, rename and delete local branches; check out a remote branch as a local
  tracking branch; check out a commit or a tag (detached HEAD)
- Merge, choosing each time between fast-forward if possible, always a merge commit, and
  squash — the last choice is remembered
- Finish a conflicted merge from the app (resolve in your editor, stage, "Commit Merge"),
  or end it: abort a merge, cherry-pick, revert, rebase or `git am`, and undo a pending
  squash
- Hooks and commit signing apply as configured, because every commit runs through
  your own `git`, not a reimplementation of it

![Line-level staging, in dark mode, with a long line wrapped](docs/screenshots/main.png)

## Safety

Gitter's own code never writes working-tree files — staging and unstaging change only the
index (`git apply --cached`, `git add`, `git reset`) and committing writes only to the
repository. Branch operations do change the working tree, since that is what a checkout
is, so the promise is restated rather than dropped:

> **Gitter never discards uncommitted work or commits without a confirmation that names
> what will be lost.**

Switch, detach, track and merge run plain git with **no force flag anywhere in the code**
(`--force`, `-f`, `--discard-changes`, `-B`, `-C`, `--merge` on switch are forbidden, and
a test greps the sources for them on every run). When git refuses, nothing has changed,
and Gitter shows the files git named rather than a wall of stderr.

Four actions can lose something without being asked for by name, and each is behind a
confirmation that says what goes and what stays:

| action | how it is confirmed |
|---|---|
| Abort a merge, cherry-pick, revert, rebase or `git am` | a sheet with that operation's own kept/lost wording — a rebase abort also takes unstaged edits, `am --abort` rewinds the branch past the patches it committed — and **the exact list of files** it is about to put back, read live |
| Undo a pending squash | the same sheet: everything staged goes, including work staged before the squash if the squash was started outside Gitter, which is why the file list is not optional |
| Force-delete an unmerged branch | `git branch -d` runs first and either deletes or refuses *without changing anything*; only its refusal opens a warning naming the unique-commit count and the tip sha, and "Delete Anyway" is refused unless the branch still points at exactly that tip |
| Leave a detached HEAD holding commits on no branch, tag or remote | a warning naming the count and the full sha, with "Create Branch Here…" as the safe answer; leaving anyway prints the command that brings the commits back |

Amending is the fifth, and the one with no confirmation sheet: it rewrites HEAD and leaves
the commit it replaces reachable from no branch, tag or remote. What stands in for the sheet
is that nothing else asks for it — you tick the Amend toggle yourself and the commit button
then reads "Amend Commit" — plus a warning when the branch tracks an upstream and has
nothing ahead of it, which is exactly when the commit being rewritten has already been
pushed. And the replaced commit is still in the reflog, as `HEAD@{1}`.

Amending is unavailable while any of those operations is in progress, and that is not
belt-and-braces: git refuses `git commit --amend` during a merge and a cherry-pick and
**accepts** it during a revert, a rebase, a `git am` and a pending squash (measured on git
2.54). Each of those four rewrites the commit the operation was standing on, leaving it
reachable from no branch, tag or remote, with nothing on screen to say so — the same kind of
loss the table above confirms, and one nobody would have been asked about. So Gitter refuses
all six itself, before git runs, and the Amend toggle says which operation is in the way.

The staging claim is verified by tests that read **every byte of every worktree file** before
and after each staging operation and require them to be identical (`worktreeSnapshot` keeps
the file contents, not a digest, so a failure can print what changed); every branch refusal is
tested the same way, with the index, HEAD and every ref compared as well.

## Design decisions

| Area | Decision | Rationale |
|---|---|---|
| UI | SwiftUI, AppKit where SwiftUI falls short | Most Mac-native result |
| Git access | `/usr/bin/git` via `Process`, behind a `GitBackend` protocol | SSH agent, credential helpers, signing and hooks work for free. libgit2 can be added behind the same protocol for hot read paths |
| Deployment | macOS 26.0 minimum, macOS 27 SDK | Dev machine runs 27 |
| Project | xcodegen `project.yml` -> `Gitter.xcodeproj`; `GitCore` local SwiftPM package | Xcode workflow for the app; `swift test` for the core |
| Staging | Patches built in-process (`PatchBuilder`) and applied with `git apply --cached`, never a hand-rolled index writer | The same command a user would run themselves; hunk- and line-level staging fall out of the same code path as whole-file staging |
| Dirty switch | git's default — carry non-conflicting changes, refuse otherwise. No stash, no force | A refusal that changes nothing is a better answer than a stash the user did not ask for |
| Delete | `git branch -d` first, then `-D` only from the warning its refusal opened, and only if the tip is still the one that warning named | `-d` is git's own authority on "is this merged", and it changes nothing when it refuses |
| Scope | Repo browsing, diffs, staging, commit and branch operations are done. Discard and remotes are not built yet | Ship the commit loop before touching anything that mutates the working tree |

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

## Tests

```sh
cd GitCore && swift test
```

403 tests in 36 suites. Most of them run real `git` against a temporary repository rather
than a fake, including one that greps `GitCore`'s own sources for forbidden force flags.

The run also reports **4 known issues, and they are meant to be there** — please do not
"fix" them. They are the two negative controls in `WorktreeAssertions.swift`, which change a
file and then pass an empty baseline to `assertWorktreeUnchanged` inside `withKnownIssue`,
recording two failures each. That is what proves the helper *can* fail. Every "nothing was
touched" claim in this suite rests on that one function, and a bug once made it silently
vacuous (it compared resolved symlink paths, so every snapshot came back empty and every
assertion passed). Deleting these two tests would take the proof away and the suite would go
on looking green.

## Project layout

Every `.swift` file in the two product targets — 69 of them, which is what `find
GitCore/Sources Gitter -name '*.swift' | wc -l` prints — with the ones inside `Models/`,
`Parsers/` and `Views/` named in prose rather than one per line. The 43 test files and
`GitCore/Package.swift` are summarised rather than listed, which is also why the check is
that command and not a bare `find . -name '*.swift'`: that one reaches them too, and the
generated sources under `.build` as well.

```
GitCore/                  SwiftPM package, no SwiftUI dependency
  Sources/GitCore/
    GitBackend.swift            Read-only protocol: snapshot, log, refs, diffs
    GitWorkingCopyBackend.swift Staging/commit/amend protocol and its contract
    GitBranchBackend.swift      Branch/merge/abort protocol and its contract
    GitError.swift              commandFailed, launchFailed, and the two pre-flight refusals
    BranchOperationTypes.swift  MergeMode, MergeOutcome, BranchDeletion, the typed refusals
    CLIGitBackend.swift         The implementation over /usr/bin/git, plus
      +WorkingCopy.swift          staging, commit, amend (and the amend-mid-operation refusal)
      +Branches.swift             create, switch, detach, track, rename
      +BranchDelete.swift         `branch -d`, and `-D` only against an expected tip
      +Merge.swift                the three merge modes and the name/tag comparison
      +Abort.swift                the five `--abort`s and `reset --merge`
      +Operation.swift            which of the six operations is part-way through
    ProcessRunner.swift         Process spawning with LC_ALL=C and captured stderr
    GraphLayout.swift           gitk-style commit lane assignment
    PatchBuilder.swift          Builds a hunk- or line-level patch from a parsed diff, with
      +Markers.swift / +Paths.swift
    Models/                     RepoSnapshot, Commit, FileStatus, Diff, Branch, Graph
    Parsers/                    Status, Log, Ref, Diff (+Paths) and BranchRefusal parsers
  Tests/GitCoreTests/           36 suites; ForceFlagScanner(+Lexing) is the force-flag grep

Gitter/                   macOS app (SwiftUI)
  GitterApp.swift            App entry point, commands, Open Recent
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
  RemoteActivity.swift       What the lane is running, a refused push, the progress relay
  RemoteWording.swift        Every sentence about the network, and making server text plain
  BranchSheet.swift          Which confirmation or form the store wants on screen
  CommitDraft.swift          The commit message + amend toggle being edited
  RepositoryWatcher.swift    FSEvents-based debounced refresh trigger
  OperationWording.swift     Every sentence the UI says about an operation in progress,
                              including the abort confirmation's five wordings
  DebugLaunchHooks.swift     Debug-only launch hooks for screenshot verification (see below),
    +Events.swift              posted clicks, keys and the responder dump
    +Branches.swift            the `GITTER_DEBUG_BRANCH_ACTION` step list
  Views/                     MainWindow, SidebarView, SidebarMenus, CommitListView,
                              CommitGraphCell, DetailView, WorkingCopyFileList,
                              CommitComposerView, DiffView, DiffHunkView, DiffLineSelection,
                              Banners, BranchToolbar, BranchNameValidator, BranchSheetHost
                              and the six sheets (NewBranch, Rename, Merge, DeleteBranch,
                              Abort, LeaveDetached)
```

## Debug launch hooks

`Gitter/DebugLaunchHooks.swift`, `DebugLaunchHooks+Events.swift` and
`DebugLaunchHooks+Branches.swift` exist only in Debug builds (`#if DEBUG`, compiled out of
Release) and drive the UI from environment variables, read once at startup. They exist because the verification environment has Screen Recording
but not Accessibility, so nothing outside the process can click — without these, a diff can
never be put on screen from a script, and a focus bug can never be reproduced.

| variable | effect |
|---|---|
| `GITTER_DEBUG_SELECT_PATH=<path>` | select that file in the working copy |
| `GITTER_DEBUG_STAGED=1` | select it on the staged side instead |
| `GITTER_DEBUG_SELECT_COMMIT=<rev>` | select a commit (`HEAD` = the newest) and, with no `SELECT_PATH`, its first file |
| `GITTER_DEBUG_SELECT_LINES=3,4` | pre-select those line ids in the first hunk |
| `GITTER_DEBUG_APPLY=hunk:0` or `lines` | then stage/unstage that hunk, or those lines |
| `GITTER_DEBUG_WINDOW=1400x1400` | resize the window, past the screen if asked |
| `GITTER_DEBUG_OPEN=<path>` | after the first repository has loaded, open that path as "Open Repository…" would — the only way to reach a failed open from a script |
| `GITTER_DEBUG_APPEARANCE=light\|dark` | force the app's appearance, so a screenshot pass can shoot both without changing the machine's setting |
| `GITTER_DEBUG_CLICK=x,y[:2\|:shift\|:right][;…]` | click those points, in points from the top-left of the *frontmost* window's content area — the sheet's own, while one is up; `:2` double-clicks, `:shift` shift-clicks, a `type=text` step types between two clicks, and `:right` posts a right-click, which is kept as a recorded negative result: it does not open a SwiftUI `.contextMenu` |
| `GITTER_DEBUG_KEYS=space,return,cmd+return` | then press those keys (`space`, `return`, `tab`, `escape`, `up`, `down`, with `cmd+`/`shift+`/`opt+`/`ctrl+`) |
| `GITTER_DEBUG_TYPE=text` | then type that text into whatever has focus |
| `GITTER_DEBUG_DUMP_RESPONDER=1` | print the first-responder chain, the window geometry and whether the window is key to stderr, after every click and key; a count instead of `1` repeats the final dump that many times, 200 ms apart, which is how you tell "never focused" from "focused, then lost it" |
| `GITTER_DEBUG_BRANCH_ACTION=<step>[;<step>…]` | run branch actions and open their sheets (see below) — the sidebar's context menus are AppKit menus that in-process clicks cannot open |
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
| `wait:<seconds>` | hold whatever is on screen, so a terminal can change the repository *underneath* a confirmation — the only way to check what a stale sheet does. Clamped to 0…120 |
| `sheet:new` / `sheet:rename:<b>` / `sheet:merge:<b>` / `sheet:delete:<b>` / `sheet:abort` / `sheet:pull` | open a sheet without acting — `sheet:delete` reads the warning's count and tip instead of letting `git branch -d` refuse, so it never deletes anything; `sheet:pull` opens the pull sheet from the tracking on screen, without fetching |
| `fetch[:<remote>]` | fetch one remote, or all |
| `pull` / `pull:merge` / `pull:rebase` | pull; the two with a mode also answer the pull sheet if one opened |
| `push` / `publish:<remote>` | push, or publish — `publish:` answers the publish sheet with that remote when there are several |
| `forcepush` / `confirmforcepush` | open the force push sheet (only possible after a rejected `push`), and answer it |
| `deleteremote:<remote>/<branch>` / `confirmdeleteremote` | open the delete-on-remote sheet, and answer it |
| `cancel` | stop what the network lane is running, and wait for it to say so |
| `start:<step>` / `idle` | run a step without waiting for its network lane, so the next steps run *during* it; `idle` then waits for the lane to free |
| `stageall` / `commit:<subject>` | stage everything, and commit through the composer's own path |
| `snapshot:<name>` | draw the window into `GITTER_DEBUG_SNAPSHOT_DIR/<name>.png` |
| `open:<path>` | open that repository as "Open Repository…" does — mid-script, e.g. while a push is running |

A step that starts network work waits for the lane to free as well, for up to 120 seconds; a
step taken while the lane is already busy waits only for the mutation slot, so a second
network action is refused and logged at once. After each step a second line reports the lane
(its kind, remote and progress line), the three blocked reasons, the push button's title, the
tracking, the remembered pull mode, and how many snapshot loads have run.

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
has focus. Launch through `open` to see stderr and to get a properly frontmost app:

```sh
open -n -F --stderr /tmp/gitter.log --env GITTER_DEBUG_CLICK=684,170 \
  --env GITTER_DEBUG_DUMP_RESPONDER=1 -a .build/DerivedData/Build/Products/Debug/Gitter.app
```

## Status / roadmap

Stages files, hunks and lines; commits, amends and commits all tracked changes; creates,
switches, merges, renames and deletes branches, checks out remote branches and tags, and
aborts an operation or undoes a pending squash. Next up: push, pull and fetch. Later:
stash, discard, and conflict resolution inside the app (today you resolve in your editor
and Gitter stages and commits the result). Everything wanted and deliberately deferred is
kept in [`docs/BACKLOG.md`](docs/BACKLOG.md), with what is already known about each item.
