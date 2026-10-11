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

if [ "$FAILS" -ne 0 ]; then
    echo "selftest: $FAILS failed"
    exit 1
fi
echo "selftest: all passed"
