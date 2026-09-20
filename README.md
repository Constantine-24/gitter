# Gitter

Gitter is a simpler native Git client for macOS — an alternative to Tower and GitKraken
without the feature bloat. It opens a repo, browses branches and the commit graph, and
shows diffs, all live-refreshed as the working copy changes. It now stages files, hunks
and even single lines, and commits — including amend and "commit all tracked" — from
those diffs. There is still no discard, no branch operations and no remotes; those are
next.

![Gitter main window](docs/screenshots/main.png)

## What it can do

- Browse commit history with a lane graph (gitk-style)
- View diffs of a commit, or of the working copy, with wrapping long lines
- Stage and unstage whole files, individual hunks, or a hand-picked set of lines
- Commit, amend the last commit, or commit every tracked change in one step
- Hooks and commit signing apply as configured, because every commit runs through
  your own `git`, not a reimplementation of it

## Safety

Gitter's own operations never modify or delete a file in your working tree: staging and
unstaging change only the index (`git apply --cached`, `git add`, `git reset`), and
committing writes only to the repository. Hooks you have configured run exactly as they
would from the command line, so a pre-commit hook that rewrites files (an auto-formatter,
say) will still do so — that rewrite is your hook acting, not Gitter. The staging claim is
verified by tests that `shasum` every worktree file before and after each staging
operation and require the bytes to be identical.

## Design decisions

| Area | Decision | Rationale |
|---|---|---|
| UI | SwiftUI, AppKit where SwiftUI falls short | Most Mac-native result |
| Git access | `/usr/bin/git` via `Process`, behind a `GitBackend` protocol | SSH agent, credential helpers, signing and hooks work for free. libgit2 can be added behind the same protocol for hot read paths |
| Deployment | macOS 26.0 minimum, macOS 27 SDK | Dev machine runs 27 |
| Project | xcodegen `project.yml` -> `Gitter.xcodeproj`; `GitCore` local SwiftPM package | Xcode workflow for the app; `swift test` for the core |
| Staging | Patches built in-process (`PatchBuilder`) and applied with `git apply --cached`, never a hand-rolled index writer | The same command a user would run themselves; hunk- and line-level staging fall out of the same code path as whole-file staging |
| Scope | Repo browsing, diffs, staging and commit are done. Discard, branches and remotes are not built yet | Ship the commit loop before touching anything that mutates the working tree |

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

182 tests, 4 known issues (pre-existing, tracked skips — not failures).

## Project layout

```
GitCore/                  SwiftPM package, no SwiftUI dependency
  Sources/GitCore/
    Models/                RepoSnapshot, Commit, FileStatus, Diff, Branch, Graph
    Parsers/                Status, Log, Ref, Diff parsers over git CLI output
    GraphLayout.swift        gitk-style commit lane assignment
    CLIGitBackend.swift       GitBackend implementation over /usr/bin/git
    PatchBuilder.swift        Builds a hunk- or line-level patch from a parsed diff
    GitWorkingCopyBackend.swift  Staging/commit/amend protocol, implemented over the CLI
      in CLIGitBackend+WorkingCopy.swift
  Tests/GitCoreTests/

Gitter/                   macOS app (SwiftUI)
  GitterApp.swift            App entry point, commands, Open Recent
  RepositoryStore.swift      @Observable @MainActor store: snapshot + selection state
  RepositoryStore+Staging.swift  Staging, commit and amend actions on the store
  CommitDraft.swift          The commit message + amend toggle being edited
  RepositoryWatcher.swift    FSEvents-based debounced refresh trigger
  DebugLaunchHooks.swift     Debug-only launch hooks for screenshot verification (see below)
  Views/                     SidebarView, CommitListView, CommitGraphCell, DetailView,
                              WorkingCopyFileList, CommitComposerView, DiffView, DiffHunkView,
                              DiffLineSelection, ErrorBanner
```

## Debug launch hooks

`Gitter/DebugLaunchHooks.swift` and `DebugLaunchHooks+Events.swift` exist only in Debug
builds (`#if DEBUG`, compiled out of Release) and drive the UI from environment variables,
read once at startup. They exist because the verification environment has Screen Recording
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
| `GITTER_DEBUG_CLICK=x,y[:2\|:shift][;…]` | click those points, in points from the top-left of the window's content area; `:2` double-clicks, `:shift` shift-clicks, and a `type=text` step types between two clicks |
| `GITTER_DEBUG_KEYS=space,return,cmd+return` | then press those keys (`space`, `return`, `tab`, `escape`, `up`, `down`, with `cmd+`/`shift+`/`opt+`/`ctrl+`) |
| `GITTER_DEBUG_TYPE=text` | then type that text into whatever has focus |
| `GITTER_DEBUG_DUMP_RESPONDER=1` | print the first-responder chain, the window geometry and whether the window is key to stderr, after every click and key |

The click and key variables wait for the window to actually become key first, and activate
the app, because an inactive window draws its selection in the unemphasized grey whatever
has focus. Launch through `open` to see stderr and to get a properly frontmost app:

```sh
open -n -F --stderr /tmp/gitter.log --env GITTER_DEBUG_CLICK=684,170 \
  --env GITTER_DEBUG_DUMP_RESPONDER=1 -a .build/DerivedData/Build/Products/Debug/Gitter.app
```

## Status / roadmap

Stages files, hunks and lines; commits, amends and commits all tracked changes. Next up:
branch operations (create, checkout, delete, merge), then push/pull/fetch. Later: discard,
stash, and conflict resolution.
