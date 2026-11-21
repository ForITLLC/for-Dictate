#!/bin/bash
# App-owned adapter for the shared Apple launcher (the for-Links pattern). The caller owns transport,
# the whole-job slot and any inherited Common gate run; the recipe keeps its checks, signing, export,
# upload and cleanup.
# Usage: apple-release.sh ios BUILD [--upload]
# FORIT_SOURCE_COMMIT must identify this exact clean checkout.
set -uo pipefail

usage() {
  echo 'usage: apple-release.sh ios BUILD [--upload]' >&2
  exit 2
}

refuse() {
  echo "apple-release: $*" >&2
  exit 1
}

[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || usage
PLATFORM=$1
BUILD=$2
UPLOAD=${3:-}
[ "$PLATFORM" = ios ] || usage
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || usage
[ "$#" -ne 3 ] || [ "$UPLOAD" = --upload ] || usage

REQUESTED_COMMIT=${FORIT_SOURCE_COMMIT:-}
[[ "$REQUESTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
  refuse 'FORIT_SOURCE_COMMIT must be a full lowercase 40-character commit SHA'

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || refuse 'cannot locate adapter directory'
IOS_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P) || refuse 'cannot locate ios directory'
REPO_ROOT=$(cd "$IOS_DIR/.." && pwd -P) || refuse 'cannot locate repository directory'
ACTUAL_ROOT=$(git -C "$IOS_DIR" rev-parse --show-toplevel 2>/dev/null) ||
  refuse 'the adapter must run from a repository checkout'
ACTUAL_ROOT=$(cd "$ACTUAL_ROOT" && pwd -P) || refuse 'cannot resolve repository root'
[ "$ACTUAL_ROOT" = "$REPO_ROOT" ] || refuse 'the adapter is not in the repository ios/Scripts directory'
[ "$IOS_DIR" = "$REPO_ROOT/ios" ] && [ "$SCRIPT_DIR" = "$IOS_DIR/Scripts" ] ||
  refuse 'the adapter must be located in ios/Scripts'

ACTUAL_COMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD) || refuse 'cannot read checkout commit'
[ "$ACTUAL_COMMIT" = "$REQUESTED_COMMIT" ] || refuse 'checkout HEAD differs from FORIT_SOURCE_COMMIT'
SOURCE_STATUS=$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all) ||
  refuse 'cannot verify checkout cleanliness'
[ -z "$SOURCE_STATUS" ] || refuse 'release requires a clean committed checkout'

# Positional arguments are always populated: no empty-array expansion under
# Bash 3.2 nounset, no command string, and no second transport or slot wrapper.
set -- "$SCRIPT_DIR/mini-testflight.sh" "$BUILD"
[ -z "$UPLOAD" ] || set -- "$@" --upload
cd "$IOS_DIR" || refuse 'cannot enter ios directory'
exec /bin/bash "$@"
