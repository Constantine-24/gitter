#!/bin/bash
# Turns a clean tree into an arm64 Release DMG with its build number and commit stamped in.
#
#   bash scripts/package.sh [--sign "<identity>"] [--notarize "<keychain-profile>"]
#
# Without --sign the app stays ad-hoc signed, as the build leaves it. With --sign the built app
# is re-signed with that identity (hardened runtime, the built entitlements kept). The script never
# creates, imports or reads keys; the identity is the user's.
# --notarize needs --sign with a Developer ID Application identity (its name, or its 40-hex SHA-1)
# and the name of a notarytool keychain profile the user stored earlier with
# `xcrun notarytool store-credentials`. The signatures are then timestamped, the app is submitted
# to Apple's notary service and stapled before it goes into the DMG, and the DMG is submitted and
# stapled too. Without --notarize the signatures carry no timestamp and nothing leaves the machine.
# Every build refuses an app that carries com.apple.security.get-task-allow.
# GITTER_DIST_DIR, if set, also receives a copy of the DMG; it must be an absolute path, as the
# script works from the repository, not the caller's folder. GITTER_PACKAGE_ROOT overrides the
# repository to package (the selftest uses it); by default it is this script's own.
#
# Exit codes: 2 refused before building, 3 a check on the built app or DMG failed, 1 anything else
# (a tool that failed, whatever its own status: the ERR trap below; -E carries it into functions
# and command substitutions).
set -Eeuo pipefail
trap 'exit 1' ERR

ROOT="${GITTER_PACKAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$(dirname "${BASH_SOURCE[0]}")/package-lib.sh"
USAGE='package.sh: usage: bash scripts/package.sh [--sign "<identity>"] [--notarize "<keychain-profile>"]'

refuse() { echo "package.sh: $1" >&2; exit 2; }
check_failed() { echo "package.sh: check failed: $1" >&2; exit 3; }

# notarize_file <path> <what>: submits the file to Apple's notary service and waits. Anything but
# Accepted prints the service's log for the submission and fails the run (exit 3). stdin is
# /dev/null so the tool can never wait on a prompt.
notarize_file() {
    local path="$1" what="$2" out="" status id
    out="$(xcrun notarytool submit "$path" --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout 1h --output-format json </dev/null)" || true
    status="$(notary_field "$out" status || true)"
    id="$(notary_field "$out" id || true)"
    if [ "$status" != "Accepted" ]; then
        [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" </dev/null || true
        check_failed "notarization of $what: ${status:-notarytool gave no readable answer${out:+ (it printed: $out)}}"
    fi
    echo "notarized $what: Accepted ($id)"
}

# 1. Arguments and GITTER_DIST_DIR first, then the tree.
IDENTITY=""
NOTARY_PROFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --notarize)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                refuse "--notarize needs a keychain profile"
            fi
            NOTARY_PROFILE="$2"; shift 2 ;;
        --sign)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "package.sh: --sign needs an identity" >&2
                echo "$USAGE" >&2
                exit 2
            fi
            IDENTITY="$2"; shift 2 ;;
        *)
            echo "$USAGE" >&2
            exit 2 ;;
    esac
done

if [ -n "$NOTARY_PROFILE" ]; then
    [ -n "$IDENTITY" ] || refuse "--notarize needs --sign with a Developer ID Application identity"
    case "$IDENTITY" in
        "Developer ID Application: "*) ;;
        *)
            [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] \
                || refuse "--notarize needs a Developer ID Application identity, not $IDENTITY" ;;
    esac
fi

if [ -n "${GITTER_DIST_DIR:-}" ]; then
    case "$GITTER_DIST_DIR" in
        /*) ;;
        *) refuse "GITTER_DIST_DIR must be an absolute path, not $GITTER_DIST_DIR" ;;
    esac
fi

cd "$ROOT"
# Its own statement, so a git that fails stops the script (exit 1) rather than reading as clean;
# --untracked-files=all, so the user's status.showUntrackedFiles cannot hide a new file.
TREE_STATUS="$(git -C "$ROOT" status --porcelain --untracked-files=all)"
[ -z "$TREE_STATUS" ] || refuse "the tree is not clean"

# 2. Version, build, commit.
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -n 1)"
[ -n "$VERSION" ] || { echo "package.sh: no MARKETING_VERSION in project.yml" >&2; exit 1; }

DIST="$ROOT/dist"
DERIVED="$DIST/DerivedData"
APP="$DERIVED/Build/Products/Release/Gitter.app"
DMG_NAME="Gitter-$VERSION-$BUILD.dmg"
DMG="$DIST/$DMG_NAME"
mkdir -p "$DIST"

SCRATCH="$(mktemp -d)"
MNT="$SCRATCH/mnt"
MOUNTED=0
cleanup() {
    if [ "$MOUNTED" = 1 ]; then
        hdiutil detach "$MNT" -force >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$SCRATCH"
}
trap cleanup EXIT

# 3. Build.
# The selftest sets this so a regressed refusal fails fast (exit 99) instead of building.
if [ -n "${GITTER_PACKAGE_NO_BUILD:-}" ]; then
    echo "package.sh: reached the build with GITTER_PACKAGE_NO_BUILD set" >&2
    exit 99
fi
command -v xcodegen >/dev/null 2>&1 || refuse "xcodegen is not installed (brew install xcodegen)"
xcodegen generate
xcodebuild -project Gitter.xcodeproj -scheme Gitter -configuration Release \
    -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CURRENT_PROJECT_VERSION="$BUILD" GITTER_COMMIT="$COMMIT" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO clean build
[ -d "$APP" ] || { echo "package.sh: the build left no $APP" >&2; exit 1; }

# 4. Re-sign with the given identity, keeping the built entitlements.
TIMESTAMP_FLAG="--timestamp=none"
[ -z "$NOTARY_PROFILE" ] || TIMESTAMP_FLAG="--timestamp"
if [ -n "$IDENTITY" ]; then
    ENTITLEMENTS="$SCRATCH/entitlements.plist"
    codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS" 2>/dev/null || true
    [ -s "$ENTITLEMENTS" ] || check_failed "the built app has no entitlements to keep; not re-signing"
    codesign --force --options runtime "$TIMESTAMP_FLAG" \
        --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi

# 5. Checks on the built app.
codesign --verify --strict --deep "$APP" 2>&1 \
    || check_failed "codesign --verify --strict --deep"
SIGINFO="$(signing_info "$APP")"
echo "$SIGINFO" | grep -q 'flags=.*runtime' \
    || check_failed "the hardened runtime flag is missing from codesign -dvv"
if [ -n "$IDENTITY" ]; then
    PROBLEM="$(authority_problem "$SIGINFO" "$IDENTITY")" || check_failed "$PROBLEM"
    echo "$SIGINFO" | grep '^Authority=' | sed 's/^/signed by: /'
    SHOWN_IDENTITY="$IDENTITY"
else
    echo "$SIGINFO" | grep -q '^Signature=adhoc' \
        || check_failed "codesign -dvv shows no Signature=adhoc"
    SHOWN_IDENTITY="ad-hoc"
fi

EXECUTABLE="$APP/Contents/MacOS/Gitter"
[ "$(lipo -archs "$EXECUTABLE")" = "arm64" ] \
    || check_failed "lipo -archs is not arm64: $(lipo -archs "$EXECUTABLE")"

PLIST="$APP/Contents/Info.plist"
plist_read() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo "<missing>"; }
[ "$(plist_read CFBundleShortVersionString)" = "$VERSION" ] \
    || check_failed "CFBundleShortVersionString is $(plist_read CFBundleShortVersionString), not $VERSION"
[ "$(plist_read CFBundleVersion)" = "$BUILD" ] \
    || check_failed "CFBundleVersion is $(plist_read CFBundleVersion), not $BUILD"
[ "$(plist_read GitterCommit)" = "$COMMIT" ] \
    || check_failed "GitterCommit is $(plist_read GitterCommit), not $COMMIT"

# xcodebuild injects get-task-allow into a build unless told not to; the re-sign keeps whatever
# the build holds, so check what the app really carries.
APP_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
[ -n "$APP_ENTITLEMENTS" ] || check_failed "codesign could not read the built app's entitlements"
PROBLEM="$(entitlements_problem "$APP_ENTITLEMENTS")" || check_failed "$PROBLEM"
if [ -n "$NOTARY_PROFILE" ]; then
    PROBLEM="$(developer_id_problem "$SIGINFO")" || check_failed "$PROBLEM"
fi

# The Release must hold none of the DEBUG harness. Every Mach-O file under Contents/MacOS is
# scanned, so a Debug-style split into a .debug.dylib could not hide a name.
SCANNED=0
while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    SCANNED=$((SCANNED + 1))
    SYMS="$(dump_symbols "$f")"
    STRS="$(dump_strings "$f")"
    # Control: the same scan must FIND names known to be present, or it proves nothing.
    text_has "$SYMS" "__mh_execute_header" || [ "$(basename "$f")" != "Gitter" ] \
        || check_failed "scan control: nm -gU found no __mh_execute_header in $(basename "$f")"
    text_has "$STRS" "NSApplication" || [ "$(basename "$f")" != "Gitter" ] \
        || check_failed "scan control: strings found no NSApplication in $(basename "$f")"
    for name in GitCoreTestSupport DebugLaunchHooks closewindow; do
        ! text_has "$SYMS" "$name" || check_failed "$(basename "$f") exports a symbol with $name (nm -gU)"
    done
    for name in GITTER_LOG_DIR quitevent closewindow; do
        ! text_has "$STRS" "$name" || check_failed "$(basename "$f") holds the string $name (strings)"
    done
    echo "scan control ok: $(basename "$f") has __mh_execute_header (nm) and NSApplication (strings); none of the Release gate's names"
done < <(find "$APP/Contents/MacOS" -type f -print0)
[ "$SCANNED" -ge 1 ] || check_failed "no Mach-O file found to scan under Contents/MacOS"

# 5b. Notarize and staple the app, so the DMG is staged from the stapled copy.
if [ -n "$NOTARY_PROFILE" ]; then
    ditto -c -k --keepParent "$APP" "$SCRATCH/Gitter.zip"
    notarize_file "$SCRATCH/Gitter.zip" "Gitter.app"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    codesign --verify --strict --deep "$APP" 2>&1 \
        || check_failed "codesign --verify --strict --deep after stapling"
    SPCTL_APP="$(spctl --assess --type execute -vv "$APP" 2>&1 || true)"
    echo "$SPCTL_APP" | sed 's/^/  /'
    text_has "$SPCTL_APP" "accepted" && text_has "$SPCTL_APP" "source=Notarized Developer ID" \
        || check_failed "spctl does not accept the app as Notarized Developer ID"
fi

# 6. The DMG.
STAGE="$SCRATCH/stage"
mkdir -p "$STAGE"
/bin/cp -R "$APP" "$STAGE/Gitter.app"
ln -s /Applications "$STAGE/Applications"
REPLACED=0
[ ! -e "$DMG" ] || REPLACED=1
PARTIAL="$DIST/.partial-$DMG_NAME"
/bin/rm -f "$PARTIAL"
trap 'cleanup; /bin/rm -f "$PARTIAL"' EXIT
hdiutil create -volname "Gitter $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$PARTIAL"
hdiutil verify "$PARTIAL" || check_failed "hdiutil verify"
mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$PARTIAL" >/dev/null \
    || check_failed "hdiutil attach"
MOUNTED=1
[ -d "$MNT/Gitter.app" ] || check_failed "the mounted DMG holds no Gitter.app"
[ -L "$MNT/Applications" ] || check_failed "the mounted DMG holds no Applications link"
hdiutil detach "$MNT" >/dev/null || check_failed "hdiutil detach"
MOUNTED=0
if [ -n "$NOTARY_PROFILE" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$PARTIAL"
    notarize_file "$PARTIAL" "$DMG_NAME"
    xcrun stapler staple "$PARTIAL"
    xcrun stapler validate "$PARTIAL"
    SPCTL_DMG="$(spctl --assess --type open --context context:primary-signature -vv "$PARTIAL" 2>&1 || true)"
    echo "$SPCTL_DMG" | sed 's/^/  /'
    text_has "$SPCTL_DMG" "accepted" || check_failed "spctl does not accept the DMG"
fi
[ "$REPLACED" = 0 ] || echo "replaced dist/$DMG_NAME"
mv -f "$PARTIAL" "$DMG"

# 7. Copy to GITTER_DIST_DIR.
COPIED=""
if [ -n "${GITTER_DIST_DIR:-}" ]; then
    mkdir -p "$GITTER_DIST_DIR"
    if [ -e "$GITTER_DIST_DIR/$DMG_NAME" ]; then
        echo "replaced $GITTER_DIST_DIR/$DMG_NAME"
    fi
    TMPCOPY="$GITTER_DIST_DIR/.$DMG_NAME.copying"
    trap 'cleanup; /bin/rm -f "$PARTIAL" "$TMPCOPY"' EXIT
    /bin/cp -f "$DMG" "$TMPCOPY"
    mv -f "$TMPCOPY" "$GITTER_DIST_DIR/$DMG_NAME"
    COPIED="$GITTER_DIST_DIR/$DMG_NAME"
fi

# 8. Summary.
echo "dmg:      $DMG"
[ -z "$COPIED" ] || echo "copied:   $COPIED"
echo "sha256:   $(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
echo "version:  $VERSION"
echo "build:    $BUILD"
echo "commit:   $COMMIT"
echo "identity: $SHOWN_IDENTITY"
if [ -n "$NOTARY_PROFILE" ]; then
    echo "notarized: yes"
else
    SPCTL="$(spctl --assess --type execute -vv "$APP" 2>&1 || true)"
    echo "spctl (informational: an app that is not notarized is rejected):"
    echo "$SPCTL" | sed 's/^/  /'
fi
