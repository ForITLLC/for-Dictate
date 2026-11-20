#!/usr/bin/env python3
"""Pure receipt classification tests with explicitly synthetic files.

No Xcode, native test, command, credential, network or real app binary is used.
The in-memory PASS fixture exercises classification, not native compile proof.
"""
import importlib.util
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("forit_compile_evidence", Path(__file__).with_name("forit-compile-evidence.py"))
EVIDENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVIDENCE)


class CompileEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="forit-compile-receipt-synthetic-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = self.root / "build/forit-compile"
        self.output.mkdir(parents=True)
        for patch in (mock.patch.object(subprocess, "Popen", side_effect=AssertionError("No command is permitted")),
                      mock.patch.object(socket, "socket", side_effect=AssertionError("No network is permitted"))):
            patch.start()
            self.addCleanup(patch.stop)
        logs = {"toolchain.log": "build-slot synthetic fixture\nXcode 27.2\nBuild version SYNTHETIC\n",
                "sdk.log": "27.2\n", "whisper.log": "synthetic dependency fixture\n",
                "resolve.log": "synthetic exact-pin fixture\n", "xcodebuild.log": "** BUILD SUCCEEDED **\n",
                "architectures.log": "x86_64 arm64\n", "source-before.log": "", "source-after.log": "",
                "Package.resolved.log": '{"pins":[]}\n',
                "phases.log": "".join(f"{phase}\t0\tfalse\n" for phase in EVIDENCE.REQUIRED_PHASES)}
        for name, text in logs.items():
            (self.output / name).write_text(text)
        pin = self.root / "VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        pin.parent.mkdir(parents=True)
        pin.write_text(logs["Package.resolved.log"])
        binary = self.root / "build/forit-compile-dd/Build/Products/Release/VoiceInk.app/Contents/MacOS/VoiceInk"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"SYNTHETIC receipt fixture; not a Mach-O or native build")

    def result(self, exit_code=0, phase="complete"):
        return EVIDENCE.receipt(self.root, "a" * 40, exit_code, "2026-11-10T00:00:00Z", phase)

    def testSyntheticControlRequiresBothArchitecturesAndStableInputs(self):
        self.assertEqual(self.result()["status"], "PASS")
        (self.output / "architectures.log").write_text("arm64\n")
        result = self.result()
        self.assertEqual(result["status"], "FAIL")
        self.assertTrue(any("lipo" in problem for problem in result["problems"]))

    def testZeroExitCannotHideCompilerErrorsAmongWarnings(self):
        (self.output / "xcodebuild.log").write_text(
            "warning: mentions error: without being an error\n"
            "A.swift:7:11: error: first genuine error\n"
            "note: second context\nB.swift:9:2: error: second genuine error\n** BUILD SUCCEEDED **\n")
        result = self.result()
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["errorCount"], 2)
        self.assertEqual(result["adapterPreReceiptExit"], 0)
        self.assertEqual(result["adapterExit"], 1)
        self.assertEqual([line["lineNumber"] for line in result["errorLines"]], [2, 4])

    def testNonzeroAdapterExitNeverClaimsPass(self):
        result = self.result(exit_code=65, phase="compile")
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["adapterExit"], 65)

    def testTimeoutDoesNotInventCompilerExitOrFinalErrors(self):
        (self.output / "phases.log").write_text("compile\tunknown\ttrue\n")
        result = self.result(exit_code=124, phase="compile")
        self.assertEqual(result["status"], "FAIL")
        self.assertIsNone(result["phases"]["compile"]["processExit"])
        self.assertFalse(result["errorLinesFinal"])
        self.assertTrue(result["ownedChildMayStillRun"])

    def testChangedPackagePinFailsEvenWithSuccessfulCompilerMarkers(self):
        (self.output / "Package.resolved.log").write_text('{"pins":["changed"]}\n')
        result = self.result()
        self.assertEqual(result["status"], "FAIL")
        self.assertTrue(any("source pin" in problem for problem in result["problems"]))


if __name__ == "__main__":
    unittest.main()
