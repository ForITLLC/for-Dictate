#!/bin/bash
# iPhone app: its screens as pictures, unsigned, on the lane's own iPhone simulators.
#
# for-iCommon's device matrix builds the Debug simulator app and photographs every screen
# ios/forit-app.json lists, in light, in dark and at the largest text size, plus the ForIT panel
# open on the home screen, on the lane's three phones (the standard one, the SE and the Pro Max),
# one up at a time. Three of the screens are the keyboard's own view drawn inside the app
# (ios/App/KeyboardPreviewScene.swift). The keyboard running as an extension in another app is
# not pictured: that needs a phone.
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
# The lane's simulator kinds on the build Mac (ci-for-Dictate-<kind>), in the order they are drawn.
KINDS=(iPhone iPhoneSE iPhoneProMax)
if [[ $MODE == plan ]]; then
  python3 -I -B - "$COMMIT" "$COMMON_REVISION" "${KINDS[@]}" <<'PY'
import json, sys
screens = [s["name"] for s in json.load(open("ios/forit-app.json"))["screens"]["list"]]
print(json.dumps({"app": "for-Dictate", "platform": "ios-ui-check", "commit": sys.argv[1],
    "nativeExecution": False, "buildNumberAllocated": False, "signingRequested": False,
    "command": ["/bin/bash", "ios/Scripts/ui-check.sh", "--execute"],
    "requiredEnvironment": ["FORIT_SOURCE_COMMIT", "FORIT_GATE_RUN", "FORIT_COMMON_ROOT"],
    "phases": ["preflight", "matrix", "evidence", "source-check"],
    "matrix": {"script": "Scripts/device-matrix/device-matrix.sh", "appDir": "ios", "shards": ["iphone"],
               "lane": "for-Dictate", "boots": sys.argv[3:],
               "bootedBy": "ci-sim-lane.sh --lane for-Dictate boot <kind>, one up at a time",
               "screens": screens, "looks": ["light", "dark", "ax5"], "profileMenu": "home"},
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
LANE_HELPER=${MATRIX_LANE_HELPER:-/Users/Shared/ci-sim/ci-sim-lane.sh}
UP=
finish() {
  local result=$?
  trap - EXIT
  # A phone this check booted is this check's to shut down, whatever ended it.
  [[ -z $UP ]] || "$LANE_HELPER" --lane for-Dictate shutdown "$UP" >> "$OUT/boot.log" 2>&1 || true
  /usr/bin/python3 -I -B - "$OUT" "$COMMIT" "$result" "$PHASE" "$STARTED" "$MATRIX_EXIT" "$COMMON_REVISION" \
    "${KINDS[@]}" <<'PY' || { (( result != 0 )) || result=1; }
import csv, datetime, json, os, sys, zipfile
out, commit, result, phase, started, matrix_exit, common = sys.argv[1:8]
kinds = sys.argv[8:]
matrix = os.path.join(out, "matrix")
# Each phone has a matrix run of its own, whose table says "not drawn" for the other two. A cell
# counts once, by the best any run said of it: taken, then failed, then why it was not drawn.
def rank(status):
    if status == "ok":
        return 0
    if status.startswith("failed"):
        return 1
    return 3 if "one after another in a job" in status else 2
cells = {}
for kind in kinds:
    tsv = os.path.join(matrix, kind, "MATRIX.tsv")
    if not os.path.isfile(tsv):
        continue
    with open(tsv, newline="") as handle:
        for row in csv.reader(handle, delimiter="\t"):
            if len(row) >= 4 and (tuple(row[:3]) not in cells or rank(row[3]) < rank(cells[tuple(row[:3])])):
                cells[tuple(row[:3])] = row[3]
rows = [list(key) + [status] for key, status in cells.items()]
taken = [r for r in rows if r[3] == "ok"]
failed = [r for r in rows if r[3].startswith("failed")]
gaps = [r for r in rows if r[3].startswith("not drawn")]
not_booted = {}
path = os.path.join(out, "not-booted.tsv")
if os.path.isfile(path):
    with open(path, newline="") as handle:
        not_booted = {r[0]: r[1] for r in csv.reader(handle, delimiter="\t") if len(r) >= 2}
# The pictures, the sheets and what each matrix run said. Derived data and helpers are left out.
names = []
with zipfile.ZipFile(os.path.join(out, "evidence.zip"), "w", zipfile.ZIP_DEFLATED) as bundle:
    for name in ("boot.log", "not-booted.tsv"):
        if os.path.isfile(os.path.join(out, name)):
            bundle.write(os.path.join(out, name), name)
            names.append(name)
    for kind in kinds:
        folder = os.path.join(matrix, kind)
        if not os.path.isdir(folder):
            continue
        for name in sorted(os.listdir(folder)):
            if name.startswith(".") or not os.path.isfile(os.path.join(folder, name)):
                continue
            if name != "PACKAGES" and name.rsplit(".", 1)[-1] not in ("png", "jpg", "tsv", "log"):
                continue
            # A picture's name already says its phone; the rest is one file per run.
            stored = name if name.endswith(".png") else kind + "-" + name
            bundle.write(os.path.join(folder, name), stored)
            names.append(stored)
    if rows:
        bundle.writestr("MATRIX.tsv", "".join("\t".join(r) + "\n" for r in rows))
        names.append("MATRIX.tsv")
passed = result == "0" and phase == "complete" and bool(taken) and not failed
json.dump({"app": "for-Dictate", "platform": "ios-ui-check", "commit": commit,
           "passed": passed, "complete": passed and not gaps and not not_booted,
           "exitCode": int(result), "lastPhase": phase,
           "matrixExit": matrix_exit, "forITCommonRevision": common,
           "cells": {"taken": len(taken), "failed": len(failed), "notDrawn": len(gaps)},
           "failedCells": [{"device": r[0], "screen": r[1], "look": r[2], "why": r[3]} for r in failed],
           "notDrawn": sorted({r[3] for r in gaps}),
           "notBooted": not_booted,
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
[[ -x $LANE_HELPER ]] || fail "the lane's simulator helper (ci-sim-lane.sh) is unavailable"

# The matrix calls plain `xcodebuild`, `xcrun` and `simctl`. In a launcher job the simulator
# gate's shims come first on PATH and stay first (FORIT_SIM_GATE is one of them); the slot-aware
# xcodebuild comes right after, which is where the gate's own xcodebuild shim hands on to.
MATRIX_PATH="$(dirname "$FORIT_XCODEBUILD"):$PATH"
[[ ${FORIT_SIM_GATE:-} != /* ]] || MATRIX_PATH="$(dirname "$FORIT_SIM_GATE"):$MATRIX_PATH"

# One phone at a time, each booted here and not by the matrix. The matrix's own boot gives
# `simctl boot` 150 s, and in a launcher job that call first waits in the simulator gate for a
# calm Mac: on 2026-11-21 six boots in two jobs were ended in that wait and no picture was taken
# (jobs apple-for-Dictate-93f5f6eea695-295825a837da and -d97fd242469b-9d1187fad8b5). The lane
# helper's boot knows the gate and waits it out. The booted phone is added to the launcher's
# run, so the matrix draws on it as the run's own; a phone that does not boot is named in the
# receipt and the next one is tried. A run with no picture at all does not pass (finish).
PHASE=matrix
MATRIX_EXIT=0
for KIND in "${KINDS[@]}"; do
  printf '== %s %s\n' "$KIND" "$(date -u +%H:%M:%SZ)" | tee -a "$OUT/boot.log"
  BOOT_EXIT=0
  UP=$KIND
  BOOTED=$("$LANE_HELPER" --lane for-Dictate boot "$KIND" 2>> "$OUT/boot.log") || BOOT_EXIT=$?
  printf '%s\n' "$BOOTED" >> "$OUT/boot.log"
  UDID=$(tail -1 <<< "$BOOTED")
  if (( BOOT_EXIT != 0 )) || [[ ! $UDID =~ ^[0-9A-F-]{36}$ ]]; then
    printf '%s\tci-sim-lane.sh boot exit %s\n' "$KIND" "$BOOT_EXIT" | tee -a "$OUT/not-booted.tsv"
    "$LANE_HELPER" --lane for-Dictate shutdown "$KIND" >> "$OUT/boot.log" 2>&1 || true
    UP=
    continue
  fi
  printf '%s\n' "$UDID" >> "$FORIT_GATE_RUN/up"
  KIND_EXIT=0
  PATH=$MATRIX_PATH MATRIX_LANE=for-Dictate MATRIX_RUN="$FORIT_GATE_RUN" MATRIX_BOOT=$KIND \
    MATRIX_LANE_HELPER="$LANE_HELPER" MATRIX_DERIVED_DATA="$OUT/derived-data" \
    /bin/bash "$FORIT_COMMON_ROOT/Scripts/device-matrix/device-matrix.sh" "$REPO_ROOT/ios" "$MATRIX/$KIND" iphone \
    > "$OUT/matrix-$KIND.log" 2>&1 || KIND_EXIT=$?
  { grep -v 'one after another in a job' "$OUT/matrix-$KIND.log" || true; } | tail -40
  (( KIND_EXIT == 0 )) || MATRIX_EXIT=$KIND_EXIT
  "$LANE_HELPER" --lane for-Dictate shutdown "$KIND" >> "$OUT/boot.log" 2>&1 \
    || fail "$KIND would not shut down, so no other phone is booted (one simulator up at a time)"
  UP=
done
(( MATRIX_EXIT == 0 )) || { printf 'error: ui-check: the device matrix exited %s (see matrix-<kind>.log)\n' "$MATRIX_EXIT" >&2; exit "$MATRIX_EXIT"; }
PHASE=evidence
tables() { cat "$MATRIX"/*/MATRIX.tsv 2> /dev/null || true; }
TAKEN=$(tables | awk -F'\t' '$4 == "ok"' | wc -l | tr -d ' ')
# Why, in the helper's and the matrix's own words.
WHY=$({ [[ ! -f $OUT/not-booted.tsv ]] || tr '\t' ' ' < "$OUT/not-booted.tsv"
  tables | awk -F'\t' '$4 ~ /^not drawn/ && $4 !~ /one after another in a job/ { print $4 }'
  } | sort -u | head -4 | paste -sd'|' -)
(( TAKEN > 0 )) || fail "no screen was drawn. $WHY"
PHASE=source-check
git status --porcelain --untracked-files=all > "$OUT/source-after.log"
[[ ! -s $OUT/source-after.log ]] || fail 'source changed during the check'
[[ $(git rev-parse HEAD) == "$COMMIT" ]] || fail 'checkout HEAD changed during the check'
PHASE=complete
printf 'iPhone screens taken for %s: %s cells. Evidence: %s\n' "$COMMIT" "$TAKEN" "$OUT"
