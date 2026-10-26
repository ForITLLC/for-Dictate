#!/usr/bin/env python3
"""Read-only source inventory, not a build/upload gate or signing validator."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re


PATTERNS = {
    "crossAppAccessibility": re.compile(r"\bAX(?:IsProcessTrusted(?:WithOptions)?|UIElement\w+)\s*\("),
    "hidEventPosting": re.compile(r"\.post\(tap:\s*\.cghidEventTap\)"),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def assess(root):
    root = Path(root).resolve()
    entitlements = root / "VoiceInk/VoiceInk.entitlements"
    project = root / "VoiceInk.xcodeproj/project.pbxproj"
    lock = root / "VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    for path in [entitlements, project, lock]:
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError("Source metadata must be an owned regular project file")
    try:
        claims = plistlib.loads(entitlements.read_bytes())
        pins = json.loads(lock.read_text())["pins"]
        project_lines = project.read_text().splitlines()
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        raise ValueError("Required source metadata is missing or malformed") from error
    if not isinstance(claims, dict) or not isinstance(pins, list):
        raise ValueError("Expected entitlement dictionary and resolved pin list")
    sources = sorted((root / "VoiceInk").rglob("*.swift"))
    findings = {key: [] for key in PATTERNS}
    for path in sources:
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError("Swift source symlinks are outside this inventory contract")
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for key, pattern in PATTERNS.items():
                if pattern.search(line):
                    findings[key].append({"path": str(path.relative_to(root)), "line": number})
    sandbox_settings = [
        {"line": number, "literal": line.strip()}
        for number, line in enumerate(project_lines, 1)
        if "ENABLE_APP_SANDBOX =" in line
    ]
    compatibility = []
    if claims.get("com.apple.security.app-sandbox") is not True:
        compatibility.append("Current app entitlement does not enable App Sandbox")
    if any("= NO;" in row["literal"] for row in sandbox_settings):
        compatibility.append("Project contains explicit unsandboxed build settings; review XPC configurations")
    if findings["crossAppAccessibility"]:
        compatibility.append("Cross-app Accessibility use needs a product compatibility strategy; enabling sandbox is not a behavior-preserving fix")
    if findings["hidEventPosting"]:
        compatibility.append("System-wide keyboard posting/paste requires sandbox compatibility testing; no supported replacement is established")
    return {
        "schema": "forit.dictate.testflight-source-assessment.v1",
        "kind": "ADVISORY_SOURCE_INVENTORY_NOT_EXECUTION_CLEARANCE",
        "liveBuildUploadReady": False,
        "reason": "Source inspection cannot establish product compatibility, approved signing/access, or Apple acceptance",
        "appSandboxEnabled": claims.get("com.apple.security.app-sandbox") is True,
        "appEntitlements": claims,
        "projectSandboxSettingOccurrences": sandbox_settings,
        "swiftFilesInspected": len(sources),
        "sourceFindings": findings,
        "compatibilityIssues": compatibility,
        "resolvedCommonPins": [pin for pin in pins if pin.get("identity") == "for-icommon"],
        "metadataSHA256": {str(path.relative_to(root)): digest(path) for path in [entitlements, project, lock]},
        "externalPrerequisites": [
            "Behavior-preserving sandbox/Accessibility/XPC design, then actual compatibility proof",
            "ASC app ID visible to an authorized release identity; existing zero-match query is scoped",
            "Existing approved Mac App Store distribution certificate/private key and TestFlight provisioning profile",
            "Existing approved package-signing identity where export requires it",
            "Named Apple Account Holder/Admin operational owner; currently unverified",
            "Ben-decided for-Decisions card before any actual security/access/profile/credential change",
        ],
        "limits": [
            "Lexical source inventory, not Swift semantic analysis or complete compiler-input coverage",
            "No network, credential/profile/keychain access, subprocess, build, install, export or upload",
            "Does not modify App Sandbox, app behavior, active workflow or DMG release",
            "No current or future Apple acceptance is inferred",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        result = assess(args.project_root)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
