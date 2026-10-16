#!/bin/bash
# scripts/forit-whisper.sh: build the macOS-only whisper.xcframework that ForIT Dictate links, from a pinned
# whisper.cpp tag, at the path the Xcode project expects ($HOME/VoiceInk-Dependencies/whisper.cpp/build-apple).
#
# Upstream's `make whisper` clones whisper.cpp master and runs its build-xcframework.sh, which also builds iOS,
# visionOS and tvOS slices. ForIT Dictate is Mac-only, so this script reuses that script's helper functions
# (everything above its first build step) and runs only the macOS build, framework and xcframework steps.
#
# Every xcodebuild (including the ones CMake's Xcode generator starts) runs through the xcodebuild named by
# FORIT_XCODEBUILD (on the Mac mini: the strict build-slot wrapper /Users/Shared/ci-runner/xcodebuild).
# The finished framework is stamped with the tag and this script's hash, and reused while both match.
set -euo pipefail

WHISPER_TAG=${FORIT_WHISPER_TAG:-v1.9.5}
WHISPER_REPO=https://github.com/ggml-org/whisper.cpp.git
DEPS_DIR="$HOME/VoiceInk-Dependencies"
WHISPER_DIR="$DEPS_DIR/whisper.cpp"
FRAMEWORK="$WHISPER_DIR/build-apple/whisper.xcframework"
XCODEBUILD=${FORIT_XCODEBUILD:-xcodebuild}
SCRIPT_HASH=$(shasum -a 256 "$0" | awk '{print $1}')
STAMP="$WHISPER_DIR/build-apple.forit-stamp"
WANT_STAMP="$WHISPER_TAG $SCRIPT_HASH"

log() { printf '==> %s\n' "$*"; }

if [[ -f $STAMP && $(cat "$STAMP") == "$WANT_STAMP" ]]; then
  log "whisper.xcframework $WHISPER_TAG already built ($FRAMEWORK)"
  exit 0
fi

command -v cmake >/dev/null || { echo "cmake is required (brew install cmake)" >&2; exit 1; }
mkdir -p "$DEPS_DIR"
if [[ ! -d $WHISPER_DIR/.git ]]; then
  rm -rf "$WHISPER_DIR"
  git clone --quiet "$WHISPER_REPO" "$WHISPER_DIR"
fi
git -C "$WHISPER_DIR" fetch --quiet --tags --force origin
git -C "$WHISPER_DIR" checkout --quiet --force "refs/tags/$WHISPER_TAG"
rm -f "$STAMP"
git -C "$WHISPER_DIR" clean -qfdx
log "whisper.cpp $WHISPER_TAG at $(git -C "$WHISPER_DIR" rev-parse HEAD)"

cd "$WHISPER_DIR"
UPSTREAM=build-xcframework.sh
grep -q '^echo "Building for iOS simulator..."' "$UPSTREAM" \
  || { echo "$UPSTREAM changed shape at $WHISPER_TAG: no 'Building for iOS simulator' line" >&2; exit 1; }

# The upstream prologue: options, COMMON_CMAKE_ARGS, tool checks, setup_framework_structure and
# combine_static_libraries. Its own build steps start at the iOS simulator line and are left out.
PROLOGUE=$(mktemp)
trap 'rm -f "$PROLOGUE"' EXIT
sed -n '1,/^echo "Building for iOS simulator..."/p' "$UPSTREAM" | sed '$d' > "$PROLOGUE"

# xcodebuild in the prologue's checks and in combine_static_libraries resolves through PATH, so put the
# chosen xcodebuild first. CMake gets it explicitly as its make program.
WRAPPER_DIR=$(mktemp -d)
trap 'rm -f "$PROLOGUE"; rm -rf "$WRAPPER_DIR"' EXIT
if [[ $XCODEBUILD != xcodebuild ]]; then
  # A shim that execs the chosen xcodebuild by its real path: a symlink would change $0, and the slot
  # wrapper finds its helper beside $0.
  printf '#!/bin/bash\nexec %q "$@"\n' "$XCODEBUILD" > "$WRAPPER_DIR/xcodebuild"
  chmod +x "$WRAPPER_DIR/xcodebuild"
fi

# No -u: upstream's functions read variables they never set.
bash -eo pipefail -c '
  PATH="$1:$PATH"
  XCODEBUILD="$2"
  source "$3"
  echo "Building for macOS..."
  cmake -B build-macos -G Xcode \
      "${COMMON_CMAKE_ARGS[@]}" \
      -DCMAKE_MAKE_PROGRAM="$XCODEBUILD" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
      -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
      -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
      -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
      -DWHISPER_COREML="ON" \
      -DWHISPER_COREML_ALLOW_FALLBACK="ON" \
      -S .
  cmake --build build-macos --config Release -- -quiet
  setup_framework_structure "build-macos" ${MACOS_MIN_OS_VERSION} "macos"
  combine_static_libraries "build-macos" "Release" "macos" "false"
  rm -rf build-apple
  "$XCODEBUILD" -create-xcframework \
      -framework "$(pwd)/build-macos/framework/whisper.framework" \
      -debug-symbols "$(pwd)/build-macos/dSYMs/whisper.dSYM" \
      -output "$(pwd)/build-apple/whisper.xcframework"
' forit-whisper "$WRAPPER_DIR" "$XCODEBUILD" "$PROLOGUE"

[[ -d $FRAMEWORK ]] || { echo "whisper.xcframework was not produced" >&2; exit 1; }
rm -f "$STAMP"
printf '%s' "$WANT_STAMP" > "$STAMP"
log "built $FRAMEWORK"
