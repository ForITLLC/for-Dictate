"""The screen check's contract, on throwaway Git repositories.

Only the real script is copied. The device matrix is replaced with a recorder that writes the
rows it is told to, and the lane's simulator helper with one that only notes its calls, so
nothing is built, booted or photographed.
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
# As the real matrix does on the build Mac: it draws the kind MATRIX_BOOT names and says of the
# other phones that they are for a job of their own.
MATRIX = r"""#!/bin/bash
set -euo pipefail
mkdir -p "$2"
python3 - "$@" <<'PY'
import json, os, pathlib, shutil, sys
out = pathlib.Path(sys.argv[2])
kind = os.environ.get("MATRIX_BOOT", "")
mine = {"iPhone": "iphone", "iPhoneSE": "iphone-se", "iPhoneProMax": "iphone-max"}.get(kind)
rows = []
for device, screen, look, status in json.loads(os.environ["UI_CHECK_FIXTURE_ROWS"]):
    if device != mine:
        status = f"not drawn: the Mini boots the {kind} one after another in a job; MATRIX_BOOT=x in a job of its own draws it"
    rows.append([device, screen, look, status])
    if status == "ok":
        (out / f"{device}-{screen}-{look}.png").write_bytes(b"png")
(out / "MATRIX.tsv").write_text("".join("\t".join(r) + "\n" for r in rows))
(out / "sheet-iphone.jpg").write_bytes(b"jpg")
(out / "PACKAGES").write_text("no packages\n")
(out / ".dd").mkdir()
(out / ".dd" / "big").write_text("derived data\n")
with open(os.environ["UI_CHECK_FIXTURE_RECORD"], "a") as record:
    record.write(json.dumps({
        "args": sys.argv[1:], "xcodebuild": shutil.which("xcodebuild"), "boot": kind,
        "lane": os.environ.get("MATRIX_LANE"), "run": os.environ.get("MATRIX_RUN"),
        "helper": os.environ.get("MATRIX_LANE_HELPER"), "derived": os.environ.get("MATRIX_DERIVED_DATA"),
        "up": pathlib.Path(os.environ["MATRIX_RUN"], "up").read_text().split()}) + "\n")
PY
exit "${UI_CHECK_FIXTURE_EXIT:-0}"
"""
# ci-sim-lane.sh as far as the script asks: boot prints the slot's queue and then the UDID.
HELPER = r"""#!/bin/bash
printf '%s\n' "$*" >> "$UI_CHECK_FIXTURE_HELPER_LOG"
[[ $1 == --lane && $2 == for-Dictate ]] || exit 3
case $3 in
  boot)
    case " ${UI_CHECK_FIXTURE_NO_BOOT:-} " in *" $4 "*) echo "the gate gave up" >&2; exit 75 ;; esac
    echo "boot-slot ok waited=0s"
    case $4 in
      iPhone) echo 11111111-1111-1111-1111-111111111111 ;;
      iPhoneSE) echo 22222222-2222-2222-2222-222222222222 ;;
      iPhoneProMax) echo 33333333-3333-3333-3333-333333333333 ;;
      *) exit 4 ;;
    esac ;;
  shutdown) exit "${UI_CHECK_FIXTURE_SHUTDOWN_EXIT:-0}" ;;
  *) exit 2 ;;
esac
"""
UDIDS = ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222",
         "33333333-3333-3333-3333-333333333333"]
KINDS = ["iPhone", "iPhoneSE", "iPhoneProMax"]
OK = [["iphone", "home", "light", "ok"], ["iphone", "keyboard", "ax5", "ok"],
      ["iphone-se", "home", "light", "ok"], ["iphone-max", "home", "dark", "ok"]]


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
        # The build Mac, as far as the script asks: its name, its slot-aware xcodebuild and the
        # lane's simulator helper.
        self.executable(self.fakes / "uname", "#!/bin/bash\necho Darwin\n")
        self.executable(self.home / "bin/xcodebuild", "#!/bin/bash\nexit 0\n")
        self.helper = self.root / "ci-sim/ci-sim-lane.sh"
        self.executable(self.helper, HELPER)
        self.helper_log = self.root / "helper calls.log"
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
        self.record = self.root / "matrix record.jsonl"
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
                   FORIT_COMMON_ROOT=str(self.common), MATRIX_LANE_HELPER=str(self.helper),
                   UI_CHECK_FIXTURE_ROWS=json.dumps(rows), UI_CHECK_FIXTURE_RECORD=str(self.record),
                   UI_CHECK_FIXTURE_HELPER_LOG=str(self.helper_log), UI_CHECK_FIXTURE_EXIT=str(matrix_exit))
        for name, value in changes.items():
            if value is None:
                env.pop(name, None)
            else:
                env[name] = value
        return subprocess.run(["/bin/bash", str(self.script), *args], cwd=self.root, env=env,
                              capture_output=True, text=True)

    def receipt(self):
        return json.loads((self.out / "receipt.json").read_text())

    def matrix_runs(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()]

    def helper_calls(self):
        return self.helper_log.read_text().splitlines() if self.helper_log.exists() else []

    def test_plan_names_the_screens_and_runs_nothing(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["matrix"]["screens"], ["home"])
        self.assertEqual(plan["matrix"]["boots"], KINDS)
        self.assertEqual(plan["forITCommonRevision"], self.common_head)
        self.assertFalse(plan["nativeExecution"])
        self.assertFalse(self.record.exists())
        self.assertEqual(self.helper_calls(), [])
        self.assertFalse((self.repo / "build").exists())

    def test_each_phone_is_booted_drawn_and_shut_down_in_turn(self):
        result = self.invoke("--execute")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = self.receipt()
        self.assertTrue(receipt["passed"])
        self.assertTrue(receipt["complete"])
        # Each run's table also names the other two phones; a cell is counted once.
        self.assertEqual(receipt["cells"], {"taken": 4, "failed": 0, "notDrawn": 0})
        self.assertEqual(receipt["notBooted"], {})
        self.assertEqual(receipt["commit"], self.head)
        self.assertFalse(receipt["signed"])
        with zipfile.ZipFile(self.out / "evidence.zip") as bundle:
            names = bundle.namelist()
            merged = bundle.read("MATRIX.tsv").decode()
        self.assertEqual(sorted(names), sorted(
            ["MATRIX.tsv", "boot.log", "iphone-home-light.png", "iphone-keyboard-ax5.png",
             "iphone-se-home-light.png", "iphone-max-home-dark.png"]
            + [f"{kind}-{name}" for kind in KINDS for name in ("MATRIX.tsv", "PACKAGES", "sheet-iphone.jpg")]))
        self.assertEqual(merged.count("\tok\n"), 4)
        self.assertEqual(self.helper_calls(), [
            f"--lane for-Dictate {verb} {kind}" for kind in KINDS for verb in ("boot", "shutdown")])
        runs = self.matrix_runs()
        self.assertEqual([run["boot"] for run in runs], KINDS)
        for index, run in enumerate(runs):
            self.assertEqual(run["args"], [str(self.repo / "ios"), str(self.out / "matrix" / KINDS[index]), "iphone"])
            self.assertEqual(run["xcodebuild"], str(self.home / "bin/xcodebuild"))
            self.assertEqual(run["lane"], "for-Dictate")
            self.assertEqual(run["run"], str(self.run_state))
            self.assertEqual(run["helper"], str(self.helper))
            # One build's products serve all three runs.
            self.assertEqual(run["derived"], str(self.out / "derived-data"))
            # The phone is the launcher run's own before the matrix starts, so the matrix does not boot it.
            self.assertEqual(run["up"], UDIDS[:index + 1])

    def test_the_gates_shims_stay_ahead_of_the_build_wrapper(self):
        gate = self.root / "gate shims"
        self.executable(gate / "forit-sim-gate", "#!/bin/bash\nexit 0\n")
        self.executable(gate / "xcodebuild", "#!/bin/bash\nexit 0\n")
        result = self.invoke("--execute", FORIT_SIM_GATE=str(gate / "forit-sim-gate"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({run["xcodebuild"] for run in self.matrix_runs()}, {str(gate / "xcodebuild")})

    def test_a_phone_that_does_not_boot_is_named_and_the_others_are_drawn(self):
        result = self.invoke("--execute", UI_CHECK_FIXTURE_NO_BOOT="iPhoneSE")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = self.receipt()
        self.assertTrue(receipt["passed"])
        self.assertFalse(receipt["complete"])
        self.assertEqual(receipt["notBooted"], {"iPhoneSE": "ci-sim-lane.sh boot exit 75"})
        self.assertEqual(receipt["cells"], {"taken": 3, "failed": 0, "notDrawn": 1})
        self.assertEqual([run["boot"] for run in self.matrix_runs()], ["iPhone", "iPhoneProMax"])
        # A boot that was refused is still shut down, in case it came up late.
        self.assertEqual(self.helper_calls().count("--lane for-Dictate shutdown iPhoneSE"), 1)
        with zipfile.ZipFile(self.out / "evidence.zip") as bundle:
            self.assertIn("the gate gave up", bundle.read("boot.log").decode())

    def test_a_run_with_no_picture_does_not_pass(self):
        result = self.invoke("--execute", UI_CHECK_FIXTURE_NO_BOOT=" ".join(KINDS))
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        receipt = self.receipt()
        self.assertFalse(receipt["passed"])
        self.assertEqual(receipt["cells"], {"taken": 0, "failed": 0, "notDrawn": 0})
        self.assertEqual(sorted(receipt["notBooted"]), sorted(KINDS))
        self.assertEqual(receipt["lastPhase"], "evidence")
        self.assertIn("no screen was drawn. iPhone ci-sim-lane.sh boot exit 75", result.stderr)
        self.assertFalse(self.record.exists())

    def test_a_matrix_that_draws_nothing_says_why(self):
        why = "not drawn: the app quit at launch"
        result = self.invoke("--execute", rows=[["iphone", "home", "light", why]])
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        receipt = self.receipt()
        self.assertFalse(receipt["passed"])
        self.assertEqual(receipt["cells"], {"taken": 0, "failed": 0, "notDrawn": 1})
        self.assertEqual(receipt["notDrawn"], [why])
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
        # The other phones are still drawn, and every one is shut down.
        self.assertEqual(len(self.matrix_runs()), 3)
        self.assertEqual(sum("shutdown" in call for call in self.helper_calls()), 3)

    def test_a_phone_that_stays_up_stops_the_next_boot(self):
        result = self.invoke("--execute", UI_CHECK_FIXTURE_SHUTDOWN_EXIT="1")
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("would not shut down", result.stderr)
        self.assertEqual([run["boot"] for run in self.matrix_runs()], ["iPhone"])
        self.assertEqual(sum(call.endswith("boot iPhoneSE") for call in self.helper_calls()), 0)
        self.assertFalse(self.receipt()["passed"])

    def test_refused_before_any_boot(self):
        other = self.root / "other common"
        self.executable(other / "Scripts/device-matrix/device-matrix.sh", MATRIX + "# another revision\n")
        self.commit(other)
        cases = {
            "another commit": {"FORIT_SOURCE_COMMIT": "0" * 40},
            "no gate run": {"FORIT_GATE_RUN": None},
            "no Common": {"FORIT_COMMON_ROOT": None},
            "another Common revision": {"FORIT_COMMON_ROOT": str(other)},
            "another xcodebuild": {"FORIT_XCODEBUILD": "/usr/bin/xcodebuild"},
            "no lane helper": {"MATRIX_LANE_HELPER": str(self.root / "missing/ci-sim-lane.sh")},
            "GitHub Actions": {"GITHUB_ACTIONS": "true"},
        }
        for name, changes in cases.items():
            with self.subTest(name):
                shutil.rmtree(self.repo / "build", ignore_errors=True)
                result = self.invoke("--execute", **changes)
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertFalse(self.record.exists(), "a refused request reached the matrix")
                self.assertEqual(self.helper_calls(), [], "a refused request reached the simulators")
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
        self.assertEqual(self.helper_calls(), [])


if __name__ == "__main__":
    unittest.main()
