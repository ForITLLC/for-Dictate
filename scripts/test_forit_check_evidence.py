"""Portable synthetic retention tests. Run this module in its own Python process:
its unconditional audit guard rejects every process/network operation, including
those attempted while importing the production helper. No native main is called.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


def offline_guard(event, _arguments):
    if event in {"subprocess.Popen", "os.system", "os.exec", "os.posix_spawn", "os.spawn", "os.fork", "os.forkpty"} or event.startswith("socket."):
        raise AssertionError("Offline check evidence refused a process/network operation: " + event)


sys.addaudithook(offline_guard)
SPEC = importlib.util.spec_from_file_location("dictate_check_evidence", Path(__file__).with_name("check-dictate-integrations.py"))
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


class CheckEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dictate-check-evidence-offline-")
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name).resolve()
        self.destination = self.output / "check-evidence.log"
        self.fixture = self.output / "synthetic-history-v1.json"
        value = {"schemaVersion": 1, "updatedAt": "2026-10-30T00:00:00.000Z", "truncated": False,
                 "entries": [{"id": "22222222-2222-4222-8222-222222222222", "timestamp": "2026-10-29T00:00:00.000Z",
                              "text": "Synthetic preferred é🙂\n", "rawText": "Synthetic raw", "duration": 1.5}]}
        self.data = json.dumps(value, ensure_ascii=False, indent=2).encode("utf-8") + b"\r\n"
        self.fixture.write_bytes(self.data)
        self.receipt = {
            "schema": "forit.dictate.integration-tests.v1", "status": "PASS", "exitCode": 0,
            "sourceCommit": "a" * 40, "sourceSHA256": {"synthetic/source.swift": "b" * 64},
            "jobs": 1, "processGroup": "inherited", "timeoutSeconds": 600,
            "expectedTestCount": 52, "testCount": 52, "failureCount": 0,
            "testSummaryComplete": True, "timeout_cleanup_delegated": False,
            "retained_package_relative_path": None, "syntheticFixtureValid": True,
            "syntheticFixtureSHA256": hashlib.sha256(self.data).hexdigest(),
            "applicationLaunched": False, "userHistoryOrClipboardRead": False,
        }

    def retained(self):
        return json.loads(self.destination.read_text(encoding="utf-8"))

    def test_completed_checks_retain_exact_original_utf8_hash_and_entire_receipt(self):
        evidence.write_check_evidence(self.output, self.receipt)
        retained = self.retained()
        self.assertEqual(retained["status"], "PASS")
        self.assertEqual(retained["receipt"], self.receipt)
        fixture = retained["syntheticFixture"]
        self.assertEqual(fixture["contentUTF8"].encode("utf-8"), self.data)
        self.assertEqual(fixture["sha256"], self.receipt["syntheticFixtureSHA256"])
        self.assertEqual(fixture["byteCount"], len(self.data))
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)

    def test_failure_and_timeout_stay_fail_without_reading_live_fixture(self):
        for code, timed_out in [(27, False), (124, True)]:
            with self.subTest(exitCode=code):
                receipt = dict(self.receipt, status="FAIL", exitCode=code, syntheticFixtureValid=False,
                               testSummaryComplete=False, timeout_cleanup_delegated=timed_out,
                               retained_package_relative_path="synthetic-package-owned" if timed_out else None)
                with patch.object(Path, "read_bytes", side_effect=AssertionError("Live fixture must not be read")):
                    evidence.write_check_evidence(self.output, receipt)
                retained = self.retained()
                self.assertEqual(retained["status"], "FAIL")
                self.assertEqual(retained["receipt"], receipt)
                self.assertNotIn("syntheticFixture", retained)

    def test_write_failure_raises_and_removes_old_pass_evidence(self):
        self.destination.write_text('{"status":"PASS","stale":true}', encoding="utf-8")
        with patch.object(os, "open", side_effect=PermissionError("Synthetic write refusal")):
            with self.assertRaises(PermissionError):
                evidence.write_check_evidence(self.output, self.receipt)
        self.assertFalse(self.destination.exists())

    def test_changed_fixture_cannot_be_retained_as_a_completed_pass(self):
        self.destination.write_text('{"status":"PASS","stale":true}', encoding="utf-8")
        self.fixture.write_bytes(self.data + b" ")
        with self.assertRaisesRegex(ValueError, "no longer matches"):
            evidence.write_check_evidence(self.output, self.receipt)
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
