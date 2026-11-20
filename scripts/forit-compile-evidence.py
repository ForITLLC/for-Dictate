#!/usr/bin/env python3
"""Unsigned compile evidence only: no subprocess, signing, credentials or network.

Read the fixed compile outputs, preserve every diagnostic line and hash stable
logs/binary. A timeout's still-running child has no claimed process exit or final
log; cleanup and final collection remain with the outer Apple launcher.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat


LOGS = ("adapter.log", "toolchain.log", "sdk.log", "whisper.log", "resolve.log", "xcodebuild.log",
        "architectures.log", "source-before.log", "source-after.log", "Package.resolved.log", "phases.log")
REQUIRED_PHASES = ("toolchain", "sdk", "whisper", "resolve", "compile", "architecture")
SEVERITY = re.compile(r"(?:^|\s)(fatal error|error|warning|note):", re.I)
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def inspect_file(path, diagnostics=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    errors, digest, count, succeeded = [], hashlib.sha256(), 0, False
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("evidence is not a regular file")
        remaining, number = before.st_size, 0
        while remaining:
            raw = stream.readline(remaining) if diagnostics else stream.read(min(remaining, 1024 * 1024))
            if not raw:
                break
            remaining -= len(raw)
            number += 1
            digest.update(raw)
            count += len(raw)
            if diagnostics:
                text = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                clean = ANSI.sub("", text)
                if clean.strip() == "** BUILD SUCCEEDED **":
                    succeeded = True
                severity = SEVERITY.search(clean)
                if (severity and severity.group(1).lower() in ("error", "fatal error")) or re.match(r"^CMake (?:Internal )?Error(?:\s|:)", clean):
                    errors.append({"log": path.name, "lineNumber": number, "text": text})
        stable = fingerprint(before) == fingerprint(os.fstat(stream.fileno())) and count == before.st_size
    return {"bytes": count, "sha256": digest.hexdigest(), "stable": stable}, errors, succeeded


def receipt(root, commit, exit_code, started, phase):
    root = Path(root).resolve()
    output = root / "build/forit-compile"
    if output.is_symlink() or not output.is_dir():
        raise ValueError("compile output must be an owned regular directory")
    files, errors, problems, phases = {}, [], [], {}
    build_succeeded = False
    for name in LOGS:
        path = output / name
        if not path.exists() and not path.is_symlink():
            continue
        try:
            metadata, diagnostics, success = inspect_file(path, diagnostics=True)
            files[name] = metadata
            errors.extend(diagnostics)
            if not metadata["stable"]:
                problems.append(f"Evidence changed while read: {name}")
            if name == "xcodebuild.log":
                build_succeeded = success
        except (OSError, ValueError) as error:
            problems.append(f"Unreadable {name}: {type(error).__name__}")
    phase_file = output / "phases.log"
    if "phases.log" in files:
        for line in phase_file.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) != 3 or fields[0] not in REQUIRED_PHASES or fields[0] in phases:
                problems.append("Invalid or repeated phase record")
                continue
            try:
                phases[fields[0]] = {"processExit": None if fields[1] == "unknown" else int(fields[1]),
                                      "timedOut": fields[2] == "true"}
                if fields[2] not in ("true", "false"):
                    problems.append("Invalid timeout marker")
            except ValueError:
                problems.append("Invalid phase exit")
    timed_out = any(value["timedOut"] for value in phases.values())
    for name in REQUIRED_PHASES:
        if name not in phases or phases[name]["processExit"] != 0 or phases[name]["timedOut"]:
            problems.append(f"Missing or failed phase: {name}")
    for name in ("toolchain.log", "sdk.log", "whisper.log", "resolve.log", "xcodebuild.log", "architectures.log"):
        if name not in files or files[name]["bytes"] == 0:
            problems.append(f"Missing or empty phase log: {name}")
    toolchain = (output / "toolchain.log").read_text().splitlines() if "toolchain.log" in files else []
    versions = [line for line in toolchain if line.startswith("Xcode ")]
    if versions != ["Xcode 27.2"]:
        problems.append("Xcode 27.2 was not established")
    archs = (output / "architectures.log").read_text().split() if "architectures.log" in files else []
    if len(archs) != 2 or set(archs) != {"arm64", "x86_64"}:
        problems.append("Actual lipo output is not arm64 plus x86_64")
    if not build_succeeded:
        problems.append("No genuine BUILD SUCCEEDED marker")
    if errors:
        problems.append("Compiler or adapter error diagnostics were emitted")
    for name in ("source-before.log", "source-after.log"):
        if name not in files or files[name]["bytes"] != 0:
            problems.append(f"Source hygiene not established: {name}")
    pin = root / "VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    try:
        pin_metadata, _, _ = inspect_file(pin)
        if "Package.resolved.log" not in files or files["Package.resolved.log"]["sha256"] != pin_metadata["sha256"]:
            problems.append("Package.resolved differs from the source pin")
    except (OSError, ValueError):
        problems.append("Pinned package resolution is missing")
    binary = None
    try:
        binary_path = root / "build/forit-compile-dd/Build/Products/Release/VoiceInk.app/Contents/MacOS/VoiceInk"
        binary, _, _ = inspect_file(binary_path)
        binary["path"] = str(binary_path.relative_to(root))
        binary["architectures"] = archs
        if binary["bytes"] == 0 or not binary["stable"]:
            problems.append("Built binary is empty or changed")
    except (OSError, ValueError):
        problems.append("Built main executable is missing or unreadable")
    if exit_code != 0:
        problems.append(f"Adapter exit: {exit_code}")
    if phase != "complete":
        problems.append(f"Adapter stopped in phase: {phase}")
    result = {"schema": "forit.dictate.unsigned-compile.v1", "app": "for-Dictate", "commit": commit,
              "platform": "macos-compile", "configuration": "Release", "expectedArchitectures": ["arm64", "x86_64"],
              "signingRequested": False, "buildNumberAllocated": False, "signedRelease": False,
              "startedUTC": started, "endedUTC": datetime.now(timezone.utc).isoformat(),
              "adapterPreReceiptExit": exit_code, "adapterExit": exit_code if exit_code else int(bool(problems)),
              "stoppedPhase": phase, "phases": phases, "toolchain": toolchain,
              "continueAfterErrorsSetting": "-IDEBuildingContinueBuildingAfterErrors=YES",
              "errorCount": len(errors), "errorLines": errors,
              "errorLinesFinal": phases.get("compile", {}).get("processExit") is not None and not timed_out
                  and all(v["stable"] for v in files.values()),
              "outerProcessCleanupRequired": True, "outerCleanupVerified": False,
              "ownedChildMayStillRun": timed_out or exit_code in (130, 143), "files": files, "binary": binary,
              "status": "FAIL" if problems else "PASS", "problems": problems}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--exit-code", required=True, type=int)
    parser.add_argument("--started", required=True)
    parser.add_argument("--phase", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("commit must be a full lowercase SHA")
    value = receipt(args.root, args.commit, args.exit_code, args.started, args.phase)
    output = Path(args.root).resolve() / "build/forit-compile/receipt.json"
    temporary = output.with_name("receipt.json.tmp")
    if temporary.exists() or temporary.is_symlink() or output.exists() or output.is_symlink():
        raise ValueError("refusing to replace existing compile receipt")
    with temporary.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
    temporary.replace(output)
    return 0 if value["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
