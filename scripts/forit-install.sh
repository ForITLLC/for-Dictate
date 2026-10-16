#!/bin/bash
# scripts/forit-install.sh <ForIT-Dictate-*.dmg>: install a ForIT Dictate release DMG into /Applications on
# this Mac, after checking that it is ForIT's Developer ID build and that Apple notarized it.
# The DMG comes from the forit-release workflow's artifact; a .sha256 beside it is checked when present.
set -euo pipefail

DMG=${1:?usage: scripts/forit-install.sh <ForIT-Dictate-<version>-<build>.dmg>}
APP_NAME="ForIT Dictate"
BUNDLE_ID=io.forit.dictate
TEAM_ID=UUSSWWML2A
DEST="/Applications/$APP_NAME.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

fail() { echo "forit-install: $*" >&2; exit 1; }
[[ -f $DMG ]] || fail "no such DMG: $DMG"
if [[ -f $DMG.sha256 ]]; then
  (cd "$(dirname "$DMG")" && shasum -a 256 -c "$(basename "$DMG").sha256" >/dev/null) || fail "sha256 does not match"
  echo "sha256 ok"
fi

codesign --verify --strict "$DMG" || fail "DMG signature is not valid"
spctl -a -t open --context context:primary-signature "$DMG" 2>/dev/null || fail "Gatekeeper rejects the DMG"

MOUNT=$(mktemp -d)
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
SRC="$MOUNT/$APP_NAME.app"
[[ -d $SRC ]] || fail "$APP_NAME.app is not in the DMG"

codesign --verify --deep --strict "$SRC" || fail "app signature is not valid"
SIG=$(codesign -dvv "$SRC" 2>&1)
grep -q "^Identifier=$BUNDLE_ID$" <<<"$SIG" || fail "app identifier is not $BUNDLE_ID"
grep -q "^TeamIdentifier=$TEAM_ID$" <<<"$SIG" || fail "app is not signed by team $TEAM_ID"
spctl -a -t execute "$SRC" 2>/dev/null || fail "Gatekeeper rejects the app (not notarized?)"
xcrun stapler validate -q "$SRC" 2>/dev/null || echo "note: no stapled ticket; Gatekeeper checked online"

# Quit a running copy, then replace by a fresh copy: macOS kills a signed binary rewritten in place.
if pgrep -f "$DEST/Contents/MacOS/" >/dev/null; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 20); do pgrep -f "$DEST/Contents/MacOS/" >/dev/null || break; sleep 0.5; done
  pkill -f "$DEST/Contents/MacOS/" 2>/dev/null || true
fi
rm -rf "$DEST.new"
ditto "$SRC" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
"$LSREG" -f "$DEST"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$DEST/Contents/Info.plist")
echo "installed $DEST $VERSION ($BUILD), team $TEAM_ID, notarized"
if [[ ${FORIT_NO_LAUNCH:-0} != 1 ]]; then
  open "$DEST"
  for _ in $(seq 20); do pgrep -f "$DEST/Contents/MacOS/" >/dev/null && break; sleep 0.5; done
  pgrep -f "$DEST/Contents/MacOS/" >/dev/null && echo "running (pid $(pgrep -f "$DEST/Contents/MacOS/" | head -1))" \
    || fail "$APP_NAME did not start"
fi
