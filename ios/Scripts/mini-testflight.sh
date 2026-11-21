#!/bin/bash
# mini-testflight.sh: archive, export and (with --upload) upload ForIT Dictate for the iPhone and iPad to TestFlight
# from the Mac mini. Ported from for-Notes apps/ios/Scripts/mini-testflight.sh at 6c199f5, with the app group steps
# of for-Links ios/Scripts/mini-testflight.sh at 5cc2d8e, adapted to an app that ships one keyboard extension.
#
#   ios/Scripts/mini-testflight.sh <build-number> [--upload]
#
# The shared Apple launcher runs it through Scripts/apple-release.sh, which checks the commit first; the launcher owns
# the transport, the build slot and the Common gate run. <build-number> is CFBundleVersion for the app and the
# keyboard (CURRENT_PROJECT_VERSION); it must be higher than every build already uploaded for MARKETING_VERSION in
# project.yml. Without --upload the run stops after the signed IPA is exported and checked, in
# build/testflight-<build-number>/export.
#
# The checks before anything is signed, and a red one stops the run (for-iCommon checklist CI-1): with --upload the
# conformance gate on the commit and the pull request that carries it, then the helpers' tests, the logic tests
# (DictateHandoffTests, on the build Mac) and a Debug simulator build of the app and its keyboard.
#
# Two bundles, two App Store profiles, each made or reused on every run by ForITCommon's asc_provision.py from the
# resolved package (checklist CI-4), and chosen by the certificate's public key:
#   io.forit.dictate           "ForIT Dictate App Store"           ForIT Dictate.app
#   io.forit.dictate.keyboard  "ForIT Dictate Keyboard App Store"  ForIT Dictate.app/PlugIns/ForITDictateKeyboard.appex
# project.yml names each profile in its own target's Release configuration (manual, "Apple Distribution"), so the
# archive signs each bundle with its own profile. Nothing on the xcodebuild command line names a profile or an
# identity: a command-line setting reaches every target, so the app's profile would land on the keyboard. The
# export's provisioningProfiles map names both, by UUID.
#
# The keyboard and the app meet in the app group group.io.forit.dictate: the keyboard asks, the app listens and
# leaves the text there for the keyboard to type. The profile step turns APP_GROUPS on for both bundle ids and
# requires the entitlement in each profile; assigning the group to the bundle ids is a one-time portal step
# (docs/SIGNING.md). The verify step reads the group back out of both signed bundles.
#
# Signing: the team's Apple Distribution identity is ~/AppleCerts/distribution.{key,der}. It is imported into a
# throwaway keychain with a random password, put first in the search list for the run, and deleted on exit.
#
# TestFlight internal testing only. The upload sets testFlightInternalTestingOnly; afterwards asc_resolve.py finds
# the app record by bundle id and its internal group "ForIT internal" (made the first time), asc_testers.py puts
# TESTER_EMAILS in that group and asc_attach.py waits for Apple's processing and sets What to Test. Nothing here
# makes an external group or a public link, or submits anything for review.
#
# Env (defaults are the team's): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, CERT_DIR, TESTER_EMAILS, WHATS_NEW.
set -uo pipefail
cd "$(dirname "$0")/.."
# The Mini's slot-aware xcodebuild link and xcodegen; a non-login ssh shell has neither on its PATH.
export PATH="$HOME/bin:/opt/homebrew/bin:$PATH"

USAGE="usage: mini-testflight.sh <build-number> [--upload]"
BUILD=${1:?$USAGE}
shift
UPLOAD=""
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=--upload ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
done
case "$BUILD" in '' | *[!0-9]* | 0) echo "$USAGE (build number: a whole number above 0)" >&2; exit 2 ;; esac
# The gate needs the repository this ios/ is in.
COMMIT=""
[ -e ../.git ] && [ "$(cd .. && pwd)/ios" = "$PWD" ] && COMMIT=1
if [ -n "$UPLOAD" ] && [ -z "$COMMIT" ]; then
  echo "::error title=Not a commit::--upload runs the conformance gate on a commit: push, then ask for the launcher's ios route" >&2
  exit 2
fi
TEAM=UUSSWWML2A
BUNDLE=io.forit.dictate
KEYBOARD_BUNDLE=io.forit.dictate.keyboard
APP_GROUP=group.io.forit.dictate
PROJECT=ForITDictate.xcodeproj
SCHEME=ForITDictate
APP_NAME="ForIT Dictate"
# The ForIT Dictate record's Apple ID, once it is known (docs/SIGNING.md); empty means any record with this bundle id.
DICTATE_APP_ID=${DICTATE_APP_ID:-}
export ASC_KEY_ID=${ASC_KEY_ID:-78ND83SSBB}
export ASC_ISSUER_ID=${ASC_ISSUER_ID:-b21bbf92-e667-43f9-b358-29908a814489}
KEY=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
CERT_DIR=${CERT_DIR:-$HOME/AppleCerts}
TESTER_EMAILS=${TESTER_EMAILS:-b.thomas@forit.io,me@bthomas.io}
WHATS_NEW=${WHATS_NEW:-"ForIT Dictate build $BUILD: add the ForIT Dictate keyboard in Settings, allow Full Access, then tap the microphone on the keyboard and talk. Speech is turned into text on the phone."}
PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
XCODE_PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
OUT=build/testflight-$BUILD
ARCHIVE=$OUT/ForITDictate.xcarchive
KC="$(pwd -P)/build/signing-$$.keychain-db"
GATE=/Users/Shared/forit-gate/mini-gate.sh
mkdir -p "$OUT" "$PROFILES_DIR"

step() {  # step <name> <cmd...>: prints "step <name> rc=<rc> <seconds>s", log in $OUT
  local name=$1 start rc
  shift
  start=$(date +%s)
  "$@" > "$OUT/$name.log" 2>&1
  rc=$?
  echo "step $name rc=$rc $(( $(date +%s) - start ))s"
  [ $rc -eq 0 ] || { tail -20 "$OUT/$name.log"; exit $rc; }
}

keychain_search_list() {  # keychain_search_list <first|remove>
  # Python passes an argv list directly: spaces and quotes never become shell words.
  # Read today's list each time, keeping the other jobs' entries and their order.
  python3 - "$KC" "$1" <<'PY'
import os
import shlex
import subprocess
import sys

try:
    current = subprocess.run(
        ["security", "list-keychains", "-d", "user"],
        check=True, stdout=subprocess.PIPE, text=True,
    ).stdout
    own = os.path.realpath(sys.argv[1])
    others = [path for path in shlex.split(current) if os.path.realpath(path) != own]
    keychains = ([sys.argv[1]] if sys.argv[2] == "first" else []) + others
    subprocess.run(["security", "list-keychains", "-d", "user", "-s", *keychains], check=True)
except subprocess.CalledProcessError as error:
    sys.exit(error.returncode if error.returncode > 0 else 1)
except (OSError, ValueError):
    print("Could not read or update the keychain search list; existing entries were not guessed.", file=sys.stderr)
    sys.exit(1)
PY
}

keychain_first() {
  keychain_search_list first
}

# On exit, however the run ends: this run's keychain, and what the run built on the Mini's disk (the DerivedData,
# the package checkouts, the archive and the unzipped IPA). The step logs stay in $OUT, and so does the exported
# IPA after a run without --upload, which is what that run is for.
cleanup() {
  local rc=$?
  if [ -e "$KC" ]; then
    keychain_search_list remove || echo "Could not remove the job keychain from the current search list." >&2
    security delete-keychain "$KC" 2>/dev/null || true
  fi
  rm -rf build/dd-iphoneos build/dd-simulator build/dd-tests build/spm "$ARCHIVE" "$OUT/verify" "$OUT/upload"
  [ -z "$UPLOAD" ] || rm -rf "$OUT/export"
  exit "$rc"
}
trap cleanup EXIT

# Other jobs on the Mini rewrite the keychain search list mid-run, and -exportArchive has no
# keychain option, so each try puts $KC first again; only errSecInternalComponent is retried.
export_archive() {
  local try rc=1 log
  log=$(mktemp)
  for try in 1 2 3; do
    keychain_first
    xcodebuild -exportArchive "$@" > "$log" 2>&1
    rc=$?
    cat "$log"
    [ $rc -ne 0 ] && grep -q errSecInternalComponent "$log" || break
    echo "export try $try of 3: errSecInternalComponent"
  done
  rm -f "$log"
  return $rc
}

profile_field() {  # profile_field <file> <key>: one field of a signed profile's plist
  security cms -D -i "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null
}

# Xcode finds project.yml's profiles by NAME among the installed ones. A copy from an earlier run whose profile has
# since been replaced in App Store Connect carries the same name, so only the one just made stays installed. Only
# files named exactly like one of this app's two profiles are ever removed.
prune_installed() {  # prune_installed <profile name> <uuid to keep>
  local dir f
  for dir in "$PROFILES_DIR" "$XCODE_PROFILES_DIR"; do
    for f in "$dir"/*.mobileprovision; do
      [ -e "$f" ] || continue
      [ "$(basename "$f" .mobileprovision)" = "$2" ] && continue
      if [ "$(profile_field "$f" Name)" = "$1" ]; then
        rm -f "$f" && echo "removed an older installed '$1': $f"
      fi
    done
  done
}

# ForITCommon's App Store profile script (for-iCommon checklist CI-4, docs/app-store-provisioning.md): the one in the
# for-iCommon the resolve step puts in build/spm, so it moves with the package.
ASC_PROVISION=build/spm/checkouts/for-iCommon/Scripts/asc/asc_provision.py
APP_GROUPS_ENT=com.apple.security.application-groups

# profile <key> <bundle id> <profile name> <register as>: makes or reuses the App Store profile with the app group,
# installs it for Xcode and sets PROFILE_UUID.
PROFILE_UUID=""
profile() {
  local key=$1 bundle=$2 name=$3 as=$4 file
  file=$OUT/profile-$key.mobileprovision
  step "profile-$key" python3 "$ASC_PROVISION" profile --type IOS_APP_STORE --name "$name" \
    --bundle-id "$bundle" --register-as "$as" --cert-der "$CERT_DIR/distribution.der" \
    --error-title "$name" --out "$file" --capability APP_GROUPS --entitlement "$APP_GROUPS_ENT"
  PROFILE_UUID=$(profile_field "$file" UUID)
  [ -n "$PROFILE_UUID" ] || { echo "no UUID in $file"; exit 1; }
  cp "$file" "$PROFILES_DIR/$PROFILE_UUID.mobileprovision"
  prune_installed "$name" "$PROFILE_UUID"
  echo "profile $key $PROFILE_UUID ($name)"
}

for f in "$KEY" "$CERT_DIR/distribution.der" "$CERT_DIR/distribution.key"; do
  [ -r "$f" ] || { echo "missing $f (docs/SIGNING.md, Where the signing material lives)"; exit 1; }
done
ASC_KEY_BASE64=$(base64 < "$KEY" | tr -d '\n')
export ASC_KEY_BASE64 BUNDLE_ID=$BUNDLE

# ---- The checks (CI-1). GitHub runs nothing, so these are the only ones.
if [ -n "$UPLOAD" ]; then
  [ -x "$GATE" ] || { echo "missing $GATE (for-iCommon: Scripts/forit-gate/mini-gate.sh --install); not uploading"; exit 1; }
  VERSION_YML=$(sed -n 's/^[[:space:]]*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)
  [ -n "$VERSION_YML" ] || { echo "no MARKETING_VERSION in project.yml; not uploading"; exit 1; }
  step gate env FORIT_VERSION="$VERSION_YML" FORIT_BUILD="$BUILD" "$GATE" .. ios
  grep -E '^(mini-gate|forit-gate):' "$OUT/gate.log" | sed 's/^/  /'
else
  echo "step gate skipped: not an upload"
fi
step tests-scripts python3 -m unittest discover -s Scripts -p 'test_*.py'
step xcodegen xcodegen generate
# -scmProvider system: SwiftPM fetches for-iCommon with this user's git and its credentials.
step resolve xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath build/spm -scmProvider system
[ -r "$ASC_PROVISION" ] || { echo "missing $ASC_PROVISION: ForITCommon 0.17.1 or later resolves it"; exit 1; }
step tests-logic xcodebuild test -project "$PROJECT" -scheme DictateHandoffTests -destination 'platform=macOS' \
  -derivedDataPath build/dd-tests -clonedSourcePackagesDirPath build/spm -scmProvider system \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
# The Debug app for the generic simulator: it compiles the app and its keyboard and boots nothing.
step build-simulator xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd-simulator \
  -clonedSourcePackagesDirPath build/spm -scmProvider system CODE_SIGNING_ALLOWED=NO

# ---- Profiles and the signing keychain
profile app "$BUNDLE" "ForIT Dictate App Store" "ForIT Dictate"
UUID_APP=$PROFILE_UUID
profile keyboard "$KEYBOARD_BUNDLE" "ForIT Dictate Keyboard App Store" "ForIT Dictate Keyboard"
UUID_KEYBOARD=$PROFILE_UUID
CERT=$(openssl x509 -inform der -in "$CERT_DIR/distribution.der" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
echo "cert $CERT"

KCPW=$(openssl rand -hex 24)
step keychain bash -c "security create-keychain -p '$KCPW' '$KC' &&
  security set-keychain-settings -lut 3600 '$KC' &&
  security unlock-keychain -p '$KCPW' '$KC' &&
  security import '$CERT_DIR/distribution.key' -k '$KC' -t priv -T /usr/bin/codesign -T /usr/bin/security &&
  security import '$CERT_DIR/distribution.der' -k '$KC' -t cert &&
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '$KCPW' '$KC' >/dev/null"
keychain_first
security find-identity -v -p codesigning "$KC" | grep -q "$CERT" || { echo "identity $CERT not in $KC"; exit 1; }

# ---- Archive, export, verify
step archive xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -sdk iphoneos -destination generic/platform=iOS -derivedDataPath build/dd-iphoneos \
  -clonedSourcePackagesDirPath build/spm -scmProvider system \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM=$TEAM CURRENT_PROJECT_VERSION="$BUILD" \
  OTHER_CODE_SIGN_FLAGS="--keychain \"$KC\""

options() {  # options <export|upload>
  cat > "$OUT/ExportOptions-$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$1</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$CERT</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$BUNDLE</key><string>$UUID_APP</string>
    <key>$KEYBOARD_BUNDLE</key><string>$UUID_KEYBOARD</string>
  </dict>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><true/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
  echo "$OUT/ExportOptions-$1.plist"
}

# ent_key <entitlements xml> <key> <raw|json>: one entitlement of a signed bundle (the dots in the key escaped for
# plutil's key path).
ent_key() {
  plutil -extract "$(printf '%s' "$2" | sed 's/\./\\./g')" "$3" -o - - <<< "$1" 2>/dev/null
}

# ent_has <entitlements xml> <array key> <value>: the entitlement array holds that value.
ent_has() {
  ent_key "$1" "$2" json | grep -q -F "\"$3\""
}

# check_bundle <dir> <bundle id> <profile uuid>: one signed bundle in the exported IPA is the right bundle id at
# this build, carries the profile made above, is signed for distribution and has the app group.
check_bundle() {
  local dir=$1 id=$2 uuid=$3 got ent
  [ -d "$dir" ] || { echo "FAIL $(basename "$dir") is not in the IPA"; return 1; }
  got=$(plutil -extract CFBundleIdentifier raw -o - "$dir/Info.plist")
  [ "$got" = "$id" ] || { echo "FAIL $(basename "$dir") is $got, not $id"; return 1; }
  got=$(plutil -extract CFBundleVersion raw -o - "$dir/Info.plist")
  [ "$got" = "$BUILD" ] || { echo "FAIL $id CFBundleVersion is $got, not $BUILD"; return 1; }
  got=$(plutil -extract CFBundleShortVersionString raw -o - "$dir/Info.plist")
  [ "$got" = "$VERSION" ] || { echo "FAIL $id version is $got, the app's is $VERSION"; return 1; }
  got=$(plutil -extract UIDeviceFamily json -o - "$dir/Info.plist" 2>/dev/null)
  [ "$got" = "[1,2]" ] || { echo "FAIL $id UIDeviceFamily is ${got:-missing}, not [1,2] (TARGETED_DEVICE_FAMILY)"; return 1; }
  got=$(profile_field "$dir/embedded.mobileprovision" UUID)
  [ "$got" = "$uuid" ] || { echo "FAIL $id is signed with profile ${got:-none}, not $uuid"; return 1; }
  ent=$(codesign -d --entitlements - --xml "$dir" 2>/dev/null)
  got=$(plutil -extract application-identifier raw -o - - <<< "$ent" 2>/dev/null)
  [ "$got" = "$TEAM.$id" ] || { echo "FAIL $id application-identifier is ${got:-missing}"; return 1; }
  got=$(plutil -extract get-task-allow raw -o - - <<< "$ent" 2>/dev/null)
  [ "$got" != true ] || { echo "FAIL $id is signed with get-task-allow (a development signature)"; return 1; }
  ent_has "$ent" "$APP_GROUPS_ENT" "$APP_GROUP" ||
    { echo "FAIL $id application-groups has no $APP_GROUP, so the keyboard and the app cannot meet"; return 1; }
  echo "ok $id build $BUILD ($VERSION) profile $uuid group $APP_GROUP"
}

verify_ipa() {
  local root=$OUT/verify app ipa keyboard
  # The IPA is named for the product ("ForIT Dictate.ipa"), so it is found by its extension.
  ipa=$(ls "$OUT"/export/*.ipa 2>/dev/null | head -1)
  [ -f "$ipa" ] || { echo "FAIL the export wrote no .ipa"; return 1; }
  rm -rf "$root" && ditto -x -k "$ipa" "$root" || return 1
  app="$root/Payload/$APP_NAME.app"
  keyboard="$app/PlugIns/ForITDictateKeyboard.appex"
  codesign --verify --deep --strict --verbose=2 "$app" || return 1
  [ -f "$app/Assets.car" ] || { echo "FAIL no Assets.car in $APP_NAME.app (the app icon)"; return 1; }
  # TestFlight holds every build at "Missing Compliance" without it.
  [ "$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$app/Info.plist" 2>/dev/null)" = false ] ||
    { echo "FAIL the app's Info.plist needs ITSAppUsesNonExemptEncryption = NO"; return 1; }
  # The reason the phone shows when it asks for the microphone; the upload refuses an app without it (ITMS-90683).
  [ -n "$(plutil -extract NSMicrophoneUsageDescription raw -o - "$app/Info.plist" 2>/dev/null)" ] ||
    { echo "FAIL the app's Info.plist has no NSMicrophoneUsageDescription"; return 1; }
  # An iPad app that multitasks lists all four iPad orientations, or the upload refuses it (ITMS-90474).
  [ "$(plutil -extract 'UISupportedInterfaceOrientations~ipad' json -o - "$app/Info.plist" 2>/dev/null | tr -cd ',' | wc -c | tr -d ' ')" = 3 ] ||
    { echo "FAIL the app's Info.plist needs all four UISupportedInterfaceOrientations~ipad"; return 1; }
  # The keyboard is a keyboard, and it asks for Full Access: without it the keyboard cannot reach the app group.
  [ "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - "$keyboard/Info.plist" 2>/dev/null)" = com.apple.keyboard-service ] ||
    { echo "FAIL ForITDictateKeyboard.appex is not a keyboard extension"; return 1; }
  [ "$(plutil -extract NSExtension.NSExtensionAttributes.RequestsOpenAccess raw -o - "$keyboard/Info.plist" 2>/dev/null)" = true ] ||
    { echo "FAIL ForITDictateKeyboard.appex does not ask for Full Access (RequestsOpenAccess)"; return 1; }
  VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Info.plist")
  check_bundle "$app" "$BUNDLE" "$UUID_APP" &&
    check_bundle "$keyboard" "$KEYBOARD_BUNDLE" "$UUID_KEYBOARD"
}

export KC
step export export_archive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$(options export)" -exportPath "$OUT/export"
VERSION=""
step verify verify_ipa
grep -E '^ok ' "$OUT/verify.log"

if [ "$UPLOAD" = "--upload" ]; then
  # The app record and its internal group; --require makes a missing record a failed step whose log says how
  # to make it (docs/SIGNING.md). The ids come back through the GITHUB_OUTPUT file asc_resolve.py writes.
  rm -f "$OUT/asc.out"
  step asc env GITHUB_OUTPUT="$OUT/asc.out" python3 Scripts/asc_resolve.py --require
  APPID=$(sed -n 's/^app_id=//p' "$OUT/asc.out" | tail -1)
  GROUPID=$(sed -n 's/^group_id=//p' "$OUT/asc.out" | tail -1)
  if [ -z "$APPID" ] || [ -z "$GROUPID" ] || { [ -n "$DICTATE_APP_ID" ] && [ "$APPID" != "$DICTATE_APP_ID" ]; }; then
    echo "App Store Connect answered app '${APPID}' group '${GROUPID}' for $BUNDLE, not ForIT Dictate (${DICTATE_APP_ID:-any id})"
    echo "and its internal group; not uploading. See $OUT/asc.log."
    exit 3
  fi
  step upload export_archive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$(options upload)" -exportPath "$OUT/upload" \
    -allowProvisioningUpdates -authenticationKeyPath "$KEY" \
    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  echo "uploaded ForIT Dictate build $BUILD to app $APPID"
  # A tester App Store Connect refuses is a ::warning line, never a failed step: the build is up either way.
  step testers python3 Scripts/asc_testers.py --app-id "$APPID" --group-id "$GROUPID" --emails "$TESTER_EMAILS"
  sed 's/^/  /' "$OUT/testers.log"
  # Waits up to 20 minutes for Apple's processing; a build still processing then is a warning, not a failure.
  step processing python3 Scripts/asc_attach.py --app-id "$APPID" --group-id "$GROUPID" --version "$BUILD" \
    --platform IOS --whats-new "$WHATS_NEW"
  grep -v -E 'not visible in ASC yet|state=PROCESSING' "$OUT/processing.log" | sed 's/^/  /'
fi
echo "done ForIT Dictate build $BUILD"
