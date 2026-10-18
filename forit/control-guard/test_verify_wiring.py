"""Mutation regressions for source-preparation evidence; no native tools or network."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("verify_wiring", Path(__file__).with_name("verify_wiring.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
SOURCE_ROOT = Path(__file__).resolve().parents[2]


def openstep(value):
    if isinstance(value, dict):
        return "{\n" + "\n".join(json.dumps(k) + " = " + openstep(v) + ";" for k, v in value.items()) + "\n}"
    if isinstance(value, list):
        return "(" + ",".join(openstep(v) for v in value) + ")"
    return json.dumps(value)


class WiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project_data = checker.OpenStep((SOURCE_ROOT / checker.PROJECT).read_text()).parse()
        cls.config = json.loads((SOURCE_ROOT / "forit-app.json").read_text())
        cls.manifests = {e["inputs"]: json.loads((SOURCE_ROOT / e["inputs"]).read_text())
                         for records in cls.config["controlGuard"]["targets"].values() for e in records}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = copy.deepcopy(self.project_data)
        self.write_project()
        self.write("forit-app.json", self.config)
        for relative, manifest in self.manifests.items():
            self.write(relative, manifest)
            for source in manifest["sources"]:
                path = self.root / source
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// offline fixture\n")

    def write(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2) + "\n")

    def write_project(self):
        path = self.root / checker.PROJECT
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(openstep(self.project))

    def manifest(self, target="VoiceInk"):
        path = self.root / ("forit/control-guard/" + target + "-macOS-inputs.json")
        return path, json.loads(path.read_text())

    def native_target(self, name="VoiceInk"):
        return next(v for v in self.project["objects"].values() if v.get("isa") == "PBXNativeTarget" and v.get("name") == name)

    def guard_phase(self):
        return self.project["objects"][self.native_target()["buildPhases"][0]]

    def rename_shared_swift(self, declaration="explicitFileType", include_in_manifests=False):
        old = "Shared/VoiceInkRefineXPCProtocol.swift"
        new = "Shared/VoiceInkRefineXPCProtocol.inc"
        (self.root / old).rename(self.root / new)
        reference = next(v for v in self.project["objects"].values()
                         if v.get("isa") == "PBXFileReference" and v.get("path") == Path(old).name)
        reference["path"] = Path(new).name
        reference[declaration] = "sourcecode.swift"
        for name in ("VoiceInk", "VoiceInkRefineXPC"):
            path, manifest = self.manifest(name)
            manifest["sources"].remove(old)
            if include_in_manifests:
                manifest["sources"].append(new)
                manifest["sources"].sort()
            path.write_text(json.dumps(manifest))
        self.write_project()

    def assert_rejected(self, message):
        with self.assertRaisesRegex(checker.VerificationError, message):
            checker.verify(self.root)

    def test_source_preparation_pass_cannot_be_production_pass(self):
        report = checker.verify(self.root)
        self.assertEqual(report["state"], "PASS_PREPARATION_ONLY")
        self.assertFalse(report["fullBuildCompileInputsProven"])
        self.assertFalse(report["productionGuardAdmitted"])
        self.assertEqual(set(report["targets"]), {"VoiceInk", "VoiceInkRefineXPC"})

    def test_explicit_shared_source_is_required_in_both_targets(self):
        for name in ("VoiceInk", "VoiceInkRefineXPC"):
            with self.subTest(name=name):
                path, manifest = self.manifest(name)
                original = path.read_text()
                self.assertIn("Shared/VoiceInkRefineXPCProtocol.swift", manifest["sources"])
                manifest["sources"].remove("Shared/VoiceInkRefineXPCProtocol.swift")
                path.write_text(json.dumps(manifest))
                self.assert_rejected("compile inputs differ")
                path.write_text(original)

    def test_renamed_explicit_swift_source_cannot_be_omitted(self):
        self.rename_shared_swift()
        self.assert_rejected("VoiceInkRefineXPCProtocol.inc")

    def test_renamed_last_known_swift_source_cannot_be_omitted(self):
        self.rename_shared_swift(declaration="lastKnownFileType")
        self.assert_rejected("VoiceInkRefineXPCProtocol.inc")

    def test_renamed_explicit_swift_source_is_counted_when_listed(self):
        self.rename_shared_swift(include_in_manifests=True)
        report = checker.verify(self.root)
        self.assertEqual(report["targets"]["VoiceInk"]["projectOwnedSwiftCompileInputs"], 352)
        self.assertEqual(report["targets"]["VoiceInkRefineXPC"]["projectOwnedSwiftCompileInputs"], 4)

    def test_unsupported_explicit_source_type_rejected(self):
        reference = next(v for v in self.project["objects"].values()
                         if v.get("isa") == "PBXFileReference" and v.get("path") == "VoiceInkRefineXPCProtocol.swift")
        reference["explicitFileType"] = "sourcecode.unreviewed"
        self.write_project()
        self.assert_rejected("unsupported declared Sources file type")

    def test_new_synchronized_source_cannot_be_omitted(self):
        path = self.root / "VoiceInk/Tests/Preview/Vendor/ReachableControl.swift"
        path.parent.mkdir(parents=True)
        path.write_text("import SwiftUI\n")
        self.assert_rejected("ReachableControl.swift")

    def test_new_native_control_source_cannot_be_omitted(self):
        path = self.root / "VoiceInk/LocalControl.m"
        path.write_text("@import AppKit;\n")
        self.assert_rejected("LocalControl.m")

    def reject_synchronized_compiler_input(self, suffix):
        path = self.root / ("VoiceInk/AddedControl" + suffix)
        path.write_text("// offline unsupported compiler-input fixture\n")
        try:
            self.assert_rejected("unsupported synchronized compiler input")
        finally:
            path.unlink()

    def test_synchronized_assembly_source_cannot_be_silently_omitted(self):
        self.reject_synchronized_compiler_input(".s")

    def test_synchronized_preprocessed_assembly_source_cannot_be_silently_omitted(self):
        self.reject_synchronized_compiler_input(".S")

    def test_synchronized_metal_source_cannot_be_silently_omitted(self):
        self.reject_synchronized_compiler_input(".metal")

    def test_other_known_unsupported_synchronized_compiler_inputs_rejected(self):
        for suffix in (".asm", ".y", ".ym", ".yacc", ".l", ".lm", ".lex", ".cp", ".c++", ".i", ".ii", ".mi", ".mii", ".defs", ".mig", ".cl", ".ll", ".f90"):
            with self.subTest(suffix=suffix):
                self.reject_synchronized_compiler_input(suffix)

    def test_excluded_unsupported_compiler_input_does_not_create_membership(self):
        path = self.root / "VoiceInk/NotCompiled.metal"
        path.write_text("// fixture excluded by actual target membership\n")
        target = self.native_target()
        group = self.project["objects"][target["fileSystemSynchronizedGroups"][0]]
        exception = self.project["objects"][group["exceptions"][0]]
        exception["membershipExceptions"].append(path.name)
        self.write_project()
        checker.verify(self.root)

    def test_ordinary_synchronized_resources_are_still_allowed(self):
        for suffix in (".json", ".png", ".svg", ".wav", ".scpt"):
            path = self.root / ("VoiceInk/OrdinaryResource" + suffix)
            path.write_text("offline resource fixture\n")
        report = checker.verify(self.root)
        self.assertEqual(report["targets"]["VoiceInk"]["projectOwnedSwiftCompileInputs"], 352)
        self.assertFalse(report["productionGuardAdmitted"])

    def test_real_synchronized_membership_exception_is_respected(self):
        path = self.root / "VoiceInk/ExcludedControl.swift"
        path.write_text("import SwiftUI\n")
        target = self.native_target()
        group = self.project["objects"][target["fileSystemSynchronizedGroups"][0]]
        exception = self.project["objects"][group["exceptions"][0]]
        exception["membershipExceptions"].append("ExcludedControl.swift")
        self.write_project()
        checker.verify(self.root)

    def test_duplicate_manifest_input_rejected(self):
        path, manifest = self.manifest()
        manifest["sources"].append(manifest["sources"][0])
        path.write_text(json.dumps(manifest))
        self.assert_rejected("duplicate/invalid")

    def test_manifest_root_escape_rejected(self):
        path, manifest = self.manifest()
        manifest["root"] = "../../.."
        path.write_text(json.dumps(manifest))
        self.assert_rejected("manifest root mismatch")

    def test_wrong_platform_rejected(self):
        path, manifest = self.manifest()
        manifest["platform"] = "iOS"
        path.write_text(json.dumps(manifest))
        self.assert_rejected("identity mismatch")

    def test_omitted_xpc_target_rejected(self):
        config = copy.deepcopy(self.config)
        del config["controlGuard"]["targets"]["VoiceInkRefineXPC"]
        self.write("forit-app.json", config)
        self.assert_rejected("including XPC")

    def test_guard_after_compile_rejected(self):
        phases = self.native_target()["buildPhases"]
        phases[0], phases[1] = phases[1], phases[0]
        self.write_project()
        self.assert_rejected("must be first")

    def test_dependency_analysis_skip_rejected(self):
        self.guard_phase().pop("alwaysOutOfDate")
        self.write_project()
        self.assert_rejected("every build")

    def test_error_swallowing_rejected(self):
        self.guard_phase()["shellScript"] += "true\n"
        self.write_project()
        self.assert_rejected("directly exec")

    def test_custom_wrapper_rejected(self):
        self.guard_phase()["shellScript"] = "exec ./guard-wrapper.sh\n"
        self.write_project()
        self.assert_rejected("directly exec")

    def test_report_mismatch_rejected(self):
        config = copy.deepcopy(self.config)
        config["controlGuard"]["targets"]["VoiceInk"][0]["report"] = "/tmp/some-other-report.json"
        self.write("forit-app.json", config)
        self.assert_rejected("wrong inputs/report")

    def test_disabled_sandboxing_in_all_configurations_rejected(self):
        for item in self.project["objects"].values():
            if item.get("isa") == "XCBuildConfiguration":
                item["buildSettings"]["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO"
        self.write_project()
        self.assert_rejected("ENABLE_USER_SCRIPT_SANDBOXING must be YES")

    def test_target_sandbox_override_rejected_for_each_shipping_configuration(self):
        for name in ("VoiceInk", "VoiceInkRefineXPC"):
            target = self.native_target(name)
            configuration_list = self.project["objects"][target["buildConfigurationList"]]
            for configuration_id in configuration_list["buildConfigurations"]:
                with self.subTest(target=name, configuration=configuration_id):
                    item = self.project["objects"][configuration_id]
                    original = copy.deepcopy(item["buildSettings"])
                    item["buildSettings"]["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO"
                    self.write_project()
                    self.assert_rejected("ENABLE_USER_SCRIPT_SANDBOXING must be YES")
                    item["buildSettings"] = original
        self.write_project()

    def test_source_selection_override_rejected(self):
        config_list = self.project["objects"][self.native_target()["buildConfigurationList"]]
        first_config = self.project["objects"][config_list["buildConfigurations"][0]]
        first_config["buildSettings"]["EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]"] = "LocalControl.swift"
        self.write_project()
        self.assert_rejected("conditional source selection")

    def test_external_xcconfig_cannot_hide_source_selection(self):
        config_list = self.project["objects"][self.native_target()["buildConfigurationList"]]
        first_config = self.project["objects"][config_list["buildConfigurations"][0]]
        first_config["baseConfigurationReference"] = "EXTERNALCONFIG"
        self.write_project()
        self.assert_rejected("xcconfig-derived settings")

    def test_symlink_source_rejected(self):
        _, manifest = self.manifest()
        path = self.root / manifest["sources"][0]
        path.unlink()
        path.symlink_to(self.root / manifest["sources"][1])
        self.assert_rejected("symlink")

    def test_comments_do_not_create_membership(self):
        path = self.root / checker.PROJECT
        path.write_text('/* fake.swift; fileSystemSynchronizedGroups = (BAD); */\n' + path.read_text())
        checker.verify(self.root)


if __name__ == "__main__":
    unittest.main()
