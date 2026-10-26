# Gitter

A simple, native Git client for macOS: an alternative to Tower and GitKraken, without the
feature bloat.

Gitter opens a repository and shows its branches, its commit graph and its diffs, refreshed live
as the working copy changes. You can stage, commit, branch, merge and sync without leaving the
window. Every action runs through your own `/usr/bin/git`, so your SSH agent, credential helpers,
hooks and commit signing all work exactly as they do in the terminal.

![Gitter's main window: the branch button, the sidebar, the lane graph and a diff](docs/screenshots/branches.png)

## Highlights

- **History.** A gitk-style lane graph that goes back to the first commit. Older commits load as
  you scroll, and clicking an old branch or tag jumps straight to it.
- **Staging and committing.** Stage whole files, single hunks or hand-picked lines. Commit, amend,
  or commit every tracked change in one step.
- **Branches.** Create, switch, rename, delete and merge branches: fast-forward, merge commit or
  squash. Check out remote branches, tags and commits.
- **Remotes.** Fetch, pull (merge or rebase) and push from the toolbar, with git's own progress
  and a Stop button. Ahead/behind counts show on every branch, and a quiet background fetch keeps
  them current. A force push is always leased on the exact commit you were shown.
- **Conflicts.** Resolve them in the app, block by block, with ours beside theirs and the result
  shown before anything is written. Then continue, skip or abort the merge, rebase, cherry-pick or
  revert.
- **History actions.** Cherry-pick or revert several commits as one sequence, or rebase onto a
  commit or a branch. Each one opens a sheet that lists exactly what will run.
- **Stash and discard.** Stash everything or only selected files. Discard a file, a hunk or a line,
  and get **Undo Discard** every time.
- **Tags, remotes and worktrees.** Create, push and delete tags, with **Restore Tag** afterwards.
  Prune a remote, clean up branches whose upstream is gone, and add, rename or remove remotes. List,
  open, add and remove worktrees.
- **Navigation.** Filter the sidebar as you type, and compare two branches: the commits only on
  each side, and the changes one would bring.
- **Several windows.** Open one repository per window. The windows come back at the next launch.
  A quit never cuts off a push that is still running.

The [user guide](docs/GUIDE.md) describes every feature in detail, and the [website](https://constantine-24.github.io/gitter/) has a shorter tour.

## Your work is safe

> **Gitter never discards uncommitted work or commits without a confirmation that names what will
> be lost**, and a discard also leaves a copy that can be brought back.

- Each discard is recorded as a stash entry first, and untracked files go to the Trash.
- Branches are deleted with `git branch -d` first. `-D` is used only after a warning that names
  the commits it would lose.
- A pull is run as a fetch, then a merge or rebase that Gitter can explain and stop.
- Before a history action, a prune or a worktree removal, the plan is read and shown on a sheet.
  It is checked again just before git runs, and the action is refused if anything changed.
- Every git call Gitter makes is written to `~/Library/Logs/Gitter/gitter.log`, with credentials
  removed from URLs. Nothing leaves your Mac.

The [Safety section of the guide](docs/GUIDE.md#safety) gives the full rules for credentials,
fetch and push, stash and discard, conflicts, history actions and remotes.

## Requirements

- macOS 26 or later, on Apple Silicon
- Git at `/usr/bin/git`, which the Xcode Command Line Tools provide
- To build from source: Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Install

Gitter is not distributed as a signed release yet. Build a DMG from a clean checkout:

```sh
bash scripts/package.sh --sign "Gitter Local Signing"
```

This writes `dist/Gitter-<version>-<build>.dmg`. [`docs/INSTALL.md`](docs/INSTALL.md) covers the
whole path:
- making the self-signed certificate once;
- the first open past Gatekeeper;
- updating;
- finding the log.

## Build and run

```sh
brew install xcodegen
xcodegen generate
open Gitter.xcodeproj
```

To build without opening Xcode:

```sh
xcodegen generate && xcodebuild -project Gitter.xcodeproj -scheme Gitter \
  -configuration Debug -derivedDataPath .build/DerivedData build
```

## Tests

```sh
bash scripts/test-gitcore.sh      # GitCore: the git layer, parsers and models
xcodegen generate && xcodebuild -project Gitter.xcodeproj -scheme Gitter -configuration Debug test   # both targets
```

The tests run against real git, in throwaway repositories. They never touch your own
repositories, defaults or logs.

## How it's built

- **SwiftUI**, with AppKit where SwiftUI falls short.
- **`GitCore`**, a local Swift package. Its `GitBackend` protocol is implemented by running
  `/usr/bin/git` through `Process`, and its parsers read git's own output.
- **Changes the way you'd make them.** Staging builds patches in-process and applies them with
  `git apply --cached`. Gitter has no index writer of its own.
- **One store per window** (`RepositoryStore`), which owns that window's sheets, network lane and
  fetch schedule.

[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) covers the rest: the design decisions and why they
were made, packaging, the test gates, the project layout file by file, and the debug launch hooks
used to drive the real app.

## Documentation

| Document | What's in it |
|---|---|
| [User guide](docs/GUIDE.md) | Every feature, and the safety rules behind each one |
| [Installing](docs/INSTALL.md) | Certificate, DMG, Gatekeeper, updates and the log |
| [Developing](docs/DEVELOPMENT.md) | Design decisions, build, tests, layout, the debug harness, and the roadmap so far |
| [Backlog](docs/BACKLOG.md) | Everything wanted or deferred, with what is already known about each item |
| [Specs and plans](docs/superpowers) | The design and the implementation plan for each milestone |

## Status

Gitter is a personal project in active development (version 0.1.0). Each milestone is listed under
"Status / roadmap" in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md#status--roadmap). Planned next:
- a batch of small, visible fixes;
- commit search.

## License

MIT. See [`LICENSE`](LICENSE).
