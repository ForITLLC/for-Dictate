"""The screen check's contract, on throwaway Git repositories.

Only the real script is copied. The device matrix is replaced with a recorder that writes the
rows it is told to, so nothing is built, booted or photographed.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name("ui-check.sh")
MATRIX = r"""#!/bin/bash
set -euo pipefail
mkdir -p "$2"
python3 - "$@" <<'PY'
import json, os, pathlib, shutil, sys
out = pathlib.Path(sys.argv[2])
rows = json.loads(os.environ["UI_CHECK_FIXTURE_ROWS"])
(out / "MATRIX.tsv").write_text("".join("\t".join(r) + "\n" for r in rows))
for device, screen, look, status in rows:
    if status == "ok":
        (out / f"{device}-{screen}-{look}.png").write_bytes(b"png")
(out / "sheet-iphone.jpg").write_bytes(b"jpg")
(out / "PACKAGES").write_text("no packages\n")
(out / ".dd").mkdir()
(out / ".dd" / "big").write_text("derived data\n")
pathlib.Path(os.environ["UI_CHECK_FIXTURE_RECORD"]).write_text(json.dumps({
    "args": sys.argv[1:], "xcodebuild": shutil.which("xcodebuild"),
    "lane": os.environ.get("MATRIX_LANE"), "run": os.environ.get("MATRIX_RUN"),
    "boot": os.environ.get("MATRIX_BOOT")}))
PY
exit "${UI_CHECK_FIXTURE_EXIT:-0}"
"""
OK = [["iphone", "home", "light", "ok"], ["iphone", "keyboard", "ax5", "ok"]]


class UICheckContractTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dictate screen check ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.template = self.root / "empty git template"
        self.template.mkdir()
        self.home = self.root / "home"
        self.fakes = self.root / "fakes"
        for folder in (self.home / "bin", self.fakes):
            folder.mkdir(parents=True)
        # The build Mac, as far as the script asks: its name and its slot-aware xcodebuild.
        self.executable(self.fakes / "uname", "#!/bin/bash\necho Darwin\n")
        self.executable(self.home / "bin/xcodebuild", "#!/bin/bash\nexit 0\n")
        self.env = {
            "PATH": str(self.fakes) + os.pathsep + os.environ.get("PATH", os.defpath),
            "HOME": str(self.home), "LANG": "C", "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TEMPLATE_DIR": str(self.template),
        }
        self.common = self.root / "for-iCommon"
        self.executable(self.common / "Scripts/device-matrix/device-matrix.sh", MATRIX)
        self.common_head = self.commit(self.common)
        self.repo = self.root / "source checkout"
        self.script = self.repo / "ios/Scripts/ui-check.sh"
        self.script.parent.mkdir(parents=True)
        self.script.write_bytes(SCRIPT.read_bytes())
        (self.repo / ".gitignore").write_text("build/\n")
        (self.repo / "forit-app.json").write_text(
            json.dumps({"controlGuard": {"commonRevision": self.common_head}}))
        (self.repo / "ios/forit-app.json").write_text(
            json.dumps({"screens": {"scheme": "ForITDictate", "list": [{"name": "home", "args": []}]}}))
        self.head = self.commit(self.repo)
        self.run_state = self.root / "gate run"
        self.run_state.mkdir()
        (self.run_state / "lane").write_text("for-Dictate\n")
        (self.run_state / "up").write_text("")
        self.record = self.root / "matrix record.json"
        self.out = self.repo / "build/forit-ios-ui-check"

    @staticmethod
    def executable(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def commit(self, repo):
        def git(*args):
            return subprocess.run(
                [shutil.which("git"), "-C", str(repo), "-c", "user.name=Fixture",
                 "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=" + str(self.template), *args],
                env=self.env, check=True, capture_output=True, text=True).stdout.strip()
        git("init", "-q")
        git("add", ".")
        git("commit", "-qm", "fixture")
        return git("rev-parse", "HEAD")

    def invoke(self, *args, rows=OK, matrix_exit=0, **changes):
        env = dict(self.env, FORIT_SOURCE_COMMIT=self.head, FORIT_GATE_RUN=str(self.run_state),
                   FORIT_COMMON_ROOT=str(self.common), UI_CHECK_FIXTURE_ROWS=json.dumps(rows),
                   UI_CHECK_FIXTURE_RECORD=str(self.record), UI_CHECK_FIXTURE_EXIT=str(matrix_exit))
        for name, value in changes.items():
            if value is None:
                env.pop(name, None)
            else:
                env[name] = value
        return subprocess.run(["/bin/bash", str(self.script), *args], cwd=self.root, env=env,
                              capture_output=True, text=True)

    def receipt(self):
        return json.loads((self.out / "receipt.json").read_text())

    def test_plan_names_the_screens_and_runs_nothing(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["matrix"]["screens"], ["home"])
        self.assertEqual(plan["matrix"]["boots"], ["iPhone", "iPhoneSE", "iPhoneProMax"])
        self.assertEqual(plan["forITCommonRevision"], self.common_head)
        self.assertFalse(plan["nativeExecution"])
        self.assertFalse(self.record.exists())
        self.assertFalse((self.repo / "build").exists())

    def test_every_cell_taken_passes_with_the_pictures_as_evidence(self):
        result = self.invoke("--execute")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = self.receipt()
        self.assertTrue(receipt["passed"])
        self.assertEqual(receipt["cells"], {"taken": 2, "failed": 0, "notDrawn": 0})
        self.assertEqual(receipt["commit"], self.head)
        self.assertFalse(receipt["signed"])
        with zipfile.ZipFile(self.out / "evidence.zip") as bundle:
            self.assertEqual(sorted(bundle.namelist()), [
                "MATRIX.tsv", "PACKAGES", "iphone-home-light.png", "iphone-keyboard-ax5.png", "sheet-iphone.jpg"])
        record = json.loads(self.record.read_text())
        self.assertEqual(record["args"], [str(self.repo / "ios"), str(self.out / "matrix"), "iphone"])
        self.assertEqual(record["xcodebuild"], str(self.home / "bin/xcodebuild"))
        self.assertEqual(record["lane"], "for-Dictate")
        self.assertEqual(record["run"], str(self.run_state))
        # The SE and the Pro Max are drawn only when the job names them.
        self.assertEqual(record["boot"], "iPhone iPhoneSE iPhoneProMax")

    def test_a_run_with_no_picture_does_not_pass(self):
        why = "not drawn: for-Dictate has no iPhone simulator on the Mini (ci-sim-lanes.conf)"
        result = self.invoke("--execute", rows=[["iphone", "home", "light", why]])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        receipt = self.receipt()
        self.assertFalse(receipt["passed"])
        self.assertEqual(receipt["cells"], {"taken": 0, "failed": 0, "notDrawn": 1})
        self.assertEqual(receipt["notDrawn"], [why])
        self.assertEqual(receipt["lastPhase"], "evidence")
        self.assertIn("no screen was drawn. " + why, result.stderr)

    def test_a_failed_cell_fails_the_check_and_is_named(self):
        rows = OK + [["iphone", "settings", "dark", "failed: black frame"]]
        result = self.invoke("--execute", rows=rows, matrix_exit=1)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        receipt = self.receipt()
        self.assertFalse(receipt["passed"])
        self.assertEqual(receipt["matrixExit"], "1")
        self.assertEqual(receipt["failedCells"], [
            {"device": "iphone", "screen": "settings", "look": "dark", "why": "failed: black frame"}])

    def test_refused_before_the_matrix(self):
        other = self.root / "other common"
        self.executable(other / "Scripts/device-matrix/device-matrix.sh", MATRIX + "# another revision\n")
        self.commit(other)
        cases = {
            "another commit": {"FORIT_SOURCE_COMMIT": "0" * 40},
            "no gate run": {"FORIT_GATE_RUN": None},
            "no Common": {"FORIT_COMMON_ROOT": None},
            "another Common revision": {"FORIT_COMMON_ROOT": str(other)},
            "another xcodebuild": {"FORIT_XCODEBUILD": "/usr/bin/xcodebuild"},
            "GitHub Actions": {"GITHUB_ACTIONS": "true"},
        }
        for name, changes in cases.items():
            with self.subTest(name):
                shutil.rmtree(self.repo / "build", ignore_errors=True)
                result = self.invoke("--execute", **changes)
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertFalse(self.record.exists(), "a refused request reached the matrix")
                self.assertFalse(self.receipt()["passed"])

    def test_untracked_source_and_a_prior_output_are_refused(self):
        (self.repo / "stray.swift").write_text("// not committed\n")
        result = self.invoke("--execute")
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertFalse(self.record.exists())
        (self.repo / "stray.swift").unlink()
        # The output of that run is still there, and a second run leaves it alone.
        before = (self.out / "receipt.json").read_bytes()
        result = self.invoke("--execute")
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertEqual((self.out / "receipt.json").read_bytes(), before)
        self.assertFalse(self.record.exists())


if __name__ == "__main__":
    unittest.main()
