#!/bin/bash
# Full-app unsigned compile only. The shared launcher owns the slot, inherited
# Common run, process group, timeout cleanup, artifact copy and checkout cleanup.
set -euo pipefail

usage() { printf '%s\n' 'Usage: scripts/forit-mini-compile.sh [--plan | --execute]'; }
MODE=plan
[[ $# -le 1 ]] || { usage >&2; exit 64; }
case ${1:---plan} in
  --plan) ;;
  --execute) MODE=execute ;;
  --help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$REPO_ROOT"
COMMIT=$(git rev-parse HEAD)
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || exit 64
if [[ $MODE == plan ]]; then
  # No host/toolchain/credential probes or file writes in this branch.
  python3 -I -B - "$COMMIT" <<'PY'
import json, sys
print(json.dumps({"app": "for-Dictate", "platform": "macos-compile", "commit": sys.argv[1],
    "nativeExecution": False, "buildNumberAllocated": False, "configuration": "Release",
    "architectures": ["arm64", "x86_64"], "signingRequested": False,
    "command": ["/bin/bash", "scripts/forit-mini-compile.sh", "--execute"],
    "requiredEnvironment": ["FORIT_SOURCE_COMMIT", "FORIT_GATE_RUN"],
    "manifestRequiredEnv": [],
    "continueAfterErrorsSetting": "-IDEBuildingContinueBuildingAfterErrors=YES",
    "receipt": "build/forit-compile/receipt.json", "logs": "build/forit-compile/*.log",
    "outerOwner": "published Apple launcher; existing slot/Common process group and cleanup"}, indent=2))
PY
  exit 0
fi

OUT="$REPO_ROOT/build/forit-compile"
DERIVED="$REPO_ROOT/build/forit-compile-dd"
# Never erase or overwrite another/unknown run's ignored outputs.
[[ ! -L "$REPO_ROOT/build" && ! -e $OUT && ! -L $OUT && ! -e $DERIVED && ! -L $DERIVED ]] \
  || { printf '%s\n' 'forit-mini-compile: prior or symlinked compile output exists; retain it for its owner' >&2; exit 64; }
umask 077
mkdir -p "$OUT"
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PHASE=preflight
finish() {
  local result=$?
  trap - EXIT
  if ! /usr/bin/python3 -I -B scripts/forit-compile-evidence.py --root "$REPO_ROOT" --commit "$COMMIT" \
      --exit-code "$result" --started "$STARTED" --phase "$PHASE"; then
    (( result != 0 )) || result=1
  fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'error: forit-mini-compile: %s\n' "$*" | tee -a "$OUT/adapter.log" >&2; exit 64; }
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
export FORIT_XCODEBUILD
[[ -z ${FORIT_WHISPER_TAG:-} || $FORIT_WHISPER_TAG == v1.9.5 ]] || fail 'Whisper dependency tag must remain pinned'
export FORIT_WHISPER_TAG=v1.9.5
RESOLVED=VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git ls-files --error-unmatch "$RESOLVED" >/dev/null || fail 'tracked Package.resolved is required'
cp "$RESOLVED" "$OUT/Package.resolved.log"

run_within() {
  local minutes=$1 logf=$2 pid began=$SECONDS result=0; shift 2
  "$@" > "$logf" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS - began >= minutes * 60 )); then
      printf '%s\tunknown\ttrue\n' "$PHASE" >> "$OUT/phases.log"
      printf '%s\n' 'error: timed out; outer launcher must reap its owned process group before collection/cleanup' >> "$OUT/adapter.log"
      return 124
    fi
    sleep 2
  done
  wait "$pid" || result=$?
  printf '%s\t%s\tfalse\n' "$PHASE" "$result" >> "$OUT/phases.log"
  return "$result"
}
run_phase() {
  PHASE=$1; shift
  local result=0
  run_within "$@" || result=$?
  (( result == 0 )) || exit "$result"
}
run_phase toolchain 1 "$OUT/toolchain.log" "$FORIT_XCODEBUILD" -version
grep -qx 'Xcode 27.2' "$OUT/toolchain.log" || fail 'this route requires Xcode 27.2'
run_phase sdk 1 "$OUT/sdk.log" /usr/bin/xcrun --show-sdk-version
run_phase whisper 45 "$OUT/whisper.log" /bin/bash scripts/forit-whisper.sh
PKG_ARGS=(
  -project VoiceInk.xcodeproj -scheme VoiceInk -derivedDataPath "$DERIVED"
  -packageAuthorizationProvider netrc -onlyUsePackageVersionsFromResolvedFile
  -disableAutomaticPackageResolution -skipPackageUpdates -hideShellScriptEnvironment
)
run_phase resolve 20 "$OUT/resolve.log" "$FORIT_XCODEBUILD" -resolvePackageDependencies "${PKG_ARGS[@]}"
cmp -s "$RESOLVED" "$OUT/Package.resolved.log" || fail 'resolver changed the committed package pin'
# Xcode27.2 IDEFoundation exports this setting. The non-existent-project read-only
# parser probe accepts it; -continueBuildingAfterErrors is an invalid option.
# It requests continuation where dependencies permit, not exhaustive diagnostics.
run_phase compile 90 "$OUT/xcodebuild.log" "$FORIT_XCODEBUILD" \
  -IDEBuildingContinueBuildingAfterErrors=YES build "${PKG_ARGS[@]}" \
  -configuration Release -destination 'generic/platform=macOS' -jobs 2 \
  -skipPackagePluginValidation -skipMacroValidation \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
run_phase architecture 1 "$OUT/architectures.log" /usr/bin/lipo -archs \
  "$DERIVED/Build/Products/Release/VoiceInk.app/Contents/MacOS/VoiceInk"
PHASE=source-check
cmp -s "$RESOLVED" "$OUT/Package.resolved.log" || fail 'compile changed the committed package pin'
git status --porcelain --untracked-files=all > "$OUT/source-after.log"
[[ ! -s $OUT/source-after.log ]] || fail 'source changed during compile'
[[ $(git rev-parse HEAD) == "$COMMIT" ]] || fail 'checkout HEAD changed during compile'
PHASE=complete
# The exit helper requires zero genuine compiler errors, BUILD SUCCEEDED and both
# actual lipo architectures. Any missing/failed evidence makes this invocation fail.
