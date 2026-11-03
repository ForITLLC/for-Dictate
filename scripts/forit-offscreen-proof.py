#!/usr/bin/env python3
"""Prepare and retain an alternate-host native image specimen, never a desktop capture.

Only the Mini executor runs prepare/collect. This does not start the product,
read its preferences, touch its Keychain, or access its transcription history.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import textwrap
import uuid
import zipfile
from contextlib import contextmanager


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "build/offscreen-proof"
COMMON_REVISION = "352f567e839b8faf61b6df5840c5275b016addce"
RELEASE_REFERENCE = "e2204a2317af761a0e828d1eb7a44c37f49701d3"
LABEL_PATH = Path("VoiceInk/App/VoiceInk.swift")


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def git(*args):
    return subprocess.check_output(["/usr/bin/git", *args], cwd=ROOT, text=True).strip()


def git_blob(revision, path):
    return subprocess.check_output(["/usr/bin/git", "show", revision + ":" + str(path)], cwd=ROOT)


def attempt_directory(attempt):
    return OUTPUT / "runs" / str(uuid.UUID(attempt))


@contextmanager
def publication_lock():
    """Serialize only local artifact aliases; never lock rendering or fleet work."""
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with (OUTPUT / ".publication.lock").open("a+b") as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def publish_attempt(output, record):
    attempt = record["attemptID"]
    with publication_lock():
        pointer = OUTPUT / "attempt.json"
        current = None
        if pointer.exists():
            current = json.loads(pointer.read_text(encoding="utf-8"))
        if current is not None and current["attemptID"] != attempt:
            return
        # The ownership comparison and every alias replacement share this lock.
        for name in ["evidence.zip", "receipt.json"]:
            temporary = OUTPUT / (name + "." + attempt + ".tmp")
            try:
                shutil.copyfile(output / name, temporary)
                os.replace(temporary, OUTPUT / name)
            finally:
                temporary.unlink(missing_ok=True)
        write_json(pointer, record)


def begin(attempt):
    output = attempt_directory(attempt)
    record = {"schema": "forit.dictate.offscreen-attempt.v1", "attemptID": attempt,
              "startedUTC": utc(), "output": str(output), "status": "PREPARING"}
    pending = {**record, "status": "IN_PROGRESS", "evidenceArchiveCurrent": False}
    with publication_lock():
        # Claim before attempt-directory or archive work can fail. The EXIT
        # collector may then publish FAILED for this owner, never for a newer one.
        write_json(OUTPUT / "attempt.json", record)
        write_json(OUTPUT / "receipt.json", pending)
        output.mkdir(parents=True)
        write_json(output / "attempt.json", record)
        write_json(output / "receipt.json", pending)
        # Previous archives are explicitly noncurrent until this pending archive
        # replaces the alias. Every older attempt remains intact under runs/.
        with zipfile.ZipFile(output / "evidence.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.write(output / "receipt.json", "receipt.json")
            archive.write(output / "attempt.json", "attempt.json")
        temporary = OUTPUT / ("evidence.zip." + attempt + ".tmp")
        try:
            shutil.copyfile(output / "evidence.zip", temporary)
            os.replace(temporary, OUTPUT / "evidence.zip")
        finally:
            temporary.unlink(missing_ok=True)


def label_expression(source):
    menu = source.index("        MenuBarExtra(")
    start = source.index("        } label: {", menu) + len("        } label: {\n")
    end = source.index("            .background(MainWindowRequestBridge", start)
    return textwrap.dedent(source[start:end]).rstrip()


def plan():
    return {
        "schema": "forit.dictate.offscreen-proof-plan.v1",
        "command": ["/bin/bash", "scripts/forit-offscreen-proof.sh", "--execute"],
        "platform": "non-Ben macOS native build executor",
        "method": "Headless XCTest SwiftUI.ImageRenderer; no UI automation, desktop capture or app launch",
        "source": "current committed app source, exact menu-label expression",
        "releaseReference": RELEASE_REFERENCE,
        "referenceVersion": "1.0.0",
        "referenceBuild": "1843",
        "commonRevision": COMMON_REVISION,
        "dataOrigin": "nonprivate synthetic rendering fixture; no user history",
        "artifact_paths": ["build/offscreen-proof/receipt.json", "build/offscreen-proof/evidence.zip"],
        "attemptLayout": "build/offscreen-proof/runs/<uuid>; attempt.json identifies the current attempt",
        "liveBenMacAppearanceProven": False,
        "installedBuildVerifiedByThisRun": False,
        "historySlice": "Separate MacBook-owned native consumer renderer and receipt",
    }


def prepare(attempt):
    output = attempt_directory(attempt)
    if platform.system() != "Darwin":
        raise RuntimeError("Native rendering executes on the macOS build host, not the fleet server")
    package = output / "package"
    package.mkdir()
    target = package / "Tests/DictateOffscreenProofTests"
    target.mkdir(parents=True)
    revision = git("rev-parse", "HEAD")
    source_bytes = git_blob(revision, LABEL_PATH)
    source = source_bytes.decode("utf-8")
    # Exclude the representable bridge: it routes app lifecycle/window requests.
    expression = label_expression(source)
    comparison = {"status": "UNVERIFIED_REFERENCE_UNAVAILABLE", "fileMatches": None,
                  "labelMatches": None}
    try:
        reference_bytes = git_blob(RELEASE_REFERENCE, LABEL_PATH)
        reference_expression = label_expression(reference_bytes.decode("utf-8"))
        comparison = {"status": "COMPARED_COMMITTED_BLOBS",
                      "fileMatches": reference_bytes == source_bytes,
                      "labelMatches": reference_expression == expression,
                      "referenceFileSHA256": hashlib.sha256(reference_bytes).hexdigest(),
                      "referenceLabelSHA256": hashlib.sha256(reference_expression.encode("utf-8")).hexdigest()}
    except (subprocess.CalledProcessError, ValueError, UnicodeError) as error:
        comparison["unverifiedReason"] = type(error).__name__
    generated = "import SwiftUI\nimport ForITCommon\n\nstruct ShippedMenuLabel: View {\n    var body: some View {\n"
    generated += textwrap.indent(expression, "        ") + "\n    }\n}\n"
    (target / "GeneratedMenuLabel.swift").write_text(generated, encoding="utf-8")
    shutil.copyfile(ROOT / "scripts/offscreen-proof/Package.swift", package / "Package.swift")
    shutil.copyfile(ROOT / "scripts/offscreen-proof/Tests/DictateOffscreenProofTests/NativeRender.swift", target / "NativeRender.swift")
    (output / "CommittedVoiceInk.swift").write_bytes(source_bytes)
    write_json(output / "source-provenance.json", {
        "schema": "forit.dictate.offscreen-source.v1",
        "preparedUTC": utc(),
        "attemptID": attempt,
        "rendererCommit": revision,
        "releaseReferenceCommit": RELEASE_REFERENCE,
        "commonRevision": COMMON_REVISION,
        "labelSourcePath": str(LABEL_PATH),
        "labelSourceOrigin": "git show rendererCommit:VoiceInk/App/VoiceInk.swift",
        "labelFileSHA256": hashlib.sha256(source_bytes).hexdigest(),
        "releaseReferenceComparison": comparison,
        "labelExpressionSHA256": hashlib.sha256(expression.encode("utf-8")).hexdigest(),
        "generatedLabelSHA256": sha(target / "GeneratedMenuLabel.swift"),
        "labelExtraction": "Unmodified MenuBarExtra label expression and accessibility modifiers; app window-request bridge omitted",
        "nativeRendererSHA256": sha(target / "NativeRender.swift"),
        "packageManifestSHA256": sha(package / "Package.swift"),
        "rendererInputsOrigin": "Copied renderer and manifest bytes; exact executed copies retained, hashes are authoritative",
        "referenceVersion": "1.0.0", "referenceBuild": "1843",
        "productSourceUnmodifiedByRenderer": True,
        "dataOrigin": "nonprivate synthetic fixture; no app store or history read",
    })
    return revision


def png_info(path):
    with path.open("rb") as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError("Renderer output is not a PNG: " + path.name)
    width, height = struct.unpack(">II", header[16:24])
    if not width or not height:
        raise ValueError("Renderer output has no pixels: " + path.name)
    return {"path": path.name, "sha256": sha(path), "bytes": path.stat().st_size,
            "widthPixels": width, "heightPixels": height}


def collect(exit_code, attempt):
    output = attempt_directory(attempt)
    receipt = {
        "schema": "forit.dictate.offscreen-proof.v1", "createdUTC": utc(),
        "attemptID": attempt, "attemptDirectory": str(output),
        "status": "FAILED", "exitCode": exit_code,
        "host": {"name": platform.node(), "osVersion": platform.platform(), "architecture": platform.machine()},
        "method": "SwiftUI.ImageRenderer", "dataOrigin": "nonprivate synthetic fixture",
        "liveBenMacAppearanceProven": False, "installedBuildVerifiedByThisRun": False,
        "images": [], "visualReviewPerformed": False,
        "historySliceIncluded": False,
    }
    files = []
    failure = None
    record = {"schema": "forit.dictate.offscreen-attempt.v1", "attemptID": attempt,
              "output": str(output), "startedUTC": None, "beginRecordRecovered": True}
    try:
        loaded_record = json.loads((output / "attempt.json").read_text(encoding="utf-8"))
        if loaded_record["attemptID"] != attempt:
            raise ValueError("Attempt record belongs to another attempt")
        record = loaded_record
        provenance = output / "source-provenance.json"
        receipt["source"] = json.loads(provenance.read_text(encoding="utf-8"))
        files.append(provenance)
        if receipt["source"]["attemptID"] != attempt:
            raise ValueError("Source provenance belongs to another attempt")
        native = output / "native-render.json"
        if native.exists():
            receipt["nativeRender"] = json.loads(native.read_text(encoding="utf-8"))
            files.append(native)
        for name in ["menu-mark-light.png", "menu-mark-dark.png", "identity-light.png", "identity-dark.png"]:
            path = output / name
            if path.exists():
                row = png_info(path)
                row["appearance"] = "dark" if "dark" in name else "light"
                row["proofScope"] = "Exact source-derived native label" if name.startswith("menu-") else "Branded identity fixture; supplied reference version/build, no installed-app readback"
                receipt["images"].append(row)
                files.append(path)
        resolver = output / "package/Package.resolved"
        if resolver.exists():
            receipt["resolvedPackagesSHA256"] = sha(resolver)
            files.append(resolver)
        if exit_code == 0:
            if len(receipt["images"]) != 4 or not native.exists():
                raise ValueError("Native renderer returned without all four expected images and metadata")
            source = receipt["source"]
            metadata = receipt["nativeRender"]
            if (git("rev-parse", "HEAD") != source["rendererCommit"]
                    or metadata.get("sourceArgument") != source["rendererCommit"]
                    or metadata.get("referenceBuild") != source["referenceBuild"]
                    or metadata.get("referenceVersion") != source["referenceVersion"]
                    or metadata.get("commonDependencyRevision") != source["commonRevision"]
                    or metadata.get("status") != "rendered-fixtures-only"):
                raise ValueError("Native render metadata does not match the current committed source and reference")
            target = output / "package/Tests/DictateOffscreenProofTests"
            for name, expected in [("GeneratedMenuLabel.swift", source["generatedLabelSHA256"]),
                                   ("NativeRender.swift", source["nativeRendererSHA256"])]:
                if sha(target / name) != expected:
                    raise ValueError("Executed source changed after preparation: " + name)
            if sha(output / "package/Package.swift") != source["packageManifestSHA256"]:
                raise ValueError("Package manifest changed after preparation")
            native_images = {item["filename"]: item for item in metadata.get("images", [])}
            if len(native_images) != 4:
                raise ValueError("Native metadata does not describe four distinct images")
            for image in receipt["images"]:
                actual = native_images.get(image["path"], {})
                if (actual.get("pixelWidth") != image["widthPixels"]
                        or actual.get("pixelHeight") != image["heightPixels"]
                        or actual.get("byteCount") != image["bytes"]
                        or actual.get("colorScheme") != image["appearance"]):
                    raise ValueError("Native image metadata mismatch: " + image["path"])
            receipt["status"] = "RENDERED_AWAITING_VISUAL_REVIEW"
    except Exception as error:
        failure = str(error)
        receipt["collectionError"] = failure
    # Preserve partial execution inputs and both logs even when preparation/rendering failed.
    for relative in ["attempt.json", "CommittedVoiceInk.swift", "source-provenance.json",
                     "native-build.log", "native-render.log", "native-render.json",
                     "menu-mark-light.png", "menu-mark-dark.png", "identity-light.png", "identity-dark.png",
                     "package/Package.swift", "package/Package.resolved",
                     "package/Tests/DictateOffscreenProofTests/GeneratedMenuLabel.swift",
                     "package/Tests/DictateOffscreenProofTests/NativeRender.swift"]:
        path = output / relative
        if path.is_file() and path not in files:
            files.append(path)
    output.mkdir(parents=True, exist_ok=True)
    record.update(status=receipt["status"], finishedUTC=utc(), exitCode=exit_code)
    write_json(output / "attempt.json", record)
    if output / "attempt.json" not in files:
        files.append(output / "attempt.json")
    write_json(output / "receipt.json", receipt)
    with zipfile.ZipFile(output / "evidence.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.write(output / "receipt.json", "receipt.json")
        for path in files:
            archive.write(path, str(path.relative_to(output)))
    publish_attempt(output, record)
    if failure:
        raise RuntimeError(failure)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "begin", "path", "prepare", "collect"])
    parser.add_argument("--attempt")
    parser.add_argument("--exit-code", type=int)
    args = parser.parse_args()
    if args.action == "plan" and (args.attempt is not None or args.exit_code is not None):
        parser.error("plan takes no options")
    if args.action in ("begin", "path", "prepare", "collect") and args.attempt is None:
        parser.error("this action requires --attempt UUID")
    if args.action != "collect" and args.exit_code is not None:
        parser.error("only collect accepts --exit-code")
    if args.action == "collect" and args.exit_code is None:
        parser.error("collect requires --exit-code")
    if args.action == "plan":
        print(json.dumps(plan(), indent=2))
    elif args.action == "begin":
        begin(args.attempt)
    elif args.action == "path":
        print(attempt_directory(args.attempt))
    elif args.action == "prepare":
        print(prepare(args.attempt))
    else:
        collect(args.exit_code, args.attempt)
