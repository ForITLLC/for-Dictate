import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("assessment", ROOT / "scripts/forit-testflight-assess.py")
ASSESSMENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ASSESSMENT)


class AssessmentTests(unittest.TestCase):
    def fixture(self, root, sandbox=True, code="struct LocalView {}"):
        for directory in ["VoiceInk", "VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"]:
            (root / directory).mkdir(parents=True, exist_ok=True)
        (root / "VoiceInk/VoiceInk.entitlements").write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": sandbox}))
        (root / "VoiceInk/Feature.swift").write_text(code)
        (root / "VoiceInk.xcodeproj/project.pbxproj").write_text("ENABLE_APP_SANDBOX = YES;\n")
        (root / "VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").write_text(json.dumps({"pins": []}))

    def test_turning_on_sandbox_does_not_clear_actual_accessibility_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, sandbox=True, code="let app = AXUIElementCreateApplication(pid)\n")
            result = ASSESSMENT.assess(root)
            self.assertTrue(result["appSandboxEnabled"])
            self.assertEqual(len(result["sourceFindings"]["crossAppAccessibility"]), 1)
            self.assertTrue(any("product compatibility" in issue for issue in result["compatibilityIssues"]))
            self.assertFalse(result["liveBuildUploadReady"])

    def test_hid_paste_is_independent_of_accessibility_symbol_presence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, code="event.post(tap: .cghidEventTap)\n")
            result = ASSESSMENT.assess(root)
            self.assertEqual(result["sourceFindings"]["crossAppAccessibility"], [])
            self.assertEqual(len(result["sourceFindings"]["hidEventPosting"]), 1)
            self.assertTrue(any("keyboard posting" in issue for issue in result["compatibilityIssues"]))

    def test_metadata_only_cannot_assert_live_apple_acceptance_and_does_not_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            before = {str(path): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            result = ASSESSMENT.assess(root)
            after = {str(path): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            self.assertEqual(before, after)
            self.assertFalse(result["liveBuildUploadReady"])
            self.assertEqual(result["compatibilityIssues"], [])
            self.assertTrue(result["externalPrerequisites"])

    def test_malformed_entitlements_are_not_treated_as_compatible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / "VoiceInk/VoiceInk.entitlements").write_text("not a plist")
            with self.assertRaises(ValueError):
                ASSESSMENT.assess(root)

    def test_external_swift_symlink_is_not_read(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            self.fixture(root)
            target = Path(outside) / "External.swift"
            target.write_text("let value = AXUIElementCreateApplication(pid)")
            (root / "VoiceInk/External.swift").symlink_to(target)
            with self.assertRaises(ValueError):
                ASSESSMENT.assess(root)


if __name__ == "__main__":
    unittest.main()
