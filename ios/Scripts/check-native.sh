#!/bin/bash
# iPhone app: logic tests and an unsigned device compile, nothing else. The shared
# Apple launcher owns the build slot, the inherited Common run, the timeout and the
# artifact copy; this never signs, uploads, SSHs or installs. Same contract as the
# Mac app's scripts/forit-mini-compile.sh: --plan probes nothing, --execute runs.
set -euo pipefail

usage() { printf '%s\n' 'Usage: ios/Scripts/check-native.sh [--plan | --execute]'; }
MODE=plan
[[ $# -le 1 ]] || { usage >&2; exit 64; }
case ${1:---plan} in
  --plan) ;;
  --execute) MODE=execute ;;
  --help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$REPO_ROOT"
COMMIT=$(git rev-parse HEAD)
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || exit 64
# ForITCommon 0.31.9, the pin the Mac app resolves (VoiceInk.xcodeproj Package.resolved).
COMMON_REVISION=352f567e839b8faf61b6df5840c5275b016addce
if [[ $MODE == plan ]]; then
  python3 -I -B - "$COMMIT" "$COMMON_REVISION" <<'PY'
import json, sys
print(json.dumps({"app": "for-Dictate", "platform": "ios-compile", "commit": sys.argv[1],
    "nativeExecution": False, "buildNumberAllocated": False, "signingRequested": False,
    "command": ["/bin/bash", "ios/Scripts/check-native.sh", "--execute"],
    "requiredEnvironment": ["FORIT_SOURCE_COMMIT", "FORIT_GATE_RUN"],
    "phases": ["toolchain", "generate", "resolve", "pin", "logic-tests", "compile", "products", "source-check"],
    "logicTests": {"scheme": "DictateHandoffTests", "destination": "platform=macOS"},
    "compile": {"scheme": "ForITDictate", "configuration": "Release",
                "destination": "generic/platform=iOS", "targets": ["ForITDictate", "ForITDictateKeyboard"]},
    "forITCommonRevision": sys.argv[2],
    "receipt": "build/forit-ios-check/receipt.json", "logs": "build/forit-ios-check/*.log",
    "outerOwner": "published Apple launcher; existing slot/Common process group and cleanup"}, indent=2))
PY
  exit 0
fi

OUT="$REPO_ROOT/build/forit-ios-check"
DERIVED="$REPO_ROOT/build/forit-ios-check-dd"
# Never erase or overwrite another run's ignored outputs.
[[ ! -L "$REPO_ROOT/build" && ! -e $OUT && ! -L $OUT && ! -e $DERIVED && ! -L $DERIVED ]] \
  || { printf '%s\n' 'check-native: prior or symlinked check output exists; retain it for its owner' >&2; exit 64; }
umask 077
mkdir -p "$OUT"
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PHASE=preflight
finish() {
  local result=$?
  trap - EXIT
  /usr/bin/python3 -I -B - "$OUT/receipt.json" "$COMMIT" "$result" "$PHASE" "$STARTED" <<'PY' || { (( result != 0 )) || result=1; }
import datetime, json, sys
path, commit, result, phase, started = sys.argv[1:6]
json.dump({"app": "for-Dictate", "platform": "ios-compile", "commit": commit,
           "passed": result == "0" and phase == "complete", "exitCode": int(result), "lastPhase": phase,
           "started": started,
           "finished": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "signed": False}, open(path, "w"), indent=2)
PY
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'error: check-native: %s\n' "$*" | tee -a "$OUT/adapter.log" >&2; exit 64; }
[[ ${GITHUB_ACTIONS:-false} != true ]] || fail 'Apple execution through GitHub Actions is retired'
[[ $(uname -s) == Darwin ]] || fail 'execution requires the maintained Mac'
[[ ${FORIT_SOURCE_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || fail 'inherited FORIT_SOURCE_COMMIT is required'
[[ $FORIT_SOURCE_COMMIT == "$COMMIT" ]] || fail 'inherited source commit differs from checkout HEAD'
git status --porcelain --untracked-files=all > "$OUT/source-before.log"
[[ ! -s $OUT/source-before.log ]] || fail 'checkout must be clean, including untracked source'
[[ ${FORIT_GATE_RUN:-} == /* && -f $FORIT_GATE_RUN/lane ]] || fail 'an inherited Common gate run is required'
FORIT_XCODEBUILD=${FORIT_XCODEBUILD:-"$HOME/bin/xcodebuild"}
case $FORIT_XCODEBUILD in
  "$HOME/bin/xcodebuild"|/Users/Shared/ci-runner/xcodebuild) ;;
  *) fail 'use the installed slot-aware xcodebuild wrapper' ;;
esac
[[ -x $FORIT_XCODEBUILD ]] || fail 'installed slot-aware xcodebuild wrapper is unavailable'
XCODEGEN=$(PATH="/opt/homebrew/bin:$PATH" command -v xcodegen) || fail 'xcodegen is unavailable'

run_phase() {
  local minutes=$2 logf=$3 pid began=$SECONDS result=0
  PHASE=$1; shift 3
  "$@" > "$logf" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS - began >= minutes * 60 )); then
      printf '%s\tunknown\ttrue\n' "$PHASE" >> "$OUT/phases.log"
      printf '%s\n' 'error: timed out; the outer launcher reaps its process group' >> "$OUT/adapter.log"
      exit 124
    fi
    sleep 2
  done
  wait "$pid" || result=$?
  printf '%s\t%s\tfalse\n' "$PHASE" "$result" >> "$OUT/phases.log"
  (( result == 0 )) || exit "$result"
}

PROJECT=ios/ForITDictate.xcodeproj
PKG_ARGS=(-project "$PROJECT" -derivedDataPath "$DERIVED" -packageAuthorizationProvider netrc
  -skipPackageUpdates -hideShellScriptEnvironment)
run_phase toolchain 1 "$OUT/toolchain.log" "$FORIT_XCODEBUILD" -version
run_phase generate 2 "$OUT/xcodegen.log" "$XCODEGEN" generate --spec ios/project.yml --project ios
run_phase resolve 20 "$OUT/resolve.log" "$FORIT_XCODEBUILD" -resolvePackageDependencies \
  "${PKG_ARGS[@]}" -scheme ForITDictate
PHASE=pin
/usr/bin/python3 -I -B - "$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$COMMON_REVISION" \
  > "$OUT/pin.log" 2>&1 <<'PY' || fail 'ForITCommon did not resolve to the pinned revision (see pin.log)'
import json, sys
pins = {p["identity"]: p["state"] for p in json.load(open(sys.argv[1]))["pins"]}
state = pins.get("for-icommon")
print(json.dumps(pins, indent=2))
sys.exit(0 if state and state.get("revision") == sys.argv[2] else 1)
PY
run_phase logic-tests 20 "$OUT/logic-tests.log" "$FORIT_XCODEBUILD" test "${PKG_ARGS[@]}" \
  -scheme DictateHandoffTests -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
run_phase compile 45 "$OUT/xcodebuild.log" "$FORIT_XCODEBUILD" build "${PKG_ARGS[@]}" \
  -scheme ForITDictate -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE_SPECIFIER=
PHASE=products
APP="$DERIVED/Build/Products/Release-iphoneos/ForIT Dictate.app"
[[ -d $APP && -d "$APP/PlugIns/ForITDictateKeyboard.appex" ]] \
  || fail 'the app or its embedded keyboard extension is missing from the build products'
grep -q 'BUILD SUCCEEDED' "$OUT/xcodebuild.log" || fail 'the compile log does not report success'
# iOS finds the keyboard by the class name in the extension's Info.plist, and a name that is not
# in the binary is a keyboard that comes up blank. The app that ships carries neither a copy of
# the keyboard's view nor the Debug screenshot scenes (ios/project.yml, App/ScreenshotScenes.swift).
/usr/bin/python3 -I -B - "$APP" > "$OUT/products.log" 2>&1 <<'PY' \
  || fail 'the built products are not what ships (see products.log)'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
def bundle(path):
    info = plistlib.loads((path / "Info.plist").read_bytes())
    return info, (path / info["CFBundleExecutable"]).read_bytes()
def runtime_name(module, name):
    return f"_TtC{len(module)}{module}{len(name)}{name}".encode()
info, keyboard = bundle(app / "PlugIns" / "ForITDictateKeyboard.appex")
principal = info["NSExtension"]["NSExtensionPrincipalClass"]
module, _, name = principal.partition(".")
_, binary = bundle(app)
checks = {
    "the keyboard has the class its Info.plist names (" + principal + ")":
        bool(module and name) and runtime_name(module, name) in keyboard,
    "the app has no copy of the keyboard's view": runtime_name("ForITDictate", name) not in binary,
    "the app has no screenshot scenes": b"screenshot-scene" not in binary,
}
for label, ok in checks.items():
    print("ok  " if ok else "FAIL", label)
sys.exit(0 if all(checks.values()) else 1)
PY
PHASE=source-check
git status --porcelain --untracked-files=all > "$OUT/source-after.log"
[[ ! -s $OUT/source-after.log ]] || fail 'source changed during the check'
[[ $(git rev-parse HEAD) == "$COMMIT" ]] || fail 'checkout HEAD changed during the check'
PHASE=complete
printf 'iPhone check passed for %s. Evidence: %s\n' "$COMMIT" "$OUT"
