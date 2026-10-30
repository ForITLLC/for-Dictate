#!/bin/bash
# App-owned adapter for for-dev's shared Apple launcher. No SSH, Actions, queue,
# gate lifecycle, credential provisioning, keychain mutation or host setup lives here.
set -euo pipefail

fail() { printf 'forit-mini-release: %s\n' "$*" >&2; exit 64; }
usage() { echo 'Usage: scripts/forit-mini-release.sh BUILD [--plan | --check-only]'; }
[[ ${1:-} != --help ]] || { usage; exit 0; }
BUILD=${1:-}
[[ $BUILD =~ ^[1-9][0-9]*$ ]] || fail 'an explicit positive integer BUILD is required'
shift
MODE=release
for argument in "$@"; do
  case $argument in
    --plan) [[ $MODE == release ]] || fail 'choose one mode'; MODE=plan ;;
    --check-only) [[ $MODE == release ]] || fail 'choose one mode'; MODE=checks ;;
    --upload) fail 'Dictate ships a notarized DMG; this adapter does not upload to TestFlight' ;;
    *) usage >&2; fail "unsupported argument: $argument" ;;
  esac
done
[[ ${GITHUB_ACTIONS:-false} != true ]] || fail 'Apple builds through GitHub Actions are retired'

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"
export FORIT_BUILD_NUMBER="$BUILD"
CHECKOUT_SOURCE_COMMIT=$(git rev-parse HEAD)
if [[ -n ${FORIT_SOURCE_COMMIT:-} ]]; then
  [[ $FORIT_SOURCE_COMMIT =~ ^[0-9a-f]{40}$ ]] || fail 'inherited FORIT_SOURCE_COMMIT must be a full lowercase 40-hex SHA'
  [[ $FORIT_SOURCE_COMMIT == "$CHECKOUT_SOURCE_COMMIT" ]] || fail 'inherited FORIT_SOURCE_COMMIT does not match checkout HEAD'
else
  FORIT_SOURCE_COMMIT=$CHECKOUT_SOURCE_COMMIT
fi
export FORIT_SOURCE_COMMIT
export FORIT_XCODEBUILD=${FORIT_XCODEBUILD:-"$HOME/bin/xcodebuild"}
export FORIT_CODESIGN_IDENTITY=${FORIT_CODESIGN_IDENTITY:-'Developer ID Application: ForIT Limited Liability Company (UUSSWWML2A)'}
export NOTARY_KEY=${NOTARY_KEY:-"$HOME/AppleCerts/AuthKey_78ND83SSBB.p8"}
export NOTARY_KEY_ID=${NOTARY_KEY_ID:-78ND83SSBB}
export NOTARY_ISSUER=${NOTARY_ISSUER:-b21bbf92-e667-43f9-b358-29908a814489}

if [[ $MODE == plan ]]; then
  # This branch reads source metadata only. It never probes the Mac, keys or network.
  python3 - "$FORIT_SOURCE_COMMIT" "$BUILD" <<'PY'
import json, sys
print(json.dumps({
    "app": "for-Dictate", "commit": sys.argv[1], "platform": "macos", "build": sys.argv[2],
    "channel": "Developer ID notarized DMG", "nativeExecution": False, "upload": False,
    "requiredEnvironment": ["FORIT_GATE_RUN", "FORIT_CODESIGN_KEYCHAIN"],
    "outerOwner": "published for-dev mini-build.py; existing whole-job slot and Common lifecycle",
    "tests": 52, "receipt": "build/forit-release/release-evidence.log",
    "executionRequires": "reviewed common publication and current host capacity; no execution authorized by this plan"
}, indent=2))
PY
  exit 0
fi

[[ $(uname -s) == Darwin ]] || fail 'native execution requires the maintained Mac'
[[ ${FORIT_GATE_RUN:-} == /* && -f $FORIT_GATE_RUN/lane ]] || fail 'an inherited active Common gate run is required'
[[ -x $FORIT_XCODEBUILD ]] || fail 'the installed slot-aware xcodebuild wrapper is unavailable'
if [[ $MODE == checks ]]; then
  exec /usr/bin/python3 scripts/check-dictate-integrations.py --output build/forit-release/integration-tests
fi
[[ -n ${FORIT_CODESIGN_KEYCHAIN:-} ]] || fail 'supply the approved existing signing keychain path; this adapter does not provision one'
[[ ${FORIT_SKIP_NOTARIZE:-0} != 1 ]] || fail 'the shared release adapter requires notarization'
exec /bin/bash scripts/forit-release.sh
