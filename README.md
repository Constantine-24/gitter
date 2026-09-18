# Gitter

Gitter is a simpler native Git client for macOS — an alternative to Tower and GitKraken
without the feature bloat. Today it's a read-only repository browser prototype: open a
repo, browse branches and the commit graph, and view diffs, all live-refreshed as the
working copy changes. The V1 goal is a full daily-driver workflow: stage and commit,
branch operations, and push/pull/fetch.

![Gitter main window](docs/screenshots/main.png)

## Design decisions

| Area | Decision | Rationale |
|---|---|---|
| UI | SwiftUI, AppKit where SwiftUI falls short | Most Mac-native result |
| Git access | `/usr/bin/git` via `Process`, behind a `GitBackend` protocol | SSH agent, credential helpers, signing and hooks work for free. libgit2 can be added behind the same protocol for hot read paths |
| Deployment | macOS 26.0 minimum, macOS 27 SDK | Dev machine runs 27 |
| Project | xcodegen `project.yml` -> `Gitter.xcodeproj`; `GitCore` local SwiftPM package | Xcode workflow for the app; `swift test` for the core |
| Scope | Read-only: open repo, branches, commit graph, diffs, live refresh | Zero risk while the foundation is proven |

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

## Project layout

```
GitCore/                  SwiftPM package, no SwiftUI dependency
  Sources/GitCore/
    Models/                RepoSnapshot, Commit, FileStatus, Diff, Branch, Graph
    Parsers/                Status, Log, Ref, Diff parsers over git CLI output
    GraphLayout.swift        gitk-style commit lane assignment
    CLIGitBackend.swift       GitBackend implementation over /usr/bin/git
  Tests/GitCoreTests/

Gitter/                   macOS app (SwiftUI)
  GitterApp.swift            App entry point, commands, Open Recent
  RepositoryStore.swift      @Observable @MainActor store: snapshot + selection state
  RepositoryWatcher.swift    FSEvents-based debounced refresh trigger
  Views/                     SidebarView, CommitListView, CommitGraphCell, DetailView, DiffView, ErrorBanner
```

## Status / roadmap

Read-only today. Next up: staging and commit, branch operations (create, checkout,
delete, merge), and push/pull/fetch.
