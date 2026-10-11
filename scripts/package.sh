#!/bin/bash
# Turns a clean tree into an arm64 Release DMG with its build number and commit stamped in.
#
#   bash scripts/package.sh [--sign "<identity>"]
#
# Without --sign the app stays ad-hoc signed, as the build leaves it. With --sign the built app
# is re-signed with that identity (hardened runtime, the built entitlements kept). The script never
# creates, imports or reads keys; the identity is the user's.
# GITTER_DIST_DIR, if set, also receives a copy of the DMG. GITTER_PACKAGE_ROOT overrides the
# repository to package (the selftest uses it); by default it is this script's own.
#
# Exit codes: 2 refused before building, 3 a check on the built app or DMG failed, 1 anything else.
set -euo pipefail

ROOT="${GITTER_PACKAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
USAGE='package.sh: usage: bash scripts/package.sh [--sign "<identity>"]'

refuse() { echo "package.sh: $1" >&2; exit 2; }
check_failed() { echo "package.sh: check failed: $1" >&2; exit 3; }

# 1. Arguments first, then the tree.
IDENTITY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --notarize)
            refuse "--notarize is not set up yet: it needs a Developer ID" ;;
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

cd "$ROOT"
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    refuse "the tree is not clean"
fi

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
xcodegen generate
xcodebuild -project Gitter.xcodeproj -scheme Gitter -configuration Release \
    -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CURRENT_PROJECT_VERSION="$BUILD" GITTER_COMMIT="$COMMIT" clean build
[ -d "$APP" ] || { echo "package.sh: the build left no $APP" >&2; exit 1; }

# 4. Re-sign with the given identity, keeping the built entitlements.
if [ -n "$IDENTITY" ]; then
    ENTITLEMENTS="$SCRATCH/entitlements.plist"
    codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS" 2>/dev/null
    codesign --force --options runtime --timestamp=none \
        --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi

# 5. Checks on the built app.
codesign --verify --strict --deep "$APP" 2>&1 \
    || check_failed "codesign --verify --strict --deep"
SIGINFO="$(codesign -dv "$APP" 2>&1)"
echo "$SIGINFO" | grep -q 'flags=.*runtime' \
    || check_failed "the hardened runtime flag is missing from codesign -dv"
if [ -n "$IDENTITY" ]; then
    echo "$SIGINFO" | grep -qxF "Authority=$IDENTITY" \
        || check_failed "codesign -dv shows no Authority=$IDENTITY"
    SHOWN_IDENTITY="$IDENTITY"
else
    echo "$SIGINFO" | grep -q '^Signature=adhoc' \
        || check_failed "codesign -dv shows no Signature=adhoc"
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

# The Release must hold none of the DEBUG harness. Every Mach-O file under Contents/MacOS is
# scanned, so a Debug-style split into a .debug.dylib could not hide a name.
SCANNED=0
while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    SCANNED=$((SCANNED + 1))
    for name in GitCoreTestSupport DebugLaunchHooks closewindow; do
        if nm -gU "$f" 2>/dev/null | grep -qF "$name"; then
            check_failed "$(basename "$f") exports a symbol with $name (nm -gU)"
        fi
    done
    for name in GITTER_LOG_DIR quitevent closewindow; do
        if strings - "$f" | grep -qF "$name"; then
            check_failed "$(basename "$f") holds the string $name (strings)"
        fi
    done
done < <(find "$APP/Contents/MacOS" -type f -print0)
[ "$SCANNED" -ge 1 ] || check_failed "no Mach-O file found to scan under Contents/MacOS"

# 6. The DMG.
STAGE="$SCRATCH/stage"
mkdir -p "$STAGE"
/bin/cp -R "$APP" "$STAGE/Gitter.app"
ln -s /Applications "$STAGE/Applications"
if [ -e "$DMG" ]; then
    echo "replaced dist/$DMG_NAME"
fi
hdiutil create -volname "Gitter $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify "$DMG" || check_failed "hdiutil verify"
mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$DMG" >/dev/null \
    || check_failed "hdiutil attach"
MOUNTED=1
[ -d "$MNT/Gitter.app" ] || check_failed "the mounted DMG holds no Gitter.app"
[ -L "$MNT/Applications" ] || check_failed "the mounted DMG holds no Applications link"
hdiutil detach "$MNT" >/dev/null || check_failed "hdiutil detach"
MOUNTED=0

# 7. Copy to GITTER_DIST_DIR.
COPIED=""
if [ -n "${GITTER_DIST_DIR:-}" ]; then
    mkdir -p "$GITTER_DIST_DIR"
    if [ -e "$GITTER_DIST_DIR/$DMG_NAME" ]; then
        echo "replaced $GITTER_DIST_DIR/$DMG_NAME"
    fi
    /bin/cp -f "$DMG" "$GITTER_DIST_DIR/$DMG_NAME"
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
SPCTL="$(spctl --assess --type execute -vv "$APP" 2>&1 || true)"
echo "spctl (informational: an app that is not notarized is rejected):"
echo "$SPCTL" | sed 's/^/  /'
