#!/usr/bin/env python3
"""Retain curated Dictate release evidence in a collector-compatible JSON .log.

This helper only reads the named release outputs. It runs no command and reads no
credentials. Metadata files are capped at 16 MiB each; the DMG is hashed as a
stream, without embedding its binary content. A failing release always produces
FAIL, and its original exit code remains the release script's responsibility.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import sys
import uuid
from xml.parsers.expat import ExpatError


SCHEMA = "forit.dictate.release-evidence.v1"
RECEIPT_NAME = "release-evidence.log"
MAX_FILE_BYTES = 16 * 1024 * 1024
EXPECTED_TEST_COUNT = 52
BUNDLE_ID = "io.forit.dictate"
FILES = (
    "SOURCE.txt", "Package.resolved", "codesign.txt", "entitlements.plist",
    "spctl-app.txt", "spctl-dmg.txt", "notary-app.json", "notary-dmg.json",
    "bundle-info.json", "integration-tests/RESULT.json",
    "integration-tests/synthetic-history-v1.json",
)


@contextmanager
def output_directory(path):
    """Open/create each directory component without following any symlink."""
    path = Path(path)
    if ".." in path.parts:
        raise ValueError("output directory must not contain parent traversal")
    absolute = Path(os.path.abspath(path))
    descriptor = os.open(absolute.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in absolute.parts[1:]:
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=descriptor)
            except FileNotFoundError:
                os.mkdir(part, mode=0o700, dir_fd=descriptor)
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


@contextmanager
def regular_file(directory, relative):
    """Resolve fixed relative names through directory descriptors, never links."""
    parts = PurePosixPath(relative).parts
    if not parts or relative.startswith("/") or any(p in (".", "..") for p in parts):
        raise ValueError("invalid evidence path")
    parent = os.dup(directory)
    descriptor = None
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=parent)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("evidence input is not a regular file")
        yield descriptor, info
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)


def fingerprint(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def read_text(directory, name):
    with regular_file(directory, name) as (descriptor, before):
        if before.st_size > MAX_FILE_BYTES:
            raise ValueError("metadata exceeds 16 MiB")
        chunks = []
        size = 0
        while True:
            chunk = os.read(descriptor, min(65536, MAX_FILE_BYTES + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if size > MAX_FILE_BYTES:
                raise ValueError("metadata exceeds 16 MiB")
        if fingerprint(before) != fingerprint(os.fstat(descriptor)) or size != before.st_size:
            raise ValueError("evidence changed while being read")
    data = b"".join(chunks)
    text = data.decode("utf-8", errors="strict")
    if not text:
        raise ValueError("empty evidence file")
    return {"byteCount": len(data), "sha256": hashlib.sha256(data).hexdigest(), "contentUTF8": text}


def hash_dmg(directory, name):
    with regular_file(directory, name) as (descriptor, before):
        if before.st_size == 0:
            raise ValueError("empty DMG")
        digest = hashlib.sha256()
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise ValueError("DMG changed while being read")
            digest.update(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1) or fingerprint(before) != fingerprint(os.fstat(descriptor)):
            raise ValueError("DMG changed while being read")
    return {"path": name, "byteCount": before.st_size, "sha256": digest.hexdigest()}


def strict_json(text):
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result

    def constant(_value):
        raise ValueError("non-finite JSON number")

    value = json.loads(text, object_pairs_hook=pairs, parse_constant=constant)
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, expected):
    return type(value) is int and value == expected


def utc_timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z", value):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ")
        return True
    except ValueError:
        return False


def validate_fixture(value, byte_count):
    require(set(value) == {"schemaVersion", "updatedAt", "truncated", "entries"}, "unsupported fixture fields")
    require(integer(value["schemaVersion"], 1), "unsupported fixture schema")
    require(byte_count <= 8 * 1024 * 1024, "fixture exceeds its 8 MiB contract")
    require(utc_timestamp(value["updatedAt"]) and type(value["truncated"]) is bool, "invalid fixture envelope")
    entries = value["entries"]
    require(isinstance(entries, list) and bool(entries), "fixture must contain a synthetic entry")
    identifiers = set()
    previous = None
    for entry in entries:
        require(isinstance(entry, dict) and set(entry) == {"id", "timestamp", "text", "rawText", "duration"}, "unsupported fixture entry")
        identifier = entry["id"]
        require(isinstance(identifier, str) and str(uuid.UUID(identifier)) == identifier, "invalid fixture UUID")
        require(identifier not in identifiers, "duplicate fixture UUID")
        identifiers.add(identifier)
        require(utc_timestamp(entry["timestamp"]), "invalid fixture timestamp")
        require(all(isinstance(entry[key], str) and bool(entry[key].strip()) for key in ("text", "rawText")), "invalid fixture text")
        duration = entry["duration"]
        require(type(duration) in (int, float) and math.isfinite(duration) and duration >= 0, "invalid fixture duration")
        current = (entry["timestamp"], identifier)
        if previous:
            require(current[0] < previous[0] or (current[0] == previous[0] and current[1] > previous[1]), "fixture ordering mismatch")
        previous = current


def validate_bundle(value, request):
    require(set(value) == {"bundleId", "version", "build"}, "unsupported bundle identity fields")
    build = value["build"]
    require(isinstance(build, str) or type(build) is int, "invalid bundle build type")
    require(value["bundleId"] == BUNDLE_ID and value["version"] == request["version"]
            and str(build) == request["build"], "bundle identity/version/build mismatch")


def validate_files(files, request, errors):
    parsed = {}
    for name, retained in files.items():
        try:
            if name.endswith(".json") or name == "Package.resolved":
                parsed[name] = strict_json(retained["contentUTF8"])
            elif name == "entitlements.plist":
                require(isinstance(plistlib.loads(retained["contentUTF8"].encode("utf-8")), dict), "entitlements must be a plist dictionary")
        except (ValueError, TypeError, OverflowError, RecursionError, ExpatError, plistlib.InvalidFileException) as exc:
            errors.append(name + ": " + str(exc))

    checks = {
        "SOURCE.txt": lambda: require(
            files["SOURCE.txt"]["contentUTF8"].splitlines()[0] == "ForIT Dictate {} ({})".format(request["version"], request["build"])
            and "Built from: https://github.com/ForITLLC/for-Dictate/commit/" + request["commit"] in files["SOURCE.txt"]["contentUTF8"].splitlines(),
            "source receipt tuple mismatch"),
        "bundle-info.json": lambda: validate_bundle(parsed["bundle-info.json"], request),
        "Package.resolved": lambda: require(
            type(parsed["Package.resolved"].get("version")) is int
            and parsed["Package.resolved"]["version"] in (1, 2, 3)
            and isinstance((parsed["Package.resolved"].get("object", {}) if parsed["Package.resolved"]["version"] == 1 else parsed["Package.resolved"]).get("pins"), list),
            "unsupported SwiftPM lock format"),
        "integration-tests/RESULT.json": lambda: validate_tests(parsed["integration-tests/RESULT.json"], request, files),
        "integration-tests/synthetic-history-v1.json": lambda: validate_fixture(
            parsed["integration-tests/synthetic-history-v1.json"], files["integration-tests/synthetic-history-v1.json"]["byteCount"]),
    }
    for name in ("notary-app.json", "notary-dmg.json"):
        if name in parsed:
            try:
                require(parsed[name].get("status") == "Accepted", "notarization is not Accepted")
                identifier = parsed[name].get("id")
                require(isinstance(identifier, str) and bool(identifier), "missing notarization id")
                uuid.UUID(identifier)
            except (ValueError, TypeError, AttributeError) as exc:
                errors.append(name + ": " + str(exc))
    for name, check in checks.items():
        if name not in files or ((name.endswith(".json") or name == "Package.resolved") and name not in parsed):
            continue
        try:
            check()
        except (ValueError, TypeError, KeyError, AttributeError, OverflowError, RecursionError) as exc:
            errors.append(name + ": " + str(exc))


def validate_tests(value, request, files):
    require(value.get("schema") == "forit.dictate.integration-tests.v1", "unsupported test receipt schema")
    require(value.get("status") == "PASS" and integer(value.get("exitCode"), 0)
            and integer(value.get("testCount"), EXPECTED_TEST_COUNT) and integer(value.get("failureCount"), 0)
            and value.get("syntheticFixtureValid") is True and value.get("sourceCommit") == request["commit"],
            "test status/count/fixture/source mismatch")
    fixture = files.get("integration-tests/synthetic-history-v1.json")
    require(fixture is not None and value.get("syntheticFixtureSHA256") == fixture["sha256"], "test receipt fixture hash mismatch")


def atomic_receipt(directory, receipt):
    try:
        old = os.stat(RECEIPT_NAME, dir_fd=directory, follow_symlinks=False)
        require(stat.S_ISREG(old.st_mode), "receipt destination is not a regular file")
    except FileNotFoundError:
        pass
    temporary = ".release-evidence-" + uuid.uuid4().hex + ".tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(receipt, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, RECEIPT_NAME, src_dir_fd=directory, dst_dir_fd=directory)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass


def collect(output, commit, build, version, exit_code):
    request = {"app": "for-Dictate", "platform": "macos", "bundleId": BUNDLE_ID,
               "commit": commit, "build": build, "version": version}
    errors = []
    files = {}
    receipt = {"schema": SCHEMA, "request": request, "exitCode": exit_code,
               "status": "FAIL", "createdAt": datetime.now(timezone.utc).isoformat(),
               "validationScope": "retained-release-outputs", "nativeChecksExecutedByHelper": False,
               "files": files, "validationErrors": errors, "dmg": None}
    with output_directory(output) as directory:
        for name in FILES:
            try:
                files[name] = read_text(directory, name)
            except (OSError, ValueError, UnicodeError) as exc:
                errors.append(name + ": " + str(exc))
        validate_files(files, request, errors)
        name = "ForIT-Dictate-{}-{}.dmg".format(version, build)
        try:
            receipt["dmg"] = hash_dmg(directory, name)
            checksum = read_text(directory, name + ".sha256")
            receipt["dmg"]["checksumFile"] = {"path": name + ".sha256", **checksum}
            expected = receipt["dmg"]["sha256"] + "  " + name
            require(checksum["contentUTF8"] in (expected, expected + "\n"), "DMG checksum/filename mismatch")
        except (OSError, ValueError, UnicodeError) as exc:
            errors.append(name + ": " + str(exc))
        receipt["evidenceComplete"] = not errors
        if exit_code == 0 and not errors:
            receipt["status"] = "PASS"
        atomic_receipt(directory, receipt)
    return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--exit-code", required=True, type=int)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("commit must be a full lowercase 40-hex SHA")
    if not re.fullmatch(r"[1-9][0-9]*", args.build):
        parser.error("build must be a positive integer")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", args.version):
        parser.error("version must contain one to three numeric components")
    try:
        receipt = collect(args.output, args.commit, args.build, args.version, args.exit_code)
        print("Release evidence: {} (release exit {}); {}".format(
            receipt["status"], args.exit_code, args.output / RECEIPT_NAME))
        return 1 if args.exit_code == 0 and receipt["status"] != "PASS" else 0
    except (OSError, ValueError, UnicodeError) as exc:
        print("Release evidence could not be written: " + str(exc), file=sys.stderr)
        return 1 if args.exit_code == 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
