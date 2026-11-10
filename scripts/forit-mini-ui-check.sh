#!/bin/bash
# Plan by default. Native execution belongs to the owner-pinned macos-ui-check
# launcher, with its inherited slot, Common gate and whole-process cleanup.
set -euo pipefail
[[ $# -le 1 ]] || { printf '%s\n' 'Usage: scripts/forit-mini-ui-check.sh [--plan | --execute]'; exit 64; }
case ${1:---plan} in
  --plan|--execute) mode=${1:---plan} ;;
  --help) printf '%s\n' 'Usage: scripts/forit-mini-ui-check.sh [--plan | --execute]'; exit 0 ;;
  *) exit 64 ;;
esac
root=$(cd "$(dirname "$0")/.." && pwd -P)
exec /usr/bin/python3 -I -B "$root/scripts/check-company-dictionary-ui.py" "$mode"
