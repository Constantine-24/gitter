# Installing Gitter on your own Macs

Gitter is not a public release. It is built on one Mac, wrapped in a DMG by one script, and carried
to your other Apple Silicon Macs through a folder you sync. Each install keeps a local log, which you
can bring back. This page covers the whole path, once, in order. What macOS does on the way has not
all been measured yet; those steps say so, and they are on the user's checklist in
[`BACKLOG.md`](BACKLOG.md) ("Milestone P1").

## 1. The signing certificate, once, on the Mac that builds

A build that is not signed with a certificate is signed "ad-hoc", and its identity is a hash of the
binary itself (`codesign -d -r-` prints `designated => cdhash H"…"`). Every build is then a new app to
macOS, so the folders you let Gitter into — Documents, Desktop, iCloud Drive — can be asked about
again after every update. A self-signed certificate keeps the identity the same from build to build.

1. Open **Keychain Access** (Spotlight finds it).
2. Choose **Keychain Access › Certificate Assistant › Create a Certificate…**.
3. Fill in:
   - **Name:** `Gitter Local Signing`;
   - **Identity Type:** Self-Signed Root;
   - **Certificate Type:** Code Signing.
4. Create it. It lands in your login keychain.

The certificate is needed only on the Mac that builds. The other Macs only run the app. The script
never creates, imports or reads keys: the certificate is yours, and only its name goes to `codesign`.
The first time `codesign` uses the key, macOS may ask whether it may; **Always Allow** stops it asking
again.

## 2. Packaging

From a clean checkout, with [XcodeGen](https://github.com/yonaskolb/XcodeGen) installed
(`brew install xcodegen`):

```sh
bash scripts/package.sh --sign "Gitter Local Signing"
```

or, to put a copy straight into a synced folder as well:

```sh
GITTER_DIST_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Gitter" \
  bash scripts/package.sh --sign "Gitter Local Signing"
```

What it does, in order:

- **It refuses** (exit 2, before building) when `git status --porcelain` shows anything, so every DMG
  maps to a commit; when XcodeGen is missing; for an unknown flag, or a `--sign` with no name; and for
  `--notarize`, which is reserved: "not set up yet: it needs a Developer ID".
- **It builds** an arm64 Release with `xcodegen generate` and `xcodebuild`, into `dist/DerivedData`, not
  your Xcode folder. The version is `MARKETING_VERSION` in `project.yml`, which you bump by hand. The
  build number is `git rev-list --count HEAD`, so it goes up with every commit on `main`. The commit's
  short hash goes into `Info.plist` as `GitterCommit`. `project.yml` is not edited.
- **With `--sign`**, it re-signs the built app with that identity: `codesign --force --options runtime
  --timestamp=none --entitlements <the built app's own> --sign "<identity>"`. The identity is the
  certificate's **exact** name, as Keychain Access shows it, or its 40-character SHA-1 fingerprint
  (Keychain Access shows it in the certificate's details; leave out the spaces). A part of the name is
  not enough: `codesign` would accept it, but the script then checks that the signature's
  `Authority=` line is that name exactly, and fails, saying what it expected and what it found. The
  bundle holds no nested code today — no framework, no helper — so it is signed without `--deep`. An
  embedded framework or helper added later must be signed too, inside out, before the app.
- **Without `--sign`**, the app stays ad-hoc signed, as the build leaves it. It runs, but see §1.
- **It checks the app**, and fails with exit 3 if any check fails: `codesign --verify --strict --deep`;
  the hardened runtime flag; the identity (or `adhoc`); `lipo` says arm64 only; `Info.plist` holds the
  version, build and commit it passed in; and the binary holds none of the Debug harness's names. That
  last scan first proves it can find a name that is there.
- **It makes the DMG**, `dist/Gitter-<version>-<build>.dmg`, holding `Gitter.app` and an `Applications`
  shortcut. The image is built under a temporary name, verified with `hdiutil verify`, mounted
  read-only to check both items, detached, and only then given its name. A DMG of the same name is
  replaced, and the script says so (`replaced dist/…`): packaging the same commit twice gives the same
  name.
- **With `GITTER_DIST_DIR` set**, it copies the DMG there too, under a temporary name first and then
  moved into place, so a sync service never sees half a file. It says `replaced …` there as well.
- **At the end** it prints the DMG's path, the copy's path, the SHA-256, the version, build, commit and
  signing identity, and what `spctl --assess` says. `spctl` judges the app as if it had been
  downloaded, and rejects one that is not notarized, quarantined or not, so "rejected" there is
  expected and is not a failure: the script's exit status is.

## 3. git, on every Mac that runs Gitter

Gitter runs `/usr/bin/git`. Until the Command Line Tools are installed, that path is only a stub that
offers to install them, and Gitter's banner says "Git was not found at /usr/bin/git. Install the Xcode
Command Line Tools." Install them first:

```sh
xcode-select --install
```

Gitter uses your own git: its configuration, your ssh agent and keys, and your credential helpers.
Nothing about git is set up inside Gitter.

## 4. Installing

1. Open the DMG from the synced folder, and drag **Gitter** onto **Applications**.
2. Eject the DMG.
3. Open Gitter from `/Applications`.

**If macOS refuses to open it.** A file that came through a browser, a sync service or AirDrop can
carry the `com.apple.quarantine` mark. Gatekeeper then refuses an app that is not notarized, ad-hoc or
self-signed alike, and a right-click › Open no longer gets past that (macOS 15 and later). Whether
iCloud Drive or AirDrop marks a DMG has not been measured: if Gitter opens at once, it was not marked.
If it is refused:

- click **Done** in macOS's message, open **System Settings › Privacy & Security**, scroll to
  Security, click **Open Anyway** beside Gitter's line, confirm, and open Gitter again; or
- clear the mark with one Terminal line, which does the same:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Gitter.app
  ```

Either is needed once per install, not on every launch.

**Folder access.** The first time Gitter opens a repository in Documents, Desktop or iCloud Drive,
macOS asks whether Gitter may use that folder. With a build signed by your certificate, the answer
should survive the next update (not yet measured: on the checklist); with an ad-hoc build it is
asked again.

**Which build you have.** **Gitter › About Gitter** shows, for example, "Version 0.1.0 (440,
99be6f3)": the version, the build number and the commit. Only a packaged build has the commit; a
build from Xcode shows the version and its build number alone, "Version 0.1.0 (1)".

## 5. Updating

1. Quit Gitter.
2. Open the new DMG, and drag Gitter onto Applications over the old one (Finder asks: **Replace**).
3. Open Gitter.

Preferences, File › Open Recent and the windows Gitter reopens belong to the bundle id
`dev.penzin.Gitter`, so they carry over. A replaced app may be quarantined again, and then needs
§4's step again.

## 6. One copy, in /Applications

Keep a single copy of Gitter, in `/Applications`, on every Mac. On the Mac that builds, Xcode's Debug
builds have the same bundle id as the installed app, on purpose: they share its preferences, its Open
Recent and its log folder. A second copy — a build left in Xcode's DerivedData, or the app inside
`dist/DerivedData` — is still an app Finder and `open` can start instead of the one in
`/Applications`. Two Gitters running at once write the same log: their lines interleave rather than
overwrite each other, but their rotations can trip over each other (the backlog has it).

## 7. The logs

Gitter keeps a log of every git call it makes and every message it shows you, so a problem on another
Mac can be read afterwards.

**Where.** `~/Library/Logs/Gitter/gitter.log`. **Help › Show Logs** opens that folder in Finder, and
makes it first if it does not exist yet; if it can neither make nor open it, an alert says why.

**What a line says.** One line per event, plain UTF-8 text, each starting with the local time to the
millisecond and its offset from UTC:

```
2026-10-11T12:12:26.500+04:00 launch: Gitter 0.1.0 (440, 99be6f3), macOS Version 27.0.1 (Build 26A434), git version 2.54.0 (Apple Git-157)
2026-10-11T12:12:26.501+04:00 open /Users/you/Developer/project
2026-10-11T12:12:26.702+04:00 git 0.012s /Users/you/Developer/project: status --porcelain=v2 -z --branch → ok
2026-10-11T12:12:28.216+04:00 git 0.007s /Users/you/Developer/project: switch --no-guess --end-of-options nosuchbranch → exit 128
    fatal: invalid reference: nosuchbranch
2026-10-11T12:12:28.245+04:00 banner /Users/you/Developer/project: fatal: invalid reference: nosuchbranch
2026-10-11T12:12:31.747+04:00 close /Users/you/Developer/project
```

- **`launch:`** — one per launch: Gitter's version, build and commit, the macOS version, and what
  `git --version` says (or "git: not available").
- **`open` / `close`** — each window's repository, with its path; a window switched to another
  repository closes the old one first, and a quit that goes ahead closes every open window.
- **`git`** — every git call: how long it took, the folder it ran in, its arguments (one with a blank
  or a quote in it is single-quoted) and how it ended: `ok`, `exit <code>`, `killed`, `cancelled`,
  `launch failed: …` or `refused before launch: …`. A call that failed is followed by git's own
  words, each line indented. A git killed while it ran through Gitter's plain runner reads as
  `exit <signal>`, not `killed` (the backlog has it).
- **`banner`, `notice`, `sticky`** — every error banner and notice as it was shown, with the
  repository's path.
- **`quit question:`** — which button answered "quit while a push runs?": Wait, Stop and Quit, or
  Don't Quit.
- **`alert "…": … → Show|Close`** — the alert a closed window's unfinished change raised, and the
  answer.

Two things about the order. A git line carries the time the call **started**, but is written when it
**ends**, so the lines of calls that overlapped can be slightly out of time order. And the `launch:`
line waits for `git --version`, so it can come after the first window's lines.

**Size.** When `gitter.log` would pass 2 MB it becomes `gitter.1.log`, the older ones move up to
`gitter.4.log`, and the oldest goes: five files, 10 MB at most. If the folder is deleted while Gitter
runs, the next line makes it again. If the folder cannot be made or a write fails, logging stops for
the rest of that launch, without an alert, and Gitter goes on.

**Privacy.** The log stays on the Mac; nothing in Gitter uploads it. Read it before you send it
anyone, because it holds:

- **as they are:** repository paths, branch, tag and remote names, file names, and the messages
  that travel in git's arguments — a stash's message, Gitter's own "Discarded by Gitter" record
  messages and its reflog messages;
- **not at all:** commit and tag messages, which reach git through a file; what git prints on its
  standard output; and its error output when the call succeeded;
- **cut:** git's words on a failure, after 2 048 bytes, and an argument list longer than 40, after its
  first 20 ("… and N more");
- **removed:** a URL's username and password, in every argument (`remote add`, `set-url`) and in
  git's words. One exception: a password holding an unencoded `/`, `?` or `#`
  (`https://me:p/ss@host/x`) makes the URL invalid — such a character must be percent-encoded, and
  git never sends that password to a server — and it stays in clear in that `remote add` or
  `set-url` line;
- **as shown:** banners and notices, word for word as they were on screen.

**Bringing a log back.** Use Help › Show Logs, then copy the `gitter*.log` files (or the whole
folder) to a USB stick, AirDrop or the synced folder. Deleting the folder is safe: Gitter makes it
again on its next line.
