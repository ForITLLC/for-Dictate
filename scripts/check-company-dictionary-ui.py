#!/usr/bin/env python3
"""Finite synthetic native UI check; --plan is deliberately the default."""
import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import time
import zipfile

COMMON_REVISION = "352f567e839b8faf61b6df5840c5275b016addce"
FIXTURES = ("signedout", "empty", "full", "stale", "error", "loading", "search", "longnames",
            "signin", "browser-wait", "keyboard-close", "close", "cancel", "signout")
SOURCES = (
    "VoiceInk/Features/Dictionary/Workflows/SharedVocabulary.swift",
    "VoiceInk/Features/Dictionary/Workflows/SharedVocabularyCatalogLock.swift",
    "VoiceInk/Features/Dictionary/Workflows/SharedVocabularyService.swift",
    "VoiceInk/Infrastructure/Persistence/Models/VocabularyWord.swift",
    "VoiceInk/Features/Dictionary/Workflows/CompanyDictionarySnapshot.swift",
    "VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryCallbackRoute.swift",
    "VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryClient.swift",
    "VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryStore.swift",
    "VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryTransport.swift",
    "VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryConnectionModel.swift",
    "VoiceInk/Features/Dictionary/Views/CompanyDictionaryView.swift",
    "forit/ui-fixtures/CompanyDictionaryUIFixture.swift",
)
MAX_PNG = 16 * 1024 * 1024
MAX_SCREENSHOTS = 32 * 1024 * 1024


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def cells():
    result = [(fixture, appearance, "900x600") for fixture in FIXTURES for appearance in ("light", "dark")]
    result += [(fixture, appearance, "1600x1000") for fixture in ("full", "longnames") for appearance in ("light", "dark")]
    return result


def archive_evidence(output, receipt):
    """Whitelist finite outputs, including partial failure evidence. Never ZIP
    arbitrary AppKit TMPDIR contents or overwrite another invocation's archive.
    """
    archive = output / "evidence.zip"
    total_png = 0
    allowed = ("fixture-result.json", "fixture-failure.json", "native/screen.png",
               "native/screen.png.receipt.json", "native/screen.png.mark")
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as zipped:
        for cell in sorted((output / "cells").glob("*")):
            if cell.is_symlink() or not cell.is_dir():
                raise RuntimeError("Unexpected cell path")
            for relative in allowed:
                path = cell / relative
                if not path.exists():
                    continue
                if path.is_symlink() or not path.is_file():
                    raise RuntimeError("Unexpected evidence file type")
                size = path.stat().st_size
                if relative.endswith(".png"):
                    total_png += size
                    if size > MAX_PNG or total_png > MAX_SCREENSHOTS:
                        raise RuntimeError("Encoded screenshot archive budget exceeded")
                elif size > 4 * 1024 * 1024:
                    raise RuntimeError("Fixture metadata exceeds its finite budget")
                zipped.write(path, path.relative_to(output))
        zipped.writestr("screenshots-manifest.json", json.dumps(receipt["cells"], indent=2))
    if archive.stat().st_size > 40 * 1024 * 1024:
        # We exclusively created this archive above; do not retain an oversized
        # explicit artifact for the collector. Original owned cell files remain.
        archive.unlink()
        raise RuntimeError("Archive exceeds bounded artifact contract")
    receipt.update(screenshotArchiveSHA256=digest(archive), screenshotArchiveBytes=archive.stat().st_size,
                   encodedScreenshotBytes=total_png)


def run(command, root, log, *, timeout, environment=None, stdout_path=None):
    # No detached group: the maintained Apple launcher owns every descendant.
    with ExitStack() as stack:
        stream = stack.enter_context(log.open("wb"))
        separate_stdout = stack.enter_context(stdout_path.open("xb")) if stdout_path is not None else None
        process = subprocess.Popen(command, cwd=root, env=environment,
                                   stdout=separate_stdout if separate_stdout is not None else stream,
                                   stderr=stream if separate_stdout is not None else subprocess.STDOUT,
                                   start_new_session=False)
        try:
            result = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise TimeoutError("Owned process group must be reaped by the Apple launcher before collection")
    if result:
        raise RuntimeError(f"Native phase failed ({result}); inspect {log.name}")
    if stdout_path is not None and stdout_path.stat().st_size > 4096:
        raise RuntimeError("Native product-path stdout exceeds its 4096-byte acceptance bound")


def preflight(root, commit):
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS", "false").lower() == "true":
        raise RuntimeError("Execution requires the maintained Mac, never GitHub Actions")
    if os.environ.get("FORIT_SOURCE_COMMIT") != commit:
        raise RuntimeError("Inherited FORIT_SOURCE_COMMIT must match the exact checkout")
    gate = Path(os.environ.get("FORIT_GATE_RUN", ""))
    if not gate.is_absolute() or gate.is_symlink() or not (gate / "lane").is_file():
        raise RuntimeError("Existing inherited FORIT_GATE_RUN is required")
    if git(root, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("Native fixture source must be clean, including untracked files")
    supplied = os.environ.get("FORIT_COMMON_ROOT", "")
    common = Path(supplied)
    if not common.is_absolute() or common.is_symlink() or common.resolve() != common:
        raise RuntimeError("Owner must supply the qualified canonical FORIT_COMMON_ROOT")
    if git(common, "rev-parse", "HEAD") != COMMON_REVISION or git(common, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("Common must be a clean exact 0.31.9 checkout")
    origin = git(common, "config", "--get", "remote.origin.url").lower().removesuffix(".git")
    if origin not in ("https://github.com/foritllc/for-icommon", "git@github.com:foritllc/for-icommon"):
        raise RuntimeError("Common checkout must retain its official existing origin")
    return common


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--execute", action="store_true")
    action.add_argument("--plan", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    commit = git(root, "rev-parse", "HEAD")
    plan = {"app": "for-Dictate", "platform": "macos-ui-check", "commit": commit,
            "nativeExecution": args.execute, "buildNumberAllocated": False, "signingRequested": False,
            "command": ["/bin/bash", "scripts/forit-mini-ui-check.sh", "--execute"],
            "requiredEnvironment": ["FORIT_SOURCE_COMMIT", "FORIT_GATE_RUN", "FORIT_COMMON_ROOT"],
            "common_commit": COMMON_REVISION, "commonRevision": COMMON_REVISION,
            "fixtureCount": len(FIXTURES), "captureCellCount": len(cells()),
            "fixtures": list(FIXTURES), "artifactPaths": ["build/forit-ui-check/receipt.json",
                "build/forit-ui-check/evidence.zip"], "automaticLogCollection": "existing suffix collector",
            "maximumEncodedScreenshotBytes": MAX_SCREENSHOTS,
            "maximumArchiveBytes": 40 * 1024 * 1024,
            "compileTimeoutSeconds": 1200, "captureCellTimeoutSeconds": 45,
            "realSupportAuth": False, "productionAppLaunched": False,
            "browserOpening": "injected count-only synthetic authority", "credentials": "memory-only synthetic",
            "owner": "existing Apple launcher slot/Common gate/process-group/cleanup; no new schedule"}
    if not args.execute:
        print(json.dumps(plan, indent=2))
        return 0
    common = preflight(root, commit)
    build = root / "build"
    output = build / "forit-ui-check"
    if build.is_symlink() or output.exists() or output.is_symlink():
        raise RuntimeError("Retain pre-existing or symlinked output for its owner; do not overwrite")
    os.umask(0o077)
    output.mkdir(parents=True)
    receipt = {**plan, "status": "RUNNING", "startedUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "timeoutCleanupDelegated": False, "acceptanceComplete": False, "cells": []}
    phase = "stage"
    exit_code = 0
    try:
        inputs = []
        package = output / "package"
        source = package / "Sources" / "DictateCompanyUIFixture"
        source.mkdir(parents=True)
        for relative in SOURCES:
            original = root / relative
            if original.is_symlink() or not original.is_file():
                raise RuntimeError(f"Missing or symlinked source: {relative}")
            inputs.append({"path": relative, "sha256": digest(original), "byteCount": original.stat().st_size})
            shutil.copyfile(original, source / original.name)
        receipt["sourceFiles"] = inputs
        common_sources = [common / "Package.swift", *sorted((common / "Sources" / "ForITCommon").rglob("*"))]
        if any(p.is_symlink() for p in common_sources):
            raise RuntimeError("Unexpected symlink in the qualified Common source closure")
        common_files = [p for p in common_sources if p.is_file()]
        tracked_common = set(git(common, "ls-files", "Package.swift", "Sources/ForITCommon").splitlines())
        if {str(p.relative_to(common)) for p in common_files} != tracked_common:
            raise RuntimeError("Common source closure contains omitted or untracked compiler/resource inputs")
        receipt["commonSourceFiles"] = [{"path": str(p.relative_to(common)), "sha256": digest(p)} for p in common_files]
        dependency = json.dumps(str(common))
        identity = json.dumps(common.name.lower())
        manifest = f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DictateCompanyUIFixture", platforms: [.macOS(.v15)],
    dependencies: [.package(path: {dependency})],
    targets: [.executableTarget(name: "DictateCompanyUIFixture", dependencies: [
        .product(name: "ForITCommon", package: {identity})])], swiftLanguageModes: [.v5])
'''
        (package / "Package.swift").write_text(manifest, encoding="utf-8")
        phase = "toolchain"
        run(["/usr/bin/xcrun", "swift", "--version"], root, output / "swift-version.log", timeout=30)
        run(["/usr/bin/xcrun", "--show-sdk-version"], root, output / "sdk.log", timeout=30)
        phase = "compile"
        run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(package), "--configuration", "debug",
             "--product", "DictateCompanyUIFixture", "--jobs", "1"], root, output / "compile.log", timeout=1200)
        phase = "discover-product"
        product_stdout = output / "show-bin-path.stdout.log"
        run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(package),
             "--configuration", "debug", "--show-bin-path"], root,
            output / "show-bin-path.stderr.log", timeout=30, stdout_path=product_stdout)
        with product_stdout.open("rb") as stream:
            product_bytes = stream.read(4097)
        if not product_bytes or len(product_bytes) > 4096 or product_stdout.stat().st_size != len(product_bytes):
            raise RuntimeError("Native product-path stdout is empty, oversized or changed during its bounded read")
        product_lines = product_bytes.decode("utf-8").splitlines()
        if len(product_lines) != 1 or not product_lines[0] or any(ord(c) < 32 or ord(c) == 127 for c in product_lines[0]):
            raise RuntimeError("Native product-path stdout must contain exactly one absolute path")
        reported_products = Path(product_lines[0])
        if not reported_products.is_absolute():
            raise RuntimeError("Native product path is not absolute")
        owned_package = package.resolve(strict=True)
        products = reported_products.resolve(strict=True)
        if not products.is_dir() or not products.is_relative_to(owned_package):
            raise RuntimeError("Native products directory is outside the owned fixture package")
        executable = (products / "DictateCompanyUIFixture").resolve(strict=True)
        if not executable.is_file() or not executable.is_relative_to(owned_package):
            raise RuntimeError("Native executable is outside the owned fixture package")
        receipt["nativeProductsRelativePath"] = str(products.relative_to(owned_package))
        receipt["nativeExecutableRelativePath"] = str(executable.relative_to(owned_package))
        receipt["productDiscoveryStdoutSHA256"] = hashlib.sha256(product_bytes).hexdigest()
        app = output / "ForIT Dictate UI Fixture.app" / "Contents"
        (app / "MacOS").mkdir(parents=True)
        binary = app / "MacOS" / "DictateCompanyUIFixture"
        shutil.copy2(executable, binary)
        # Preserve genuine SwiftPM resource bundles at Bundle.main.bundleURL;
        # the original compiler inputs/build-path fallback also remain retained.
        for bundle in products.glob("*.bundle"):
            if bundle.is_symlink() or not bundle.is_dir():
                raise RuntimeError("Unexpected symlinked resource bundle")
            shutil.copytree(bundle, app.parent / bundle.name)
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "io.forit.dictate.ui-fixture", "CFBundleName": "ForIT Dictate",
            "CFBundleDisplayName": "ForIT Dictate", "CFBundleExecutable": "DictateCompanyUIFixture",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "0",
            "CFBundleDevelopmentRegion": "en", "LSUIElement": True}))
        receipt["fixtureExecutableSHA256"] = digest(binary)
        phase = "capture"
        total_png = 0
        for fixture, appearance, size in cells():
            name = f"{fixture}-{appearance}-{size}"
            cell = output / "cells" / name
            cell.mkdir(parents=True)
            native_directory = cell / "native"
            native_directory.mkdir()
            env = os.environ.copy()
            env["FORIT_COMPANY_UI_OUTPUT"] = str(cell)
            env["FORIT_COMPANY_UI_CAPTURE"] = str(native_directory)
            env["TMPDIR"] = str(native_directory) + os.sep
            command = [str(binary), "-forit-fixture", fixture, "-forit-shot", "screen.png",
                       "-forit-appearance", appearance, "-forit-window", size, "-forit-settle", "3"]
            run(command, cell, output / f"{name}.log", timeout=45, environment=env)
            png = native_directory / "screen.png"
            native = native_directory / "screen.png.receipt.json"
            result = cell / "fixture-result.json"
            if any(p.is_symlink() or not p.is_file() for p in (png, native, result)):
                raise RuntimeError(f"Missing genuine native evidence for {name}")
            if not 24 <= png.stat().st_size <= MAX_PNG:
                raise RuntimeError(f"PNG size exceeds its finite input bound for {name}")
            with png.open("rb") as stream:
                raw = stream.read(MAX_PNG + 1)
            if not 24 <= len(raw) <= MAX_PNG or raw[:8] != b"\x89PNG\r\n\x1a\n":
                raise RuntimeError(f"Invalid/bounded PNG for {name}")
            width, height = struct.unpack(">II", raw[16:24])
            facts = json.loads(native.read_text())
            evidence = json.loads(result.read_text())
            if (facts.get("captureKind") != "own-window-server" or facts.get("fixture") != fixture
                    or facts.get("appearance") != appearance or facts.get("requestedWindow") != size
                    or facts.get("surface") != "ordinary-window"
                    or facts.get("pixelWidth") != width or facts.get("pixelHeight") != height
                    or facts.get("pid") != evidence.get("pid") or facts.get("windowNumber") != evidence.get("windowNumber")
                    or [facts.get("contentWidth"), facts.get("contentHeight")] != [int(v) for v in size.split("x")]
                    or evidence.get("nativeCaptureDirectory") != str(native_directory.resolve())
                    or evidence.get("appearance") != appearance or evidence.get("requestedWindow") != size
                    or [evidence.get("contentWidthPoints"), evidence.get("contentHeightPoints")] != [int(v) for v in size.split("x")]
                    or evidence.get("sourceCommit") != commit or evidence.get("commonRevision") != COMMON_REVISION
                    or evidence.get("syntheticOnly") is not True or evidence.get("browserNetworkRequests") != 0
                    or evidence.get("realBrowserOpened") is not False):
                raise RuntimeError(f"Native identity/isolation mismatch for {name}")
            total_png += len(raw)
            if total_png > MAX_SCREENSHOTS:
                raise RuntimeError("Encoded screenshot archive budget exceeded")
            receipt["cells"].append({"fixture": fixture, "appearance": appearance, "sizePoints": size,
                                      "png": str(png.relative_to(output)), "sha256": digest(png),
                                      "byteCount": len(raw), "pixelWidth": width, "pixelHeight": height,
                                      "nativeReceiptSHA256": digest(native), "fixtureResultSHA256": digest(result),
                                      "interactions": evidence["interactions"]})
        phase = "source-check"
        if git(root, "rev-parse", "HEAD") != commit or git(root, "status", "--porcelain", "--untracked-files=all"):
            raise RuntimeError("App source changed during native check")
        if git(common, "rev-parse", "HEAD") != COMMON_REVISION or git(common, "status", "--porcelain", "--untracked-files=all"):
            raise RuntimeError("Common source changed during native check")
        if any(digest(root / p["path"]) != p["sha256"] for p in inputs):
            raise RuntimeError("Compiled source bytes changed")
        if any(digest(common / p["path"]) != p["sha256"] for p in receipt["commonSourceFiles"]):
            raise RuntimeError("Common compiler/resource bytes changed")
        receipt.update(status="CAPTURED_SCOPED", encodedScreenshotBytes=total_png,
                       acceptanceComplete=False, phase="complete")
        # Captures and local interactions are evidence for review, not a visual
        # verdict, source-guard PASS, real authentication or Ben acceptance.
        exit_code = 0
    except TimeoutError as error:
        receipt.update(status="TIMEOUT", error=str(error), phase=phase, timeoutCleanupDelegated=True)
        exit_code = 124
    except Exception as error:
        receipt.update(status="FAIL", error=str(error), phase=phase)
        exit_code = 1
    except KeyboardInterrupt:
        receipt.update(status="INTERRUPTED", phase=phase, timeoutCleanupDelegated=True)
        exit_code = 130
    finally:
        if not receipt["timeoutCleanupDelegated"]:
            try:
                archive_evidence(output, receipt)
            except Exception as error:
                receipt.update(status="FAIL", archiveError=str(error), acceptanceComplete=False)
                exit_code = 1
        receipt["endedUTC"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        write_json(output / "receipt.json", receipt)
        write_json(output / "ui-evidence.log", receipt)
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"forit-company-ui: {error}", file=sys.stderr)
        sys.exit(64)
