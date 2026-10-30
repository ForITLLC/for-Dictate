#!/usr/bin/env python3
"""Run the app's synthetic integration tests without launching the app or its stores.

Stages the listed, unmodified production helpers and XCTest fixtures as a temporary
Swift package, including in-memory SwiftData checks. No third-party dependencies,
application host, model download, user transcripts or clipboard access are involved.
Run serially on the maintained Mac
release runner; the real application compilation remains a separate required step.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time


PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "DictateIntegrationChecks",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "VoiceInk"),
        .testTarget(name: "DictateIntegrationTests", dependencies: ["VoiceInk"])
    ],
    swiftLanguageVersions: [.v5]
)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=600)
    args = parser.parse_args()
    if not os.environ.get("FORIT_GATE_RUN", "").strip():
        parser.error("FORIT_GATE_RUN is required; native checks must inherit the owning adapter's process group")
    if platform.system() != "Darwin":
        parser.error("these native Foundation/SwiftData tests require the maintained Mac runner")
    if not 1 <= args.timeout_seconds <= 1200:
        parser.error("timeout must be 1..1200 seconds")
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "forit/integration-tests/sources.json").read_text())
    expected_count = manifest.get("expectedTestCount")
    if type(expected_count) is not int or expected_count <= 0:
        parser.error("manifest expectedTestCount must be a positive integer")
    sources = [root / relative for relative in manifest["sources"]]
    tests = sorted({path for pattern in manifest["testPatterns"] for path in root.glob(pattern)})
    if not tests:
        parser.error("no synthetic XCTest fixtures found")
    paths = sources + tests
    for path in paths:
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            parser.error("test inputs must be regular source files inside this checkout")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixture = output / "synthetic-history-v1.json"
    fixture.unlink(missing_ok=True)
    log = output / "swift-test.log"
    receipt = {
        "schema": "forit.dictate.integration-tests.v1",
        "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "sourceSHA256": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths},
        "jobs": 1,
        "expectedTestCount": expected_count,
        "timeoutSeconds": args.timeout_seconds,
        "processGroup": "inherited",
        "applicationLaunched": False,
        "userHistoryOrClipboardRead": False,
    }
    started = time.monotonic()
    # The common native adapter owns the inherited process group. On timeout, a Swift
    # descendant may still need these sources: retain them under this invocation's output
    # until the outer adapter kills/reaps its group and performs verified source cleanup.
    package = Path(tempfile.mkdtemp(prefix="synthetic-package-", dir=output))
    timed_out = False
    process = None
    try:
        (package / "Package.swift").write_text(PACKAGE)
        for destination, inputs in [("Sources/VoiceInk", sources), ("Tests/DictateIntegrationTests", tests)]:
            folder = package / destination
            folder.mkdir(parents=True)
            names = set()
            for path in inputs:
                if path.name in names:
                    parser.error("duplicate staged source filename")
                names.add(path.name)
                (folder / path.name).write_bytes(path.read_bytes())
        command = ["/usr/bin/xcrun", "swift", "test", "--package-path", str(package), "--jobs", "1"]
        environment = os.environ.copy()
        environment["FORIT_SYNTHETIC_HISTORY_FIXTURE_PATH"] = str(fixture)
        with log.open("wb") as stream:
            process = subprocess.Popen(command, cwd=package, env=environment, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=False)
            try:
                result = process.wait(timeout=args.timeout_seconds)
            except subprocess.TimeoutExpired:
                timed_out = True
                result = 124
    finally:
        # Never remove compiler inputs while a timed-out/interrupted process can use them.
        # A normally completed success or failure can safely clean this owned package.
        if not timed_out and (process is None or process.poll() is not None):
            shutil.rmtree(package)
    contents = "" if timed_out else log.read_text(errors="replace")
    summaries = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", contents)
    total, failures = map(int, summaries[-1]) if summaries else (0, 0)
    receipt.update({"exitCode": result, "testCount": total, "failureCount": failures,
                    "elapsedSeconds": round(time.monotonic() - started, 3),
                    "testSummaryComplete": not timed_out and result == 0,
                    "timeout_cleanup_delegated": timed_out,
                    "retained_package_relative_path": package.relative_to(output).as_posix() if timed_out else None})
    fixture_valid = False
    # A timed-out child may still be writing its fixture; do not parse/hash it or
    # report it valid before the owning process-group cleanup has completed.
    if not timed_out and fixture.is_file():
        try:
            data = fixture.read_bytes()
            receipt["syntheticFixtureSHA256"] = hashlib.sha256(data).hexdigest()
            value = json.loads(data)
            fixture_valid = (len(data) <= 8 * 1024 * 1024 and isinstance(value, dict)
                             and set(value) == {"schemaVersion", "updatedAt", "truncated", "entries"}
                             and value["schemaVersion"] == 1 and bool(value["entries"]))
        except (OSError, ValueError, TypeError):
            fixture_valid = False
    passed = result == 0 and total == expected_count and failures == 0 and fixture_valid
    receipt["status"] = "PASS" if passed else "FAIL"
    receipt["syntheticFixtureValid"] = fixture_valid
    (output / "RESULT.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Synthetic integration tests: {receipt['status']} ({total} tests, {failures} failures); jobs=1")
    if not passed:
        if timed_out:
            print("Native checks timed out; cleanup is delegated to the owning adapter's process group.", file=sys.stderr)
        else:
            print("\n".join(contents.splitlines()[-35:]), file=sys.stderr)
    return 124 if timed_out else (0 if passed else 1)


if __name__ == "__main__":
    raise SystemExit(main())
