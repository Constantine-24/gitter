#!/bin/bash
# Helpers shared by package.sh and package-selftest.sh. Sourced, never run.

# dump_symbols <file> / dump_strings <file>: the text a scan searches. Each is captured to a
# variable by the caller first, so `grep -q` can never SIGPIPE a producer under pipefail.
dump_symbols() { nm -gU "$1" 2>/dev/null || true; }
dump_strings() { strings - "$1" 2>/dev/null || true; }

# text_has <text> <name>: succeeds if the name is in the text (a here-string, no pipe).
text_has() { grep -qF -- "$2" <<<"$1"; }

# binary_has <symbols|strings> <file> <name>
binary_has() {
    local text
    case "$1" in
        symbols) text="$(dump_symbols "$2")" ;;
        strings) text="$(dump_strings "$2")" ;;
        *) return 2 ;;
    esac
    text_has "$text" "$3"
}

# signing_info <app>: codesign's description of a signature, the text authority_problem reads.
# -dvv, not -dv: only the second level of detail lists the Authority= lines.
signing_info() { codesign -dvv "$1" 2>&1; }

# authority_problem <codesign -dvv text> <identity>: prints what was expected and what was found and
# returns 1 if the signature does not match the identity; returns 0 when it does.
# A 40-hex identity is a SHA-1: the signature must be non-adhoc with an Authority= line (the
# common name is not in the hash). Any other identity must be an Authority= line, exactly.
authority_problem() {
    local info="$1" id="$2" auths
    auths="$(grep '^Authority=' <<<"$info" || true)"
    if [[ "$id" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        if grep -q '^Signature=adhoc' <<<"$info"; then
            echo "expected a non-adhoc signature for identity hash $id, found Signature=adhoc"
            return 1
        fi
        if [ -z "$auths" ]; then
            echo "expected an Authority= line for identity hash $id, found none"
            return 1
        fi
        return 0
    fi
    if ! grep -qxF "Authority=$id" <<<"$info"; then
        echo "expected Authority=$id, found: ${auths:-no Authority= line}"
        return 1
    fi
    return 0
}
