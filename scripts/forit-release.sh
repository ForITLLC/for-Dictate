#!/bin/bash
# scripts/forit-release.sh: build, sign, notarize and package ForIT Dictate as a Developer ID DMG.
#
# ForIT Dictate is ForIT's build of VoiceInk (GPLv3). This script is part of its Corresponding Source: it is
# the whole of how a shipped build is made from this repository. The shared Apple launcher calls
# scripts/forit-mini-release.sh in its existing whole-job slot and Common gate. GitHub Actions is retired.
#
# Inputs (environment):
#   FORIT_CODESIGN_IDENTITY  SHA-1 of the "Developer ID Application: ForIT Limited Liability Company" identity
#   FORIT_CODESIGN_KEYCHAIN  existing keychain that holds it (already usable; never changed here)
#   FORIT_BUILD_NUMBER      explicit build number; never inferred from a shallow checkout or Actions run
#   FORIT_GATE_RUN          existing Common run inherited from the shared launcher
#   NOTARY_KEY               path to the App Store Connect API key (.p8) used by notarytool
#   NOTARY_KEY_ID, NOTARY_ISSUER
#   FORIT_SKIP_NOTARIZE=1    sign only (a local trial build; never shipped)
#   FORIT_XCODEBUILD         installed slot-aware xcodebuild wrapper (defaults to ~/bin/xcodebuild)
# Output: build/forit-release/ with ForIT-Dictate-<version>-<build>.dmg, its .sha256, notary receipts and
# SOURCE.txt naming the public commit the build came from.
set -euo pipefail

[[ ${GITHUB_ACTIONS:-false} != true ]] || { echo 'Apple builds through GitHub Actions are retired.' >&2; exit 64; }

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

APP_NAME="ForIT Dictate"
BUNDLE_ID=io.forit.dictate
TEAM_ID=UUSSWWML2A
PUBLIC_REPO=https://github.com/ForITLLC/for-Dictate
VERSION=$(tr -d '[:space:]' < forit/VERSION)
BUILD=${FORIT_BUILD_NUMBER:?an explicit FORIT_BUILD_NUMBER is required; use scripts/forit-mini-release.sh}
COMMIT=$(git rev-parse HEAD)
OUT="$REPO_ROOT/build/forit-release"
DERIVED="$REPO_ROOT/build/forit-dd"
ENTITLEMENTS="$REPO_ROOT/VoiceInk/VoiceInk.entitlements"
BASENAME="ForIT-Dictate-$VERSION-$BUILD"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'forit-release: %s\n' "$*" >&2; exit 1; }

[[ -n $VERSION ]] || fail "forit/VERSION is empty"
[[ $BUILD =~ ^[1-9][0-9]*$ ]] || fail "build number must be a positive integer"
[[ ${FORIT_GATE_RUN:-} == /* && -f $FORIT_GATE_RUN/lane ]] || fail "an active inherited Common gate run is required"
[[ -z $(git status --porcelain --untracked-files=all) ]] || fail "source is modified or has untracked files; a shipped build must match a commit"
[[ -z ${FORIT_SOURCE_COMMIT:-} || $FORIT_SOURCE_COMMIT == "$COMMIT" ]] || fail "source commit does not match the staged checkout"

# The outer launcher owns the existing slot and gate lifecycle. Use the installed wrapper;
# never create a second gate, change the host, or silently bypass its slot checks.
FORIT_XCODEBUILD=${FORIT_XCODEBUILD:-"$HOME/bin/xcodebuild"}
[[ -x $FORIT_XCODEBUILD ]] || fail "installed slot-aware xcodebuild wrapper is unavailable"
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

# Keep the former workflow's GPL public-source check in the app-owned path,
# including builds staged from the private mirror.
public_status=$(curl -sS --retry 3 --max-time 30 -o /dev/null -w '%{http_code}' \
  "https://api.github.com/repos/ForITLLC/for-Dictate/commits/$COMMIT")
[[ $public_status == 200 ]] || fail "source commit is not available in the public fork (HTTP $public_status)"

rm -rf "$OUT" "$DERIVED"
mkdir -p "$OUT"
STAGE=""
finish() {
  local result=$?
  trap - EXIT
  if ! /usr/bin/python3 scripts/forit-release-evidence.py --output "$OUT" --commit "$COMMIT" \
      --build "$BUILD" --version "$VERSION" --exit-code "$result"; then
    (( result != 0 )) || result=1
  fi
  [[ -z $STAGE ]] || rm -rf "$STAGE"
  exit "$result"
}
trap finish EXIT
{ "$FORIT_XCODEBUILD" -version; /usr/bin/xcrun --show-sdk-version; } > "$OUT/toolchain.log" 2>&1

# Synthetic checks compile the actual new Foundation helpers without launching
# Dictate or opening the runner user's transcription database. One compiler job.
log "Checking history integration and shared vocabulary"
/usr/bin/python3 scripts/check-dictate-integrations.py --output "$OUT/integration-tests"

# --- whisper.cpp ---
scripts/forit-whisper.sh

# --- Bounded Xcode steps, in the shared launcher's inherited process group. ---
# On timeout return failure. The outer owner must stop/reap its proven process
# group before copying artifacts or deleting source; never signal guessed PIDs.
xcodebuild_within() {
  local minutes=$1 logf=$2 pid began=$SECONDS; shift 2
  "$FORIT_XCODEBUILD" "$@" >"$logf" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS - began >= minutes * 60 )); then
      echo "Xcode step timed out after $minutes minutes; owned-process cleanup belongs to the shared launcher."
      return 124
    fi
    sleep 5
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
(( rc != 124 )) || exit 124
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
  -jobs 2 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" || rc=$?
grep -E '^(build-slot |\*\* |error:|.*: error:|warning: .*deprecated)' "$OUT/xcodebuild.log" || true
(( rc != 124 )) || exit 124
(( rc == 0 )) || fail "xcodebuild failed ($rc; see xcodebuild.log)"
grep -q '\*\* BUILD SUCCEEDED \*\*' "$OUT/xcodebuild.log" || fail "xcodebuild did not succeed (see xcodebuild.log)"

BUILT_APP="$DERIVED/Build/Products/Release/VoiceInk.app"
[[ -d $BUILT_APP ]] || fail "built app not found at $BUILT_APP"
APP="$OUT/$APP_NAME.app"
ditto "$BUILT_APP" "$APP"

INFO="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO"; }
[[ $(plist CFBundleIdentifier) == "$BUNDLE_ID" ]] || fail "bundle id is $(plist CFBundleIdentifier), expected $BUNDLE_ID"
[[ $(plist CFBundleShortVersionString) == "$VERSION" ]] || fail "version is $(plist CFBundleShortVersionString), expected $VERSION"
[[ $(plist CFBundleVersion) == "$BUILD" ]] || fail "build is $(plist CFBundleVersion), expected $BUILD"
/usr/bin/python3 - "$INFO" "$OUT/bundle-info.json" <<'PY'
import json, plistlib, sys
from pathlib import Path
value = plistlib.loads(Path(sys.argv[1]).read_bytes())
Path(sys.argv[2]).write_text(json.dumps({"bundleId": value["CFBundleIdentifier"],
    "version": value["CFBundleShortVersionString"], "build": str(value["CFBundleVersion"])}, indent=2) + "\n")
PY
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
  xcrun stapler staple "$APP" > "$OUT/stapler-app.log" 2>&1
  xcrun stapler validate "$APP" >> "$OUT/stapler-app.log" 2>&1
  spctl -a -t execute -vv "$APP" 2>&1 | tee "$OUT/spctl-app.txt"
fi

# --- DMG ---
log "Packaging $BASENAME.dmg"
STAGE=$(mktemp -d "$OUT/dmg-stage.XXXXXX")
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE (GPLv3).txt"
DMG="$OUT/$BASENAME.dmg"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --keychain "$FORIT_CODESIGN_KEYCHAIN" --sign "$FORIT_CODESIGN_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
if [[ ${FORIT_SKIP_NOTARIZE:-0} != 1 ]]; then
  notarize "$DMG" dmg
  xcrun stapler staple "$DMG" > "$OUT/stapler-dmg.log" 2>&1
  xcrun stapler validate "$DMG" >> "$OUT/stapler-dmg.log" 2>&1
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
