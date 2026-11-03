#!/bin/bash
# App-owned native image specimen; the for-dev executor owns the inherited gate.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# == 0 ]]; then
    /usr/bin/python3 -I scripts/forit-offscreen-proof.py plan
    exit 0
fi
if [[ $# != 1 || $1 != --execute ]]; then
    printf '%s\n' 'Usage: scripts/forit-offscreen-proof.sh [--execute]' >&2
    exit 64
fi

attempt=""
finish() {
    result=$?
    trap - EXIT
    if [[ -n $attempt ]]; then
        /usr/bin/python3 -I scripts/forit-offscreen-proof.py collect --attempt "$attempt" --exit-code "$result" || {
            if [[ $result == 0 ]]; then result=1; fi
        }
    fi
    exit "$result"
}
trap finish EXIT

attempt=$(/usr/bin/python3 -I scripts/forit-offscreen-proof.py begin)
output=$(/usr/bin/python3 -I scripts/forit-offscreen-proof.py path --attempt "$attempt")
source_commit=$(/usr/bin/python3 -I scripts/forit-offscreen-proof.py prepare --attempt "$attempt")

FORIT_RENDER_OUTPUT="$output" FORIT_RENDER_SOURCE="$source_commit" \
    FORIT_RENDER_REFERENCE_VERSION=1.0.0 FORIT_RENDER_REFERENCE_BUILD=1843 \
    /usr/bin/xcrun swift test --package-path "$output/package" \
    --scratch-path "$output/swift-build" --configuration release \
    --filter DictateOffscreenProofTests.testRenderFixtures \
    2>&1 | /usr/bin/tee "$output/native-build.log"
