#!/bin/bash
# Selftest for package.sh's refusals. None of these cases builds.
#
#   bash scripts/package-selftest.sh
#
# Runs this working tree's package.sh against a scratch `git clone --no-hardlinks` of the
# repository (GITTER_PACKAGE_ROOT), so it works before anything is committed. Checks each
# refusal by exit status and first stderr line. The scratch folder is removed on exit.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap '/bin/rm -rf "$SCRATCH"' EXIT

export GIT_ALLOW_PROTOCOL=file GIT_SSH_COMMAND=/usr/bin/false GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset SSH_AUTH_SOCK
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
    GITTER_PACKAGE_ROOT="$CLONE" bash "$HERE/package.sh" "$@" >/dev/null 2>"$err" || code=$?
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

expect "--notarize" 2 "package.sh: --notarize is not set up yet: it needs a Developer ID" -- --notarize
expect "--bogus" 2 "$USAGE" -- --bogus
expect "--sign with no value" 2 "" -- --sign
expect "--sign with an empty value" 2 "" -- --sign ""

touch "$CLONE/untracked-file"
expect "untracked file" 2 "package.sh: the tree is not clean" --
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

# The Authority matching, on captured codesign -dv text (no codesign, no identity involved).
ADHOC=$'Signature=adhoc\nTeamIdentifier=not set'
SIGNED=$'Authority=My Cert\nTeamIdentifier=not set'
HASH=0123456789abcdef0123456789abcdef01234567
check "authority: name matches exactly" authority_problem "$SIGNED" "My Cert"
check "authority: other name refused" bash -c '. "$0"; ! authority_problem "$1" "Other" >/dev/null' "$HERE/package-lib.sh" "$SIGNED"
check "authority: name must be whole line" bash -c '. "$0"; ! authority_problem "$1" "My" >/dev/null' "$HERE/package-lib.sh" "$SIGNED"
check "authority: hash with an authority passes" authority_problem "$SIGNED" "$HASH"
check "authority: hash with adhoc refused" bash -c '. "$0"; ! authority_problem "$1" "$2" >/dev/null' "$HERE/package-lib.sh" "$ADHOC" "$HASH"
check "authority: hash with no authority line refused" bash -c '. "$0"; ! authority_problem "$1" "$2" >/dev/null' "$HERE/package-lib.sh" "TeamIdentifier=x" "$HASH"

if [ "$FAILS" -ne 0 ]; then
    echo "selftest: $FAILS failed"
    exit 1
fi
echo "selftest: all passed"
