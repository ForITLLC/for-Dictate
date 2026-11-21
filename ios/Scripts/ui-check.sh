#!/bin/bash
# iPhone app: its screens as pictures, unsigned, on the lane's own iPhone simulator.
#
# for-iCommon's device matrix builds the Debug simulator app once and photographs every
# screen ios/forit-app.json lists, in light, in dark and at the largest text size, plus the
# ForIT panel open on the home screen, on the lane's three phones (the standard one, the SE and
# the Pro Max), booted one after another. Three of the screens are the keyboard's own view drawn
# inside the app (ios/App/KeyboardPreviewScene.swift). The keyboard running as an extension
# in another app is not pictured: that needs a phone.
#
# The shared Apple launcher owns the build slot, the Common run, the Common checkout
# (FORIT_COMMON_ROOT, the route's common_commit), the timeout and the artifact copy. This
# never signs, uploads, SSHs, installs on a phone or creates a simulator. Same contract as
# ios/Scripts/check-native.sh: --plan probes nothing, --execute runs.
set -euo pipefail

usage() { printf '%s\n' 'Usage: ios/Scripts/ui-check.sh [--plan | --execute]'; }
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
# The ForITCommon revision both apps are pinned to (forit-app.json, controlGuard).
COMMON_REVISION=$(/usr/bin/env python3 -I -B -c \
  'import json; print(json.load(open("forit-app.json"))["controlGuard"]["commonRevision"])')
[[ $COMMON_REVISION =~ ^[0-9a-f]{40}$ ]] || exit 64
if [[ $MODE == plan ]]; then
  python3 -I -B - "$COMMIT" "$COMMON_REVISION" <<'PY'
import json, sys
screens = [s["name"] for s in json.load(open("ios/forit-app.json"))["screens"]["list"]]
print(json.dumps({"app": "for-Dictate", "platform": "ios-ui-check", "commit": sys.argv[1],
    "nativeExecution": False, "buildNumberAllocated": False, "signingRequested": False,
    "command": ["/bin/bash", "ios/Scripts/ui-check.sh", "--execute"],
    "requiredEnvironment": ["FORIT_SOURCE_COMMIT", "FORIT_GATE_RUN", "FORIT_COMMON_ROOT"],
    "phases": ["preflight", "matrix", "evidence", "source-check"],
    "matrix": {"script": "Scripts/device-matrix/device-matrix.sh", "appDir": "ios", "shards": ["iphone"],
               "lane": "for-Dictate", "boots": ["iPhone", "iPhoneSE", "iPhoneProMax"], "screens": screens, "looks": ["light", "dark", "ax5"],
               "profileMenu": "home"},
    "forITCommonRevision": sys.argv[2],
    "receipt": "build/forit-ios-ui-check/receipt.json",
    "evidence": "build/forit-ios-ui-check/evidence.zip",
    "passes": "every cell the matrix could take was taken, and at least one was",
    "outerOwner": "published Apple launcher; existing slot/Common process group and cleanup"}, indent=2))
PY
  exit 0
fi

OUT="$REPO_ROOT/build/forit-ios-ui-check"
MATRIX="$OUT/matrix"
# Never erase or overwrite another run's ignored outputs.
[[ ! -L "$REPO_ROOT/build" && ! -e $OUT && ! -L $OUT ]] \
  || { printf '%s\n' 'ui-check: prior or symlinked check output exists; retain it for its owner' >&2; exit 64; }
umask 077
mkdir -p "$OUT"
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PHASE=preflight
MATRIX_EXIT=not-run
finish() {
  local result=$?
  trap - EXIT
  /usr/bin/python3 -I -B - "$OUT" "$COMMIT" "$result" "$PHASE" "$STARTED" "$MATRIX_EXIT" "$COMMON_REVISION" <<'PY' || { (( result != 0 )) || result=1; }
import csv, datetime, json, os, sys, zipfile
out, commit, result, phase, started, matrix_exit, common = sys.argv[1:8]
matrix = os.path.join(out, "matrix")
rows = []
tsv = os.path.join(matrix, "MATRIX.tsv")
if os.path.isfile(tsv):
    with open(tsv, newline="") as handle:
        rows = [r for r in csv.reader(handle, delimiter="\t") if len(r) >= 4]
taken = [r for r in rows if r[3] == "ok"]
failed = [r for r in rows if r[3].startswith("failed")]
gaps = [r for r in rows if r[3].startswith("not drawn")]
# The pictures, the sheet and what the matrix said. Its derived data and helpers are left out.
names = []
if os.path.isdir(matrix):
    names = sorted(n for n in os.listdir(matrix)
                   if not n.startswith(".") and os.path.isfile(os.path.join(matrix, n))
                   and (n == "PACKAGES" or n.rsplit(".", 1)[-1] in ("png", "jpg", "tsv", "log")))
    with zipfile.ZipFile(os.path.join(out, "evidence.zip"), "w", zipfile.ZIP_DEFLATED) as bundle:
        for name in names:
            bundle.write(os.path.join(matrix, name), name)
passed = result == "0" and phase == "complete" and bool(taken) and not failed
json.dump({"app": "for-Dictate", "platform": "ios-ui-check", "commit": commit,
           "passed": passed, "exitCode": int(result), "lastPhase": phase,
           "matrixExit": matrix_exit, "forITCommonRevision": common,
           "cells": {"taken": len(taken), "failed": len(failed), "notDrawn": len(gaps)},
           "failedCells": [{"device": r[0], "screen": r[1], "look": r[2], "why": r[3]} for r in failed],
           "notDrawn": sorted({r[3] for r in gaps}),
           "pictures": [n for n in names if n.endswith(".png")],
           "sheets": [n for n in names if n.endswith(".jpg")],
           "notPictured": "the keyboard running as an extension in another app, Full Access, and the hop to the app",
           "started": started,
           "finished": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "signed": False}, open(os.path.join(out, "receipt.json"), "w"), indent=2)
PY
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'error: ui-check: %s\n' "$*" | tee -a "$OUT/adapter.log" >&2; exit 64; }
[[ ${GITHUB_ACTIONS:-false} != true ]] || fail 'Apple execution through GitHub Actions is retired'
[[ $(uname -s) == Darwin ]] || fail 'execution requires the maintained Mac'
[[ ${FORIT_SOURCE_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || fail 'inherited FORIT_SOURCE_COMMIT is required'
[[ $FORIT_SOURCE_COMMIT == "$COMMIT" ]] || fail 'inherited source commit differs from checkout HEAD'
git status --porcelain --untracked-files=all > "$OUT/source-before.log"
[[ ! -s $OUT/source-before.log ]] || fail 'checkout must be clean, including untracked source'
[[ ${FORIT_GATE_RUN:-} == /* && -f $FORIT_GATE_RUN/lane && -f $FORIT_GATE_RUN/up ]] \
  || fail 'an inherited Common gate run is required'
[[ ${FORIT_COMMON_ROOT:-} == /* && -f $FORIT_COMMON_ROOT/Scripts/device-matrix/device-matrix.sh ]] \
  || fail 'the launcher must supply FORIT_COMMON_ROOT (the route pins common_commit)'
[[ $(git -C "$FORIT_COMMON_ROOT" rev-parse HEAD) == "$COMMON_REVISION" ]] \
  || fail 'FORIT_COMMON_ROOT is not the ForITCommon revision this app is pinned to'
FORIT_XCODEBUILD=${FORIT_XCODEBUILD:-"$HOME/bin/xcodebuild"}
case $FORIT_XCODEBUILD in
  "$HOME/bin/xcodebuild"|/Users/Shared/ci-runner/xcodebuild) ;;
  *) fail 'use the installed slot-aware xcodebuild wrapper' ;;
esac
[[ -x $FORIT_XCODEBUILD ]] || fail 'installed slot-aware xcodebuild wrapper is unavailable'

# The matrix calls plain `xcodebuild`: this makes that the slot-aware wrapper. It draws only on
# simulators that are this lane's, and a kind the lane has none of is a row that says so, not a
# failure, which is why a run with no picture at all does not pass (finish). On the build Mac a
# job boots only the kinds MATRIX_BOOT names, one after another and never two at once; left
# unset it is the iPhone, the iPad and Vision Pro, and the SE and the Pro Max are not drawn.
PHASE=matrix
MATRIX_EXIT=0
PATH="$(dirname "$FORIT_XCODEBUILD"):$PATH" MATRIX_LANE=for-Dictate MATRIX_RUN="$FORIT_GATE_RUN" \
  MATRIX_BOOT='iPhone iPhoneSE iPhoneProMax' \
  /bin/bash "$FORIT_COMMON_ROOT/Scripts/device-matrix/device-matrix.sh" "$REPO_ROOT/ios" "$MATRIX" iphone \
  > "$OUT/matrix.log" 2>&1 || MATRIX_EXIT=$?
tail -40 "$OUT/matrix.log"
(( MATRIX_EXIT == 0 )) || { printf 'error: ui-check: the device matrix exited %s (see matrix.log)\n' "$MATRIX_EXIT" >&2; exit "$MATRIX_EXIT"; }
PHASE=evidence
[[ -s $MATRIX/MATRIX.tsv ]] || fail 'the device matrix wrote no MATRIX.tsv'
TAKEN=$(awk -F'\t' '$4 == "ok"' "$MATRIX/MATRIX.tsv" | wc -l | tr -d ' ')
# Why, in the matrix's own words: each kind's rows carry one reason.
(( TAKEN > 0 )) || fail "no screen was drawn. $(awk -F'\t' '$4 ~ /^not drawn/ { print $4 }' "$MATRIX/MATRIX.tsv" | sort -u | head -3 | paste -sd'|' -)"
PHASE=source-check
git status --porcelain --untracked-files=all > "$OUT/source-after.log"
[[ ! -s $OUT/source-after.log ]] || fail 'source changed during the check'
[[ $(git rev-parse HEAD) == "$COMMIT" ]] || fail 'checkout HEAD changed during the check'
PHASE=complete
printf 'iPhone screens taken for %s: %s cells. Evidence: %s\n' "$COMMIT" "$TAKEN" "$OUT"
