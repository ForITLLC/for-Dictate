#!/bin/bash
# scripts/forit-release.sh: build, sign, notarize and package ForIT Dictate as a Developer ID DMG.
#
# ForIT Dictate is ForIT's build of VoiceInk (GPLv3). This script is part of its Corresponding Source: it is
# the whole of how a shipped build is made from this repository. It runs on the Mac mini's GitHub runner
# (.github/workflows/forit-release.yml) and on any Mac that has the identity and notary key below.
#
# Inputs (environment):
#   FORIT_CODESIGN_IDENTITY  SHA-1 of the "Developer ID Application: ForIT Limited Liability Company" identity
#   FORIT_CODESIGN_KEYCHAIN  keychain that holds it (unlocked)
#   NOTARY_KEY               path to the App Store Connect API key (.p8) used by notarytool
#   NOTARY_KEY_ID, NOTARY_ISSUER
#   FORIT_SKIP_NOTARIZE=1    sign only (a local trial build; never shipped)
#   FORIT_XCODEBUILD         xcodebuild to use. Defaults to the normal Xcode command.
# Output: build/forit-release/ with ForIT-Dictate-<version>-<build>.dmg, its .sha256, notary receipts and
# SOURCE.txt naming the public commit the build came from.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

APP_NAME="ForIT Dictate"
BUNDLE_ID=io.forit.dictate
TEAM_ID=UUSSWWML2A
PUBLIC_REPO=https://github.com/ForITLLC/for-Dictate
VERSION=$(tr -d '[:space:]' < forit/VERSION)
BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse HEAD)
OUT="$REPO_ROOT/build/forit-release"
DERIVED="$REPO_ROOT/build/forit-dd"
ENTITLEMENTS="$REPO_ROOT/VoiceInk/VoiceInk.entitlements"
BASENAME="ForIT-Dictate-$VERSION-$BUILD"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'forit-release: %s\n' "$*" >&2; exit 1; }

[[ -n $VERSION ]] || fail "forit/VERSION is empty"
[[ -z $(git status --porcelain --untracked-files=no) ]] || fail "tracked files are modified; a shipped build must match a commit"

# --- The owning lane workflow runs Xcode directly; retired admission/slot gates are not release checks. ---
# Keep explicit compiler selection and the existing execution deadlines without changing runner-global files.
FORIT_XCODEBUILD=${FORIT_XCODEBUILD:-$(/usr/bin/xcrun --find xcodebuild)}
export FORIT_XCODEBUILD
log "xcodebuild: $FORIT_XCODEBUILD"

if [[ ${FORIT_SKIP_NOTARIZE:-0} != 1 ]]; then
  for v in FORIT_CODESIGN_IDENTITY FORIT_CODESIGN_KEYCHAIN NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER; do
    [[ -n ${!v:-} ]] || fail "$v is not set"
  done
  [[ -f $NOTARY_KEY ]] || fail "NOTARY_KEY does not exist"
else
  for v in FORIT_CODESIGN_IDENTITY FORIT_CODESIGN_KEYCHAIN; do
    [[ -n ${!v:-} ]] || fail "$v is not set"
  done
fi
security find-identity -v -p codesigning "$FORIT_CODESIGN_KEYCHAIN" | grep -q "$FORIT_CODESIGN_IDENTITY" \
  || fail "identity $FORIT_CODESIGN_IDENTITY is not in $FORIT_CODESIGN_KEYCHAIN"

rm -rf "$OUT" "$DERIVED"
mkdir -p "$OUT"

# --- whisper.cpp ---
scripts/forit-whisper.sh

# --- xcodebuild with a deadline. ---
# xcodebuild_within <minutes> <log> <args...> runs "$FORIT_XCODEBUILD" <args> into <log>. The clock runs only
# while Xcode's xcodebuild itself runs, not while the slot wrapper waits for a slot. Past the deadline it
# prints the process tree and any keychain prompt securityd raised (read-only, never an attach), stops the
# tree and returns 124, so a hung build fails the job instead of sitting until the workflow timeout.
descendants() {
  local p kids
  for p in "$@"; do
    echo "$p"
    kids=$(pgrep -P "$p" || true)
    [[ -z $kids ]] || descendants $kids
  done
}
xcodebuild_within() {
  local minutes=$1 logf=$2 pid pids ran=0; shift 2
  "$FORIT_XCODEBUILD" "$@" >"$logf" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 10
    pids=$(descendants "$pid" | paste -sd, -)
    if ps -o command= -p "$pids" 2>/dev/null | grep -E '/Contents/Developer/usr/bin/xcodebuild( |$)' >/dev/null; then
      ran=$((ran + 10))
    fi
    if (( ran >= minutes * 60 )); then
      echo "xcodebuild ran past its $minutes-minute deadline. Its processes:"
      ps -o pid,ppid,etime,stat,command -p "$pids" 2>/dev/null | cut -c1-240 || true
      echo "Keychain prompts securityd raised in that time:"
      /usr/bin/log show --last "$((minutes + 30))m" --style compact \
        --predicate 'process == "securityd" AND eventMessage CONTAINS "displaying keychain prompt"' 2>/dev/null \
        | cut -c1-240 | tail -5 || true
      pids=$(descendants "$pid")
      kill -TERM $pids 2>/dev/null || true
      sleep 10
      kill -KILL $pids 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
  done
  wait "$pid"
}

# Package lookups read credentials from netrc only. With the default keychain provider, xcodebuild reads the
# login keychain's github.com password while it fetches the packages' binary artifacts; that item trusts only
# git's credential helper, so macOS asks for access on the Mini's locked console, nobody answers, and the
# build waits until the job times out (runs 38953215094 and 39005809560). There is no ~/.netrc on the runner,
# so the public packages and artifacts download without credentials.
PKG_ARGS=(
  -project VoiceInk.xcodeproj
  -scheme VoiceInk
  -derivedDataPath "$DERIVED"
  -packageAuthorizationProvider netrc
)

log "Resolving Swift packages"
rc=0
xcodebuild_within 20 "$OUT/resolve.log" -resolvePackageDependencies "${PKG_ARGS[@]}" || rc=$?
grep -E '^(build-slot |error:|.*: error:)' "$OUT/resolve.log" || true
(( rc == 0 )) || fail "package resolution failed ($rc; see resolve.log)"
# Preserve genuine SDK resolution for release evidence; subsequent compilation must use it.
RESOLVED=VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
[[ -f $RESOLVED ]] || fail "SDK resolver did not leave the canonical Package.resolved"
cp "$RESOLVED" "$OUT/Package.resolved"
PKG_ARGS+=(-onlyUsePackageVersionsFromResolvedFile)

# --- Build, unsigned: signing happens below, inside-out, with the job keychain named explicitly. ---
log "Building $APP_NAME $VERSION ($BUILD) from $COMMIT"
rc=0
xcodebuild_within 90 "$OUT/xcodebuild.log" build \
  "${PKG_ARGS[@]}" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" || rc=$?
grep -E '^(build-slot |\*\* |error:|.*: error:|warning: .*deprecated)' "$OUT/xcodebuild.log" || true
(( rc != 124 )) || fail "xcodebuild ran past its deadline (see above and xcodebuild.log)"
grep -q '\*\* BUILD SUCCEEDED \*\*' "$OUT/xcodebuild.log" || fail "xcodebuild did not succeed (see xcodebuild.log)"

BUILT_APP="$DERIVED/Build/Products/Release/VoiceInk.app"
[[ -d $BUILT_APP ]] || fail "built app not found at $BUILT_APP"
APP="$OUT/$APP_NAME.app"
ditto "$BUILT_APP" "$APP"

INFO="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO"; }
[[ $(plist CFBundleIdentifier) == "$BUNDLE_ID" ]] || fail "bundle id is $(plist CFBundleIdentifier), expected $BUNDLE_ID"
[[ $(plist CFBundleShortVersionString) == "$VERSION" ]] || fail "version is $(plist CFBundleShortVersionString), expected $VERSION"
if /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$INFO" >/dev/null 2>&1; then
  fail "Info.plist still has a Sparkle feed (SUFeedURL)"
fi

# --- Sign every nested piece of code, deepest first, then the app. ---
sign() {
  codesign --force --timestamp --options runtime \
    --keychain "$FORIT_CODESIGN_KEYCHAIN" --sign "$FORIT_CODESIGN_IDENTITY" "$@"
}
is_macho() { file -b "$1" | grep -q 'Mach-O'; }

log "Signing nested code"
NESTED=()
while IFS= read -r -d '' path; do NESTED+=("$path"); done < <(
  find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.appex' \
    -o -name '*.bundle' -o -name '*.dylib' -o -name '*.so' \) -print0)
for path in "${NESTED[@]}"; do
  case $path in
    *.bundle)
      # A resource bundle (no executable) is sealed by the app's signature; one with code is signed itself.
      [[ -d $path/Contents/MacOS ]] || continue ;;
    *.dylib|*.so)
      is_macho "$path" || continue ;;
  esac
  sign "$path"
done
# Loose executables beside the main one (helpers), if any.
while IFS= read -r -d '' path; do
  [[ $path == "$APP/Contents/MacOS/$(plist CFBundleExecutable)" ]] && continue
  is_macho "$path" && sign "$path"
done < <(find "$APP/Contents/MacOS" "$APP/Contents/Helpers" -type f -perm -u+x -print0 2>/dev/null)

log "Signing $APP_NAME.app"
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority=Developer ID Application|Runtime Version)' \
  | tee "$OUT/codesign.txt"
grep -q "TeamIdentifier=$TEAM_ID" "$OUT/codesign.txt" || fail "app is not signed by team $TEAM_ID"
codesign -d --entitlements - --xml "$APP" > "$OUT/entitlements.plist" 2>/dev/null

notarize() {
  local file=$1 tag=$2 json="$OUT/notary-$2.json"
  log "Notarizing $tag"
  xcrun notarytool submit "$file" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait --timeout 2h --output-format json > "$json" || true
  local status id
  status=$(/usr/bin/plutil -extract status raw -o - "$json" 2>/dev/null || true)
  id=$(/usr/bin/plutil -extract id raw -o - "$json" 2>/dev/null || true)
  if [[ $status != Accepted ]]; then
    [[ -n $id ]] && xcrun notarytool log "$id" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER" "$OUT/notary-$tag-log.json" || true
    fail "notarization of $tag ended '$status' (submission ${id:-none}); see notary-$tag-log.json"
  fi
  log "$tag notarization Accepted ($id)"
}

if [[ ${FORIT_SKIP_NOTARIZE:-0} != 1 ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/app-for-notary.zip"
  notarize "$OUT/app-for-notary.zip" app
  rm -f "$OUT/app-for-notary.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -t execute -vv "$APP" 2>&1 | tee "$OUT/spctl-app.txt"
fi

# --- DMG ---
log "Packaging $BASENAME.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE (GPLv3).txt"
DMG="$OUT/$BASENAME.dmg"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --keychain "$FORIT_CODESIGN_KEYCHAIN" --sign "$FORIT_CODESIGN_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
if [[ ${FORIT_SKIP_NOTARIZE:-0} != 1 ]]; then
  notarize "$DMG" dmg
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | tee "$OUT/spctl-dmg.txt"
fi
(cd "$OUT" && shasum -a 256 "$BASENAME.dmg" > "$BASENAME.dmg.sha256")

cat > "$OUT/SOURCE.txt" <<EOF
$APP_NAME $VERSION ($BUILD)
Bundle identifier: $BUNDLE_ID
Built from: $PUBLIC_REPO/commit/$COMMIT
License: GNU General Public License v3.0 (LICENSE). ForIT Dictate is ForIT's build of VoiceInk by
Prakash Joshi Pax (https://github.com/Beingpax/VoiceInk). The complete source for this build, including this
script, is at the commit above.
EOF
rm -rf "$APP"
log "Done: $DMG"
