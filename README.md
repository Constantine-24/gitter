# Gitter

Gitter is a simpler native Git client for macOS — an alternative to Tower and GitKraken
without the feature bloat. It opens a repo, browses branches and the commit graph, and
shows diffs, all live-refreshed as the working copy changes. It stages files, hunks and
even single lines, and commits — including amend and "commit all tracked" — from those
diffs. It creates, switches, merges, renames and deletes branches, checks out remote
branches and tags, and ends an operation the repository is stuck part-way through. And it
now talks to remotes: fetch, pull and push the current branch, publish a branch, show how
far each branch is ahead of and behind its upstream, and keep that picture current with a
quiet fetch in the background. There is still no discard and no stash; those are next.

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
- Fetch, Pull and Push from the toolbar (Repository menu: ⇧⌘F, ⇧⌘L, ⇧⌘P). The running one
  shows a spinner, git's own progress line and a Stop button (⌘.); browsing is never
  blocked, and a fetch does not block staging or committing either
- Pull fast-forwards when it can and says so in a notice (`Fast-forwarded to
  "origin/main".`); when both sides have moved on it asks, Merge or Rebase, with the counts —
  the last answer is remembered
- Publish a branch that has no upstream (`push -u`), choosing the remote when there is more
  than one (`origin` preselected); Re-publish one whose upstream was deleted on the server
- When the server refuses a push because it has commits you don't, the banner offers
  **Pull** and **Force Push…**; the force push is leased on the exact sha it showed you
- Delete a branch on a remote from the sidebar ("Delete on "origin"…"), with a warning that
  says whether its commits are held anywhere else
- Ahead/behind badges on the branch button and the sidebar's branches: `↑2 ↓3`, "gone" when
  the upstream was deleted, and `↑1 · main` when the upstream is a local branch; the Pull and
  Push buttons carry the same counts
- Copy a remote's URL from its sidebar menu, with any password or token taken out
- Fetch quietly in the background: when a repository opens and every 10 minutes after,
  unless **Repository ▸ Fetch Automatically** is unticked (on by default). It never shows a
  banner — a failure is only a small mark on the Fetch button, with the reason in its
  tooltip — and it never stands in your way: Fetch, Pull and Push stay available while it
  runs, and using one stops it (yours starts once the stopped fetch's git has gone — at once
  for a transport that honours the stop, about 2 s for one that ignores it)
- Quit safely while the network is busy: a fetch or pull is stopped and Gitter quits; a push
  (or publish, force push, delete on a remote) asks first — **Wait** lets it finish and then
  quits (or stays open if it failed or has a warning, so you can read it, or if it is still
  running after ten minutes), **Stop and Quit**, or **Don't Quit**

![The remote toolbar: Fetch, "Pull ↓2" and "Push ↑2", with "main ↑2 ↓2" on the branch button](docs/screenshots/remotes.png)

![Line-level staging, in dark mode, with a long line wrapped](docs/screenshots/main.png)

## Safety

Gitter's own code never writes working-tree files — staging and unstaging change only the
index (`git apply --cached`, `git add`, `git reset`) and committing writes only to the
repository. Branch operations do change the working tree, since that is what a checkout
is, and remote operations change another machine, so the promise is restated rather than
dropped — in the design's words:

> **Gitter never discards uncommitted work or commits without a confirmation that names
> what will be lost** — from this milestone, on the remote as well.

Switch, detach, track and merge run plain git with **no force flag anywhere in the code**
(`--force`, `-f`, `--discard-changes`, `-B`, `-C`, `--merge` on switch are forbidden, and
a test greps the sources for them on every run). When git refuses, nothing has changed,
and Gitter shows the files git named rather than a wall of stderr. The same test forbids,
for the network: a bare `--force-with-lease`, any refspec beginning with `+`, `--mirror`,
`--prune`, `--all` on push, `--tags` and `--follow-tags`, `--delete`/`-d` on push,
`--no-verify`, `--autostash`, `--update-refs` on rebase, and the `pull` subcommand itself
(Gitter fetches and then merges or rebases as two steps it controls).

Six actions can lose something without being asked for by name, and each is behind a
confirmation that says what goes and what stays:

| action | how it is confirmed |
|---|---|
| Abort a merge, cherry-pick, revert, rebase or `git am` | a sheet with that operation's own kept/lost wording — a rebase abort also takes unstaged edits, `am --abort` rewinds the branch past the patches it committed — and **the exact list of files** it is about to put back, read live |
| Undo a pending squash | the same sheet: everything staged goes, including work staged before the squash if the squash was started outside Gitter, which is why the file list is not optional |
| Force-delete an unmerged branch | `git branch -d` runs first and either deletes or refuses *without changing anything*; only its refusal opens a warning naming the unique-commit count and the tip sha, and "Delete Anyway" is refused unless the branch still points at exactly that tip |
| Leave a detached HEAD holding commits on no branch, tag or remote | a warning naming the count and the full sha, with "Create Branch Here…" as the safe answer; leaving anyway prints the command that brings the commits back |
| **Force push** — only ever offered from a push the server refused because it has commits you don't | Gitter fetches, then a sheet names the remote and branch, shows **both shas in full** — the remote tip that will be replaced and your local tip that will be pushed — and lists the commits that will leave the server's branch, with their authors. On "Force Push" it re-reads your branch and refuses if it has moved since the warning; the push then carries `--force-with-lease=<remote ref>:<the remote sha shown>` and sends `<the local sha shown>:<remote ref>`, so what the server loses and what it gets are exactly what the sheet showed. If the server's branch moved meanwhile, git itself refuses (`stale info`) and nothing on the server changes |
| **Delete a branch on a remote** (sidebar ▸ remote branch ▸ "Delete on "origin"…") | Gitter fetches that remote, then a sheet names the branch, the remote and its tip in full, and says whether its commits are **held by no branch, tag or other remote Gitter can see** (and how many). The deletion is leased on that tip (`--force-with-lease=refs/heads/<b>:<tip>` with `:refs/heads/<b>`), so a branch that moved, or is already gone, is refused by the server and nothing is deleted. The notice afterwards prints the `git push <remote> <tip>:refs/heads/<b>` that recreates it |

In both sheets Cancel holds Return and the destructive button has no shortcut. The sha is
spelled out rather than left to git on purpose: a bare `--force-with-lease` leases against
the remote-tracking ref, which Gitter's own automatic fetch rewrites — measured, in the
situation where the explicit lease answers `stale info`, the bare one force-pushed and took
a colleague's newest commit off the branch.

Pull with **Rebase** rewrites your local commits, and it is asked for by name: the pull
sheet says how many commits it rewrites, that it needs a clean working copy, and that a
merge commit among them is flattened rather than kept. It is never a default you did not
choose; the old tip stays in `ORIG_HEAD` and the reflog. A rebase that stops on a conflict
lands in the existing rebase note, whose Abort puts everything back.

Amending is the seventh, and the one with no confirmation sheet: it rewrites HEAD and leaves
the commit it replaces reachable from no branch, tag or remote. What stands in for the sheet
is that nothing else asks for it — you tick the Amend toggle yourself and the commit button
then reads "Amend Commit" — plus a warning, "Amending rewrites history that has already been
pushed.", when the branch tracks an upstream and has nothing ahead of it, which is exactly
when the commit being rewritten has already been pushed. And the replaced commit is still in
the reflog, as `HEAD@{1}`.

Amending is unavailable while any of those operations is in progress, and that is not
belt-and-braces: git refuses `git commit --amend` during a merge and a cherry-pick and
**accepts** it during a revert, a rebase, a `git am` and a pending squash (measured on git
2.54). Each of those four rewrites the commit the operation was standing on, leaving it
reachable from no branch, tag or remote, with nothing on screen to say so — the same kind of
loss the table above confirms, and one nobody would have been asked about. So Gitter refuses
all six itself, before git runs, and the Amend toggle says which operation is in the way.

A network write that is stopped or fails is **never reported as "nothing changed"**: a
stopped push says the remote "may or may not have been updated" and fetches to find out.
A stopped or failed fetch leaves the repository intact (no `*.lock`, `git fsck` clean).

The staging claim is verified by tests that read **every byte of every worktree file** before
and after each staging operation and require them to be identical (`worktreeSnapshot` keeps
the file contents, not a digest, so a failure can print what changed); every branch refusal is
tested the same way, with the index, HEAD and every ref compared as well, and every remote
refusal also compares every ref of the bare "server" repository.

### Credentials: whatever git already has

Gitter never sees, asks for or stores a secret. Every fetch, pull and push is your own
`git`, so your credential helper (the macOS Keychain helper included), your ssh-agent, your
`~/.ssh/config` and macOS ssh's Keychain passphrases (`UseKeychain`) all apply as they do in
a terminal. git is run with `GIT_TERMINAL_PROMPT=0`, so when it would have had to ask for
something it fails at once, and Gitter says what to do **once, in a terminal**:

- HTTPS with no stored login — "<url> needs a login that git doesn't have. Run git fetch once
  in a terminal to sign in; Gitter will use it afterwards." Run `git fetch` in that
  repository, sign in when git asks, and the credential helper remembers it.
- A key the server refused, or one git could not unlock — "<url> refused the login git
  offered. Run git fetch in a terminal to sign in again."
- An unknown ssh host key — "The server's host key isn't trusted yet. Connect once from a
  terminal (git fetch) to check its fingerprint and accept it."

**A passphrase-protected ssh key.** When the environment sets neither `SSH_ASKPASS` nor
`SSH_ASKPASS_REQUIRE`, Gitter starts its network git with `SSH_ASKPASS_REQUIRE=force`. A Mac
has no askpass program, so ssh can never ask for a passphrase or a host key — it fails in
about 50 ms with the real cause, however Gitter was launched. Before this, a Gitter launched
**from a terminal** had ssh stopped by the terminal (SIGTTOU) as it went to ask, before any
prompt was shown: the automatic fetch then hung until its 2-minute timeout, and a manual one
until Stop. Now it fails like any other refused key: load the key into your agent (`ssh-add`)
or let macOS keep its passphrase (`UseKeychain`), and Gitter uses it from then on. Your own
`SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE`, `GIT_SSH_COMMAND` and `core.sshCommand` are never
touched; if you set `SSH_ASKPASS` without `SSH_ASKPASS_REQUIRE` and start Gitter from a
terminal, ssh's own rules apply and it can still be stopped there (see the backlog).

### What fetch and push deliberately do not do

- **No prune.** Gitter's fetch always passes `--no-prune`, even when `fetch.prune`,
  `remote.<name>.prune` or `fetch.pruneTags` is set: pruning can drop the last ref to a
  deleted branch's commits, and that will need a confirmation of its own. So a branch
  someone deleted on the server keeps its `origin/…` ref in Gitter, and its local branch
  keeps counting against it; the **"gone"** badge appears only after a prune done elsewhere
  (`git fetch --prune` in a terminal) — or after Gitter's own "Delete on …", which removes the
  one ref it deleted. A "gone" branch's Push button reads **Re-publish**.
- **No tags.** Every push passes `--no-follow-tags`, even when `push.followTags` is set,
  including a force push and a deletion — measured, git otherwise publishes annotated tags
  beside the one ref it was asked to push, even beside a delete.
- **Only the current branch**, always by an explicit refspec (`refs/heads/<b>:<remote ref>`),
  to the branch's push remote (`branch.<b>.pushRemote` / `remote.pushDefault` are honoured).
  The force push is the one exception to the spelling, not to the rule: it sends the sha its
  sheet showed (`<sha>:<remote ref>`), so what lands is the commit you were shown even if the
  branch moved meanwhile — and if it did, Gitter refuses instead.
- **No submodules.** Every push passes `--no-recurse-submodules`: with `submodule.recurse` or
  `push.recurseSubmodules=on-demand` set, git otherwise pushes the submodule's branch to the
  submodule's own server too. (This also overrides `push.recurseSubmodules=check`.)
- **No autostash.** Pull's fast-forward and merge pass `--no-autostash`: with
  `merge.autoStash` set, git otherwise stashes an edit the pull would overwrite, reports
  success, and leaves the file with conflict markers. Gitter shows git's refusal instead.
- **No fetch into your own branches.** A fetch is only a read of the server while the remote's
  fetch refspecs write into `refs/remotes/`. One that writes anywhere else
  (`+refs/heads/*:refs/heads/*`, a `--mirror=fetch` remote) would move your local branches or
  tags on every fetch, so Gitter does not fetch that remote — it says so, with the `git
  config` line that fixes it — and fetches the others.

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
| Remotes | git's own transports and credentials; `fetch`, then merge or rebase, instead of `git pull`; an explicit-sha lease on every force; no prune, no tags | Nothing to store or ask for; every step of a pull is one Gitter can explain and stop; the lease the automatic fetch cannot arm |
| Scope | Browsing, diffs, staging, commit, branch and remote operations are done. Discard and stash are not built yet | Ship the commit loop before touching anything that mutates the working tree |

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

728 tests in 58 suites. Most of them run real `git` against a temporary repository rather
than a fake — the remote tests against local bare repositories standing in for a server,
with a second clone as "the colleague" who pushes in between — including one that greps
`GitCore`'s own sources for forbidden force flags. The suite isolates itself from your git
configuration (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`) and never touches the
network.

The run also reports **6 known issues, and they are meant to be there** — please do not
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

Deleting any of them would take the proof away and the suite would go on looking green.

## Project layout

Every `.swift` file in the two product targets — 92 of them, which is what `find
GitCore/Sources Gitter -name '*.swift' | wc -l` prints — with the ones inside `Models/`,
`Parsers/` and `Views/` named in prose rather than one per line. The 64 test files and
`GitCore/Package.swift` are summarised rather than listed, which is also why the check is
that command and not a bare `find . -name '*.swift'`: that one reaches them too, and the
generated sources under `.build` as well.

```
GitCore/                  SwiftPM package, no SwiftUI dependency
  Sources/GitCore/
    GitBackend.swift            Read-only protocol: snapshot, log, refs, diffs
    GitWorkingCopyBackend.swift Staging/commit/amend protocol and its contract
    GitBranchBackend.swift      Branch/merge/abort protocol and its contract
    GitRemoteBackend.swift      Fetch/push/lease/rebase protocol and its contract
    GitError.swift              commandFailed, launchFailed, and the two pre-flight refusals
    FetchRefspec.swift          Which configured fetch refspecs write outside refs/remotes/
    BranchOperationTypes.swift  MergeMode, MergeOutcome, BranchDeletion, the typed refusals
    RemoteOperationTypes.swift  PushOutcome, PushResult, RebaseOutcome, RemoteOperationError,
                                PullPlan, PushTarget (where a push goes), StopClick
    CLIGitBackend.swift         The implementation over /usr/bin/git, plus
      +WorkingCopy.swift          staging, commit, amend (and the amend-mid-operation refusal)
      +Branches.swift             create, switch, detach, track, rename
      +BranchDelete.swift         `branch -d`, and `-D` only against an expected tip
      +Merge.swift                the three merge modes and the name/tag comparison
      +Abort.swift                the five `--abort`s and `reset --merge`
      +Operation.swift            which of the six operations is part-way through
      +Remotes.swift              fetch, commit lists, the "held only there" count
      +Push.swift                 push, publish, the leased force push and delete
      +Rebase.swift               the pull's rebase, and what a stopped one means
    ProcessRunner.swift         Process spawning with LC_ALL=C and captured stderr
      +Streaming.swift            the cancellable runner: progress, SIGTERM then SIGKILL
    GraphLayout.swift           gitk-style commit lane assignment
    PatchBuilder.swift          Builds a hunk- or line-level patch from a parsed diff, with
      +Markers.swift / +Paths.swift
    Models/                     RepoSnapshot, Commit, FileStatus, Diff, Branch, Graph, Remote
    Parsers/                    Status, Log, Ref, Diff (+Paths), BranchRefusal, Remote,
                                PushPorcelain and RemoteFailure parsers
  Tests/GitCoreTests/           58 suites; ForceFlagScanner(+Lexing) is the force-flag grep

Gitter/                   macOS app (SwiftUI)
  GitterApp.swift            App entry point, the one store (`AppModel`), the Repository
                              menu, Open Recent and the quit hook (`AppDelegate`)
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
  AutoFetchScheduler.swift   When the quiet automatic fetch runs (the store decides what it does)
  QuitGuard.swift            Quitting while the network lane is busy: stop, or ask first
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
                              Banners, BranchToolbar, BranchNameValidator, BranchSheetHost,
                              RemoteToolbar, TrackingBadge and the ten sheets (NewBranch,
                              Rename, Merge, DeleteBranch, Abort, LeaveDetached, Pull,
                              Publish, ForcePush, DeleteRemoteBranch)
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
| `GITTER_DEBUG_KEYS=space,return,cmd+return` | then press those keys (`space`, `return`, `tab`, `escape`, `up`, `down`, `period`, `f`, `l`, `p`, `r`, with `cmd+`/`shift+`/`opt+`/`ctrl+`). A key with `cmd+` is dispatched as AppKit dispatches one — the window's views, then the main menu — because a *posted* command key never reaches a menu's key equivalent (measured: a posted ⌘R ran no Refresh) |
| `GITTER_DEBUG_TYPE=text` | then type that text into whatever has focus |
| `GITTER_DEBUG_DUMP_RESPONDER=1` | print the first-responder chain, the window geometry and whether the window is key to stderr, after every click and key; a count instead of `1` repeats the final dump that many times, 200 ms apart, which is how you tell "never focused" from "focused, then lost it" |
| `GITTER_DEBUG_BRANCH_ACTION=<step>[;<step>…]` | run branch actions and open their sheets (see below) — the sidebar's context menus are AppKit menus that in-process clicks cannot open |
| `GITTER_DEBUG_THEN=<step>[;<step>…]` | more branch steps, run **after** the clicks and keys — what a click on a toolbar button did: `idle;snapshot:after-click` |
| `GITTER_DEBUG_AUTOFETCH=<interval>[,<timeout>]` | run the automatic fetch every `<interval>` seconds instead of 10 minutes, stopping each one after `<timeout>` seconds (default 120) instead of 2 minutes — so a script sees several ticks. Every tick and every ending prints an `AUTOFETCH …` line, naming the store (`store 1`); `STORES built: <n>` lines at launch and on every open event say how many stores exist — one is the only right answer |
| `GITTER_DEBUG_QUIT_WAIT=<seconds>` | how long **Wait**, in the quit alert, waits for a write before calling the quit off with a banner, instead of 10 minutes — so a script can reach the bound with a slow scratch transport |
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
| `menu:<title>` | log every item of that main-menu menu — title, shortcut, enabled — as it would be when opened; a script cannot open a menu. As the **very first** step it can read stale state (seen: every item `enabled=false` before the first snapshot had loaded), so put `wait:1` before it |
| `views[:<class>]` | log the window's view tree with frames in click coordinates; a toolbar item is a `ToolbarItemHostingView`, above the content area (negative y) — the centre of its frame is where `GITTER_DEBUG_CLICK` aims |
| `badges` | log what each local branch's tracking badge draws, its tooltip and its VoiceOver text — the snapshot cannot draw the sidebar |
| `copyurls` | for every configured remote, take the items its sidebar menu offers ("Copy URL", "Copy Push URL"), copy each through the menu's own call onto a *private* pasteboard and log `copy <remote> "<title>": <raw address> -> <what was copied>` — how the credential redaction is checked. It prints the raw address, so point it only at scratch remotes |
| `autofetchfailed:<reason>` | set the failure the Fetch item's quiet mark stands for, without waiting for a real automatic fetch to fail |
| `menuitem:<menu>:<title>` | choose that main-menu item (`NSMenu.performActionForItem`) — how "Fetch Automatically" is toggled; `menu:<title>` a second later shows its tick as `state=on` |
| `quit` | quit as ⌘Q does, from the run loop, so the steps after it run while the quit is held: `start:push;wait:1;quit;wait:1;start:snapshot:alert;alert;alertbutton:Wait`. `QUIT …` lines say what was decided and when |
| `alert` / `alertbutton:<title>` | log every text and button (with its key equivalent) of the alert on screen — the snapshot draws an alert's buttons but not its text — and click one of its buttons |

A step that starts network work waits for the lane to free as well, for up to 120 seconds; a
step taken while the lane is already busy waits only for the mutation slot, so a second
network action is refused and logged at once. After each step a second line reports the lane
(its kind, remote and progress line), the three blocked reasons, the push button's title, the
tracking, the counts the Push and Pull buttons draw (`pushCount`, `pullCount`), the Push
tooltip, the remembered pull mode, how many snapshot loads have run, whether "Fetch
Automatically" is on and the last automatic fetch's failure. An automatic fetch on the lane
does not count as busy for this: the user's actions stop it and go ahead. A step that starts **no** network work, though, waits for the lane to be empty, the automatic fetch included — so `snapshot:` taken during one waits for it to end; write `start:snapshot:<name>` to shoot it running. And `quit` while a sheet is on screen does nothing at all: AppKit does not ask the app whether it may quit while a window has a sheet attached (seen with the new-branch sheet and the delete-on-remote sheet alike), so answer or close the sheet first. A click on the
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
has focus. Launch through `open` to see stderr and to get a properly frontmost app:

```sh
open -n -F --stderr /tmp/gitter.log --env GITTER_DEBUG_CLICK=684,170 \
  --env GITTER_DEBUG_DUMP_RESPONDER=1 -a .build/DerivedData/Build/Products/Debug/Gitter.app
```

## Status / roadmap

Stages files, hunks and lines; commits, amends and commits all tracked changes; creates,
switches, merges, renames and deletes branches, checks out remote branches and tags, and
aborts an operation or undoes a pending squash; fetches, pulls (merge or rebase) and pushes
the current branch, publishes and re-publishes it, force-pushes behind a lease and a
confirmation, deletes a branch on a remote, and keeps ahead/behind current with a quiet
automatic fetch.

Next up, from the backlog: **discard** (file, hunk, line — the missing half of staging, and
loss-capable, so it comes with its own confirmation) and **stash**, which would also let pull
and rebase offer "stash, then continue". After those: conflict resolution and continuing a
rebase inside the app (today you resolve in your editor and a stopped rebase can only be
aborted here), prune with a confirmation plus cleaning up "gone" branches, and tags (creating
them, then pushing one by name). Everything wanted and deliberately deferred is kept in
[`docs/BACKLOG.md`](docs/BACKLOG.md), with what is already known about each item — including
what only a person at the keyboard can still check about the remote work (real HTTPS and ssh
credentials, the menus, tooltips and VoiceOver).
