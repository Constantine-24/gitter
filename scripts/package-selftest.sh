#!/bin/bash
# Selftest for package.sh's refusals. None of these cases builds.
#
#   bash scripts/package-selftest.sh
#
# Runs this working tree's package.sh against a scratch `git clone --no-hardlinks` of the
# repository (GITTER_PACKAGE_ROOT), so it works before anything is committed. Checks each
# refusal by exit status and first stderr line, and — the controls — that a clean tree and a
# --sign with a value get past every refusal to the build (exit 99, GITTER_PACKAGE_NO_BUILD). The
# scratch folder is removed on exit.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap '/bin/rm -rf "$SCRATCH"' EXIT

export GIT_ALLOW_PROTOCOL=file GIT_SSH_COMMAND=/usr/bin/false GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset SSH_AUTH_SOCK
# Only the rows that set them pass a copy folder or another root.
unset GITTER_DIST_DIR ROW_ROOT
# A regressed refusal must exit 99 here, never fall through to a build.
export GITTER_PACKAGE_NO_BUILD=1
. "$HERE/package-lib.sh"

CLONE="$SCRATCH/clone"
git clone --quiet --no-hardlinks "$REPO" "$CLONE"

FAILS=0
# expect <name> <exit> <first-stderr-line-or-empty> -- <args...>
expect() {
    local name="$1" want_code="$2" want_line="$3"
    shift 4
    local err="$SCRATCH/err" code=0
    GITTER_PACKAGE_ROOT="${ROW_ROOT:-$CLONE}" bash "$HERE/package.sh" "$@" >/dev/null 2>"$err" || code=$?
    local first
    first="$(head -n 1 "$err")"
    if [ "$code" != "$want_code" ]; then
        echo "FAIL $name: exit $code, wanted $want_code (stderr: $first)"; FAILS=$((FAILS + 1)); return
    fi
    if [ -n "$want_line" ] && [ "$first" != "$want_line" ]; then
        echo "FAIL $name: first stderr line '$first', wanted '$want_line'"; FAILS=$((FAILS + 1)); return
    fi
    if [ -z "$first" ]; then
        echo "FAIL $name: no stderr"; FAILS=$((FAILS + 1)); return
    fi
    echo "ok   $name"
}

USAGE='package.sh: usage: bash scripts/package.sh [--sign "<identity>"]'
BUILD_REACHED="package.sh: reached the build with GITTER_PACKAGE_NO_BUILD set"

expect "--notarize" 2 "package.sh: --notarize is not set up yet: it needs a Developer ID" -- --notarize
expect "--bogus" 2 "$USAGE" -- --bogus
expect "--sign with no value" 2 "" -- --sign
expect "--sign with an empty value" 2 "" -- --sign ""

# The controls: on the clean clone, with no arguments and with a --sign that has a value, nothing
# refuses and the run reaches the build. A refusal that fired every time would fail these.
expect "clean tree reaches the build" 99 "$BUILD_REACHED" --
expect "clean tree with --sign <value> reaches the build" 99 "$BUILD_REACHED" -- --sign "Some Name"
GITTER_DIST_DIR="$SCRATCH/dist-copy" expect "an absolute GITTER_DIST_DIR reaches the build" 99 "$BUILD_REACHED" --

# A relative GITTER_DIST_DIR is refused: package.sh works from the repository, not the caller's
# folder, so it would land there (and make the next run's tree dirty).
GITTER_DIST_DIR="dist-copy" expect "a relative GITTER_DIST_DIR" 2 \
    "package.sh: GITTER_DIST_DIR must be an absolute path, not dist-copy" --

# A failing tool is exit 1, whatever its own status: git's 128 for a folder that is no repository.
NOT_A_REPO="$SCRATCH/not-a-repo"
mkdir -p "$NOT_A_REPO"
ROW_ROOT="$NOT_A_REPO" expect "a root that is no repository: exit 1, not git's 128" 1 "" --

touch "$CLONE/untracked-file"
expect "untracked file" 2 "package.sh: the tree is not clean" --
# The user's status.showUntrackedFiles does not hide one.
git -C "$CLONE" config status.showUntrackedFiles no
expect "untracked file with status.showUntrackedFiles=no" 2 "package.sh: the tree is not clean" --
git -C "$CLONE" config --unset status.showUntrackedFiles
# A modified tracked file is just as dirty.
/bin/rm "$CLONE/untracked-file"
echo "x" >> "$CLONE/project.yml"
expect "modified file" 2 "package.sh: the tree is not clean" --

# Controls for the Release-name scan: the same code must FIND a name that is present. The needle
# is on the first line of a 20 MB file, the case where grep -q under pipefail used to miss it.
big="$SCRATCH/big.txt"
{ echo "KNOWN_NEEDLE_NAME"; head -c 20000000 /dev/zero | tr '\0' 'x' | fold -w 80; } > "$big"
check() { # check <name> <command...>: the command must succeed
    local name="$1"; shift
    if "$@"; then echo "ok   $name"; else echo "FAIL $name"; FAILS=$((FAILS + 1)); fi
}
check "control: text_has finds a name on the first line of 20 MB" text_has "$(cat "$big")" KNOWN_NEEDLE_NAME
check "control: text_has does not find an absent name" bash -c '! { . "$0"; text_has "abc" zzz; }' "$HERE/package-lib.sh"
check "control: strings scan finds a present name" binary_has strings /bin/ls CLICOLOR
check "control: nm scan finds a present symbol" binary_has symbols /bin/ls __mh_execute_header
check "control: scans do not find an absent name" bash -c '. "$0"; ! binary_has strings /bin/ls GITTER_LOG_DIR && ! binary_has symbols /bin/ls GitCoreTestSupport' "$HERE/package-lib.sh"

# The Authority matching, on captured codesign -dvv text (no codesign, no identity involved).
ADHOC=$'Signature=adhoc\nTeamIdentifier=not set'
SIGNED=$'Authority=My Cert\nTeamIdentifier=not set'
HASH=0123456789abcdef0123456789abcdef01234567
check "authority: name matches exactly" authority_problem "$SIGNED" "My Cert"
check "authority: other name refused" bash -c '. "$0"; ! authority_problem "$1" "Other" >/dev/null' "$HERE/package-lib.sh" "$SIGNED"
check "authority: name must be whole line" bash -c '. "$0"; ! authority_problem "$1" "My" >/dev/null' "$HERE/package-lib.sh" "$SIGNED"
check "authority: hash with an authority passes" authority_problem "$SIGNED" "$HASH"
check "authority: hash with adhoc refused" bash -c '. "$0"; ! authority_problem "$1" "$2" >/dev/null' "$HERE/package-lib.sh" "$ADHOC" "$HASH"
check "authority: hash with no authority line refused" bash -c '. "$0"; ! authority_problem "$1" "$2" >/dev/null' "$HERE/package-lib.sh" "TeamIdentifier=x" "$HASH"

# The control for the text authority_problem reads: signing_info must show a real signature's
# Authority= lines. `codesign -dv` shows none (it needs -dvv), so a --sign build was refused even
# when the identity had signed it. Calculator is signed by Apple, through to Apple Root CA.
check "control: signing_info shows a signed app's Authority= lines" \
    authority_problem "$(signing_info /System/Applications/Calculator.app)" "Apple Root CA"

if [ "$FAILS" -ne 0 ]; then
    echo "selftest: $FAILS failed"
    exit 1
fi
echo "selftest: all passed"
