#!/bin/bash
# scripts/forit-install.sh <ForIT-Dictate-*.dmg>: install a ForIT Dictate release DMG into /Applications on
# this Mac, after checking its mandatory checksum, Developer ID signatures and Apple tickets.
# The MacBook owner supplies a closed-app opportunity; this script never quits or launches the app.
set -euo pipefail

DMG=${1:?usage: scripts/forit-install.sh <ForIT-Dictate-<version>-<build>.dmg>}
APP_NAME="ForIT Dictate"
BUNDLE_ID=io.forit.dictate
TEAM_ID=UUSSWWML2A
SIGNING_AUTHORITY='Developer ID Application: ForIT Limited Liability Company (UUSSWWML2A)'
APP_EXECUTABLE=VoiceInk
DEST="/Applications/$APP_NAME.app"
PLISTBUDDY=/usr/libexec/PlistBuddy
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
export LC_ALL=C

fail() { echo "forit-install: $*" >&2; exit 1; }
[[ $# == 1 ]] || fail "supply exactly one release DMG"
[[ -f $DMG && ! -L $DMG ]] || fail "DMG must be a regular file, not a symlink"
DMG=$(cd "$(dirname "$DMG")" && printf '%s/%s' "$PWD" "$(basename "$DMG")")
DMG_NAME=$(basename "$DMG")
[[ $DMG_NAME != *$'\n'* && $DMG_NAME != *$'\r'* ]] || fail "ambiguous DMG filename"
CHECKSUM="$DMG.sha256"
[[ -f $CHECKSUM && ! -L $CHECKSUM ]] || fail "the adjacent .sha256 file is required"
CHECKSUM_BYTES=$(wc -c < "$CHECKSUM")
(( CHECKSUM_BYTES <= 67 + ${#DMG_NAME} )) || fail "checksum must contain exactly one record"
CHECKSUM_RECORD=""
IFS= read -r CHECKSUM_RECORD < "$CHECKSUM" || [[ -n $CHECKSUM_RECORD ]] || fail "empty checksum file"
# Compare the original bytes as well: reject extra lines, CRLF, NULs or other
# data hidden by shell parsing. Accept a single record with or without its final LF.
if ! printf '%s\n' "$CHECKSUM_RECORD" | cmp -s - "$CHECKSUM"; then
  printf '%s' "$CHECKSUM_RECORD" | cmp -s - "$CHECKSUM" || fail "checksum must contain exactly one record"
fi
EXPECTED_SHA=${CHECKSUM_RECORD%% *}
[[ $EXPECTED_SHA =~ ^[0-9a-f]{64}$ ]] || fail "checksum must be a SHA-256 hex digest"
[[ $CHECKSUM_RECORD == "$EXPECTED_SHA  $DMG_NAME" ]] || fail "checksum must name this exact DMG basename"
ACTUAL_RECORD=$(shasum -a 256 "$DMG") || fail "could not hash the DMG"
[[ ${ACTUAL_RECORD%% *} == "$EXPECTED_SHA" ]] || fail "sha256 does not match"

require_closed_app() {
  local status
  if pgrep -x "$APP_EXECUTABLE" >/dev/null 2>&1; then
    fail "close ForIT Dictate after saving pending work, then run the installer again"
  else
    status=$?
    [[ $status == 1 ]] || fail "could not determine whether ForIT Dictate is running"
  fi
}
require_destination() {
  [[ -d $(dirname "$DEST") && ! -L $(dirname "$DEST") ]] || fail "application destination parent is not a regular directory"
  [[ ! -L $DEST && ( ! -e $DEST || -d $DEST ) ]] || fail "application destination is ambiguous or symlinked"
}
verify_team() {
  local signature
  signature=$(codesign -dvv "$1" 2>&1) || fail "could not read the signing identity"
  grep -Fxq "TeamIdentifier=$TEAM_ID" <<<"$signature" || fail "signature is not from ForIT team $TEAM_ID"
  grep -Fxq "Authority=$SIGNING_AUTHORITY" <<<"$signature" || fail "signature is not ForIT's Developer ID Application identity"
}
verify_app() {
  local signature info="$1/Contents/Info.plist"
  [[ -d $1 && ! -L $1 ]] || fail "release app is absent or symlinked"
  codesign --verify --deep --strict "$1" || fail "app signature is not valid"
  verify_team "$1"
  signature=$(codesign -dvv "$1" 2>&1) || fail "could not read the app identifier"
  grep -Fxq "Identifier=$BUNDLE_ID" <<<"$signature" || fail "app identifier is not $BUNDLE_ID"
  [[ $("$PLISTBUDDY" -c 'Print CFBundleIdentifier' "$info") == "$BUNDLE_ID" ]] || fail "app bundle identifier does not match"
  [[ $("$PLISTBUDDY" -c 'Print CFBundleExecutable' "$info") == "$APP_EXECUTABLE" ]] || fail "app executable does not match"
  xcrun stapler validate -q "$1" || fail "app does not have a valid stapled Apple ticket"
  spctl -a -t execute "$1" || fail "Gatekeeper rejects the app"
}

require_destination
require_closed_app
codesign --verify --strict "$DMG" || fail "DMG signature is not valid"
verify_team "$DMG"
xcrun stapler validate -q "$DMG" || fail "DMG does not have a valid stapled Apple ticket"
spctl -a -t open --context context:primary-signature "$DMG" || fail "Gatekeeper rejects the DMG"

MOUNT=""
STAGE=""
BACKUP=""
INSTALLED=0
COMMITTED=0
cleanup() {
  local result=$? keep_stage=0
  trap - EXIT
  if [[ $COMMITTED == 0 && $INSTALLED == 1 ]]; then
    # Keep a failed installed copy in our own stage, never in the user's app slot.
    keep_stage=1
    if [[ ! -L $DEST && -d $DEST ]] && mv "$DEST" "$STAGE/rejected.app"; then
      INSTALLED=0
    else
      echo "forit-install: could not move the rejected app; retained $DEST" >&2
      result=1
    fi
  fi
  if [[ $COMMITTED == 0 && -n $BACKUP && -d $BACKUP && ! -L $BACKUP ]]; then
    # If restoration fails, leave the entire owned stage intact for the owner.
    if [[ ! -e $DEST && ! -L $DEST ]] && mv "$BACKUP" "$DEST"; then
      echo "forit-install: restored the previous app" >&2
    else
      keep_stage=1
      echo "forit-install: rollback incomplete; previous app retained at $BACKUP" >&2
      result=1
    fi
  fi
  if [[ -n $MOUNT ]]; then
    hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
    if ! rmdir "$MOUNT" 2>/dev/null; then
      echo "forit-install: mount cleanup incomplete; retained $MOUNT" >&2
      result=1
    fi
  fi
  if [[ -n $STAGE ]]; then
    if [[ -n $BACKUP && -d $BACKUP ]]; then keep_stage=1; fi
    if [[ $keep_stage == 0 ]]; then
      rm -rf "$STAGE"
    else
      echo "forit-install: retained installation evidence at $STAGE" >&2
    fi
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

MOUNT=$(mktemp -d)
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
SRC="$MOUNT/$APP_NAME.app"
verify_app "$SRC"
VERSION=$("$PLISTBUDDY" -c 'Print CFBundleShortVersionString' "$SRC/Contents/Info.plist") || fail "could not read release version"
BUILD=$("$PLISTBUDDY" -c 'Print CFBundleVersion' "$SRC/Contents/Info.plist") || fail "could not read release build"
[[ $VERSION =~ ^[0-9]+(\.[0-9]+){0,2}$ && $BUILD =~ ^[1-9][0-9]*$ ]] || fail "invalid release version or build"

STAGE=$(mktemp -d "$(dirname "$DEST")/.forit-dictate-install.XXXXXX")
STAGED_APP="$STAGE/$APP_NAME.app"
ditto "$SRC" "$STAGED_APP" || fail "could not stage the new app"
verify_app "$STAGED_APP"
require_destination
require_closed_app
BACKUP="$STAGE/previous.app"
if [[ -e $DEST ]]; then
  mv "$DEST" "$BACKUP" || fail "could not preserve the previous app"
fi
mv "$STAGED_APP" "$DEST" || fail "could not install the staged app"
INSTALLED=1
verify_app "$DEST"
"$LSREG" -f "$DEST" || fail "could not register the installed app"
COMMITTED=1
echo "installed $DEST $VERSION ($BUILD), team $TEAM_ID, notarized; app remains closed"
