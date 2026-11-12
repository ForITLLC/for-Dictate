#!/usr/bin/env python3
"""Merge upstream's Localizable.xcstrings into ours key by key during an upstream sync.

A text merge of the catalogue conflicts on every key upstream touched, because this fork
renamed "VoiceInk" to "ForIT Dictate" inside keys and values. This does a three-way merge
per key and per language instead, carrying the app name into upstream's entries.

    scripts/forit-upstream-strings.py BASE OURS THEIRS [--drop KEY ...] [--write]

BASE is the fork point, OURS the fork (HEAD while merging), THEIRS upstream. Without
--write it only reports. Keys upstream deleted are dropped; anything both sides changed
differently is kept as ours and listed under REVIEW.
"""
import argparse
import collections
import json
import subprocess

PATH = "VoiceInk/Localizable.xcstrings"
MISSING = object()
OD = collections.OrderedDict


def load(rev):
    raw = subprocess.check_output(["git", "show", f"{rev}:{PATH}"]).decode()
    return json.loads(raw, object_pairs_hook=OD)


def brand(value):
    if isinstance(value, str):
        return value.replace("VoiceInk", "ForIT Dictate")
    if isinstance(value, dict):
        return OD((key, brand(item)) for key, item in value.items())
    if isinstance(value, list):
        return [brand(item) for item in value]
    return value


def merge(base, ours, theirs, path, review):
    if ours == theirs or theirs == base:
        return ours
    if ours == base:
        return theirs
    if isinstance(ours, dict) and isinstance(theirs, dict) and (base is MISSING or isinstance(base, dict)):
        base = base if isinstance(base, dict) else {}
        merged = OD()
        for key in list(theirs) + [key for key in ours if key not in theirs]:
            value = merge(base.get(key, MISSING), ours.get(key, MISSING), theirs.get(key, MISSING), path + [key], review)
            if value is not MISSING:
                merged[key] = value
        return merged
    review.append(" > ".join(path) + ": both sides changed it; kept ours")
    return ours


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("base")
    parser.add_argument("ours")
    parser.add_argument("theirs")
    parser.add_argument("--drop", action="append", default=[], help="upstream key this fork does not carry")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    catalogue = load(args.theirs)
    base, ours, theirs = load(args.base)["strings"], load(args.ours)["strings"], catalogue["strings"]
    renamed = {key: brand(key) for key in base if "VoiceInk" in key and key not in ours and brand(key) in ours}
    review, counts, result = [], collections.Counter(), OD()

    for key, entry in theirs.items():
        if key in args.drop or brand(key) in args.drop:
            counts["dropped"] += 1
            continue
        if key in renamed or ("VoiceInk" in key and key not in base and key not in ours):
            name = brand(key)
            value = merge(brand(base[key]) if key in base else MISSING, ours.get(name, MISSING), brand(entry), [name], review)
            counts["carried the app name"] += 1
        else:
            name = key
            value = merge(base.get(key, MISSING), ours.get(key, MISSING), entry, [key], review)
        if value is not MISSING:
            result[name] = value

    originals = {name: key for key, name in renamed.items()}
    items, previous = list(result.items()), None
    for key, entry in ours.items():
        if key not in result:
            original = originals.get(key, key)
            if original in base and original not in theirs:
                counts["deleted upstream"] += 1
                if entry != (brand(base[original]) if original != key else base[original]):
                    review.append(f"{key}: upstream deleted it, ours had changed it; dropped")
            elif original not in theirs:
                # Our own key: keep it after the neighbour it follows in our file.
                index = next((i for i, (name, _) in enumerate(items) if name == previous), len(items) - 1)
                items.insert(index + 1, (key, entry))
                counts["ours only"] += 1
        previous = key

    catalogue["strings"] = OD(items)
    if args.write:
        with open(PATH, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(catalogue, indent=2, separators=(",", " : "), ensure_ascii=False))
    print(dict(counts), "keys", len(items), "written" if args.write else "dry run")
    print("REVIEW", len(review))
    for line in review:
        print("  " + line)


if __name__ == "__main__":
    main()
