"""Offline fixtures only. Run: python3 -m unittest discover
with -s scripts -p test_forit_release_evidence.py. No child process is permitted.
"""

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


OFFLINE_GUARD_ACTIVE = False


def offline_guard(event, _arguments):
    if OFFLINE_GUARD_ACTIVE and (event in {"subprocess.Popen", "os.system", "os.exec", "os.posix_spawn", "os.spawn", "os.fork", "os.forkpty"}
                                 or event.startswith("socket.")):
        raise AssertionError("offline evidence fixture refused process/network operation: " + event)


sys.addaudithook(offline_guard)
SPEC = importlib.util.spec_from_file_location("dictate_release_evidence", Path(__file__).with_name("forit-release-evidence.py"))
evidence = importlib.util.module_from_spec(SPEC)
OFFLINE_GUARD_ACTIVE = True
try:
    SPEC.loader.exec_module(evidence)
finally:
    OFFLINE_GUARD_ACTIVE = False


class ReleaseEvidenceTests(unittest.TestCase):
    commit = "a" * 40
    build = "1850"
    version = "1.0.0"

    def setUp(self):
        global OFFLINE_GUARD_ACTIVE
        OFFLINE_GUARD_ACTIVE = True
        self.addCleanup(self.release_guard)
        self.temporary = tempfile.TemporaryDirectory(prefix="dictate-evidence-offline-")
        self.addCleanup(self.temporary.cleanup)
        # macOS /var may itself be a symlink; use its explicit real fixture path.
        self.output = Path(self.temporary.name).resolve() / "output"
        self.output.mkdir()
        self.write_success()

    @staticmethod
    def release_guard():
        global OFFLINE_GUARD_ACTIVE
        OFFLINE_GUARD_ACTIVE = False

    def write(self, name, text):
        path = self.output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def write_json(self, name, value):
        self.write(name, json.dumps(value, ensure_ascii=False))

    def write_success(self):
        self.write("SOURCE.txt", "ForIT Dictate {} ({})\nBuilt from: https://github.com/ForITLLC/for-Dictate/commit/{}\n".format(self.version, self.build, self.commit))
        self.write_json("Package.resolved", {"version": 3, "pins": []})
        for name in ("codesign.txt", "spctl-app.txt", "spctl-dmg.txt"):
            self.write(name, "synthetic assessment only\n")
        self.write("entitlements.plist", plistlib.dumps({"synthetic": True}).decode("utf-8"))
        self.write_json("bundle-info.json", {"bundleId": "io.forit.dictate", "version": self.version, "build": self.build})
        for name in ("notary-app.json", "notary-dmg.json"):
            self.write_json(name, {"status": "Accepted", "id": "11111111-1111-4111-8111-111111111111"})
        self.write_json("integration-tests/synthetic-history-v1.json", {
            "schemaVersion": 1, "updatedAt": "2026-10-30T00:00:00.000Z", "truncated": False,
            "entries": [{"id": "22222222-2222-4222-8222-222222222222", "timestamp": "2026-10-29T00:00:00.000Z",
                         "text": "Synthetic preferred 🙂\n", "rawText": "Synthetic raw", "duration": 1.5}],
        })
        self.test_result = {
            "schema": "forit.dictate.integration-tests.v1", "status": "PASS", "exitCode": 0,
            "testCount": 52, "failureCount": 0, "sourceCommit": self.commit,
            "syntheticFixtureValid": True, "syntheticFixtureSHA256": hashlib.sha256(
                (self.output / "integration-tests/synthetic-history-v1.json").read_bytes()).hexdigest(),
        }
        self.write_json("integration-tests/RESULT.json", self.test_result)
        self.dmg_name = "ForIT-Dictate-{}-{}.dmg".format(self.version, self.build)
        data = b"synthetic DMG fixture; never a signed artifact\x00"
        (self.output / self.dmg_name).write_bytes(data)
        self.dmg_hash = hashlib.sha256(data).hexdigest()
        self.write(self.dmg_name + ".sha256", self.dmg_hash + "  " + self.dmg_name + "\n")

    def run_helper(self, exit_code=0, output=None):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return evidence.main(["--output", str(output or self.output), "--commit", self.commit,
                                  "--build", self.build, "--version", self.version, "--exit-code", str(exit_code)])

    def receipt(self):
        return json.loads((self.output / evidence.RECEIPT_NAME).read_text())

    def test_complete_receipt_retains_exact_utf8_hashes_and_only_allowlisted_files(self):
        self.write("AuthKey_private.p8", "must never be collected")
        self.write("unexpected.json", '{"unapproved":true}')
        self.assertEqual(self.run_helper(), 0)
        receipt = self.receipt()
        self.assertEqual(receipt["status"], "PASS")
        self.assertEqual(set(receipt["files"]), set(evidence.FILES))
        self.assertEqual(receipt["request"]["commit"], self.commit)
        self.assertEqual(receipt["dmg"]["sha256"], self.dmg_hash)
        for name, retained in receipt["files"].items():
            original = (self.output / name).read_bytes()
            self.assertEqual(retained["contentUTF8"].encode("utf-8"), original)
            self.assertEqual(retained["sha256"], hashlib.sha256(original).hexdigest())
            self.assertEqual(retained["byteCount"], len(original))
        self.assertNotIn("must never be collected", json.dumps(receipt))
        self.assertEqual((self.output / evidence.RECEIPT_NAME).stat().st_mode & 0o777, 0o600)

    def test_success_requires_every_curated_file(self):
        for name in evidence.FILES:
            with self.subTest(name=name):
                path = self.output / name
                data = path.read_bytes()
                path.unlink()
                self.assertEqual(self.run_helper(), 1)
                self.assertEqual(self.receipt()["status"], "FAIL")
                path.write_bytes(data)

    def test_original_failure_stays_fail_even_with_complete_or_partial_evidence(self):
        self.assertEqual(self.run_helper(exit_code=27), 0)
        self.assertEqual(self.receipt()["status"], "FAIL")
        self.assertEqual(self.receipt()["exitCode"], 27)
        (self.output / "notary-app.json").unlink()
        self.assertEqual(self.run_helper(exit_code=27), 0)
        self.assertFalse(self.receipt()["evidenceComplete"])
        self.assertEqual(self.receipt()["exitCode"], 27)

    def test_wrong_bundle_tuple_or_unsupported_fields_fail(self):
        for update in ({"bundleId": "wrong"}, {"version": "2.0.0"}, {"build": "1"}, {"extra": True}):
            with self.subTest(update=update):
                self.write_json("bundle-info.json", {"bundleId": "io.forit.dictate", "version": self.version, "build": self.build, **update})
                self.assertEqual(self.run_helper(), 1)

    def test_bundle_build_accepts_integer_representation_without_coercing_bool(self):
        self.write_json("bundle-info.json", {"bundleId": "io.forit.dictate", "version": self.version, "build": int(self.build)})
        self.assertEqual(self.run_helper(), 0)
        self.write_json("bundle-info.json", {"bundleId": "io.forit.dictate", "version": self.version, "build": True})
        self.assertEqual(self.run_helper(), 1)

    def test_notary_requires_accepted_and_valid_id(self):
        for value in ({"status": "In Progress", "id": "11111111-1111-4111-8111-111111111111"},
                      {"status": "Accepted"}, {"status": "Accepted", "id": "invalid"}):
            with self.subTest(value=value):
                self.write_json("notary-dmg.json", value)
                self.assertEqual(self.run_helper(), 1)

    def test_test_receipt_requires_exact_count_source_status_and_fixture_hash(self):
        for update in ({"testCount": 51}, {"testCount": True}, {"failureCount": 1}, {"exitCode": 1},
                       {"status": "FAIL"}, {"schema": "future"}, {"sourceCommit": "b" * 40},
                       {"syntheticFixtureValid": False}, {"syntheticFixtureSHA256": "0" * 64}):
            with self.subTest(update=update):
                self.write_json("integration-tests/RESULT.json", {**self.test_result, **update})
                self.assertEqual(self.run_helper(), 1)

    def test_malformed_duplicate_nonfinite_and_unsupported_json_fail(self):
        for content in ('{', '{"version":3,"version":3,"pins":[]}', '{"version":NaN,"pins":[]}',
                        '{"version":99,"pins":[]}', '[]'):
            with self.subTest(content=content):
                self.write("Package.resolved", content)
                self.assertEqual(self.run_helper(), 1)

    def test_malformed_plist_is_retained_but_never_accepted(self):
        self.write("entitlements.plist", "<plist><dict><key>broken</dict></plist>")
        self.assertEqual(self.run_helper(), 1)
        self.assertIn("entitlements.plist", self.receipt()["files"])
        self.assertEqual(self.receipt()["status"], "FAIL")

    def test_invalid_or_unsupported_fixture_fails_even_when_result_hash_matches(self):
        name = "integration-tests/synthetic-history-v1.json"
        valid = json.loads((self.output / name).read_text())
        for update in ({"schemaVersion": 2}, {"entries": []}, {"updatedAt": "2026-02-30T00:00:00.000Z"}, {"extra": True}):
            with self.subTest(update=update):
                self.write_json(name, {**valid, **update})
                changed = hashlib.sha256((self.output / name).read_bytes()).hexdigest()
                self.write_json("integration-tests/RESULT.json", {**self.test_result, "syntheticFixtureSHA256": changed})
                self.assertEqual(self.run_helper(), 1)

    def test_dmg_and_checksum_must_match_exact_artifact(self):
        for content in ("0" * 64 + "  " + self.dmg_name + "\n", self.dmg_hash + "  other.dmg\n",
                        self.dmg_hash + "  " + self.dmg_name + "\nextra\n"):
            with self.subTest(content=content):
                self.write(self.dmg_name + ".sha256", content)
                self.assertEqual(self.run_helper(), 1)
        (self.output / self.dmg_name).unlink()
        self.assertEqual(self.run_helper(), 1)

    def test_oversized_and_non_utf8_metadata_are_not_embedded(self):
        with (self.output / "codesign.txt").open("wb") as stream:
            stream.truncate(evidence.MAX_FILE_BYTES + 1)
        self.assertEqual(self.run_helper(), 1)
        self.assertNotIn("codesign.txt", self.receipt()["files"])
        (self.output / "codesign.txt").write_bytes(b"\xff")
        self.assertEqual(self.run_helper(), 1)
        self.assertNotIn("codesign.txt", self.receipt()["files"])

    def test_symlink_file_and_parent_are_not_followed(self):
        outside = self.output.parent / "private.txt"
        outside.write_text("outside credential-shaped content")
        (self.output / "codesign.txt").unlink()
        (self.output / "codesign.txt").symlink_to(outside)
        self.assertEqual(self.run_helper(), 1)
        self.assertNotIn("outside credential-shaped content", json.dumps(self.receipt()))
        (self.output / "codesign.txt").unlink()
        self.write("codesign.txt", "synthetic")
        original = self.output / "integration-tests"
        moved = self.output.parent / "moved-integration-tests"
        original.rename(moved)
        original.symlink_to(moved, target_is_directory=True)
        self.assertEqual(self.run_helper(), 1)
        self.assertNotIn("integration-tests/RESULT.json", self.receipt()["files"])

    def test_symlink_output_and_receipt_destination_are_refused(self):
        alias = self.output.parent / "alias"
        alias.symlink_to(self.output, target_is_directory=True)
        self.assertEqual(self.run_helper(output=alias), 1)
        self.assertFalse((self.output / evidence.RECEIPT_NAME).exists())
        target = self.output.parent / "untouched.txt"
        target.write_text("unchanged")
        (self.output / evidence.RECEIPT_NAME).symlink_to(target)
        self.assertEqual(self.run_helper(), 1)
        self.assertEqual(target.read_text(), "unchanged")

    @unittest.skipUnless(hasattr(os, "mkfifo"), "POSIX fixture")
    def test_nonregular_input_is_refused_without_blocking(self):
        (self.output / "codesign.txt").unlink()
        os.mkfifo(self.output / "codesign.txt")
        self.assertEqual(self.run_helper(), 1)

    def test_atomic_write_failure_keeps_previous_receipt_and_removes_temporary(self):
        self.assertEqual(self.run_helper(), 0)
        before = (self.output / evidence.RECEIPT_NAME).read_bytes()
        with patch.object(evidence.os, "replace", side_effect=OSError("synthetic rename refusal")):
            self.assertEqual(self.run_helper(), 1)
        self.assertEqual((self.output / evidence.RECEIPT_NAME).read_bytes(), before)
        self.assertFalse(list(self.output.glob(".release-evidence-*.tmp")))

    def test_offline_guard_refuses_process_and_network_entrypoints(self):
        for event in ("os.fork", "os.forkpty"):
            with self.subTest(event=event), self.assertRaisesRegex(AssertionError, "refused process/network"):
                sys.audit(event)
        with self.assertRaisesRegex(AssertionError, "refused process/network"):
            subprocess.run(["/bin/true"], check=True)
        with self.assertRaisesRegex(AssertionError, "refused process/network"):
            socket.create_connection(("127.0.0.1", 9), timeout=0.01)


if __name__ == "__main__":
    unittest.main()
