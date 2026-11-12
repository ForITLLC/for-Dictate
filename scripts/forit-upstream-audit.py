#!/usr/bin/env python3
"""Audit an upstream sync: list merged lines that are neither upstream's nor already ours.

After a merge, every difference between the merged tree and upstream should be a difference
this fork already had against the fork point. Lines outside that are the merge's own
resolutions (or stale code the merge kept by mistake) and are worth reading one by one.

    scripts/forit-upstream-audit.py BASE OURS THEIRS [path-fragment ...]

BASE is the fork point, OURS the fork before the merge, THEIRS upstream. Compares THEIRS
with the index, so run it with the resolved merge staged or committed. The app's name and
bundle identifier are treated as equal on both sides.
"""
import collections
import os
import re
import subprocess
import sys


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, errors="replace").stdout


def changed_lines(*diff_args):
    added, removed = collections.Counter(), collections.Counter()
    for line in sh("git", "diff", "-U0", "--no-color", "-M", *diff_args).split("\n"):
        if line.startswith(("+++", "---")) or not line[1:].strip():
            continue
        if line.startswith("+"):
            added[line[1:].strip()] += 1
        elif line.startswith("-"):
            removed[line[1:].strip()] += 1
    return added, removed


def neutral(line):
    line = re.sub(r"ForIT Dictate|VoiceInk", "APP", line)
    return re.sub(r"io\.forit\.dictate|com\.prakashjoshipax\.[Vv]oice[Ii]nk", "BUNDLE", line)


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    base, ours, theirs, only = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    files = [
        name for name in sh("git", "diff", "--cached", "--name-only", theirs).split("\n")
        if name.endswith(".swift") and os.path.exists(name) and (not only or any(part in name for part in only))
    ]
    total = 0
    for name in files:
        merged_added, merged_removed = changed_lines("--cached", theirs, "--", name)
        fork_added, fork_removed = changed_lines(base, ours, "--", name)
        fork_added = {neutral(line) for line in fork_added}
        fork_removed = {neutral(line) for line in fork_removed}
        # A rebranded upstream line shows as one removal and one addition; skip those pairs.
        added_neutral = {neutral(line) for line in merged_added}
        removed_neutral = {neutral(line) for line in merged_removed}
        extra = [line for line in merged_added if neutral(line) not in fork_added | removed_neutral]
        lost = [line for line in merged_removed if neutral(line) not in fork_removed | added_neutral]
        if extra or lost:
            total += len(extra) + len(lost)
            print("##", name)
            for line in extra:
                print("   + not upstream's, not ours before:", line[:150])
            for line in lost:
                print("   - upstream's, missing, never removed by us:", line[:150])
    print(f"files differing from upstream: {len(files)}; lines to read: {total}")


if __name__ == "__main__":
    main()
