"""The release adapter's contract, on throwaway Git repositories (the for-Links test, for one platform).

Only the real adapter is copied. Its recipe is replaced with a recorder, so no SDK, signing, upload or
gate command can run.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ADAPTER = Path(__file__).with_name("apple-release.sh")
CURRENT_HEAD = object()
PASSTHROUGH = {
    "FORIT_GATE_RUN": "fixture gate already open = serial one",
    "FORIT_SLOT_TOKEN": "fixture serial token with spaces",
}


class AppleReleaseContractTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dictate release contract ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / "source checkout with spaces"
        self.scripts = self.repo / "ios/Scripts"
        self.scripts.mkdir(parents=True)
        self.adapter = self.scripts / "apple-release.sh"
        self.adapter.write_bytes(ADAPTER.read_bytes())
        self.output = self.root / "child receipt.json"
        self.recorder = self.root / "fake recipe recorder.py"
        self.recorder.write_text(
            "import json, os, pathlib, sys\n"
            "names = json.loads(os.environ['APPLE_RELEASE_FIXTURE_ENV_NAMES'])\n"
            "payload = {'recipe': pathlib.Path(sys.argv[1]).name, 'args': sys.argv[2:],\n"
            "           'cwd': os.getcwd(), 'env': {name: os.environ.get(name) for name in names}}\n"
            "pathlib.Path(os.environ['APPLE_RELEASE_FIXTURE_OUTPUT']).write_text(json.dumps(payload))\n"
            "print('INERT_RECIPE_CHILD_ONLY')\n"
            "sys.exit(int(os.environ.get('APPLE_RELEASE_FIXTURE_EXIT', '0')))\n"
        )
        (self.scripts / "mini-testflight.sh").write_text(
            '#!/bin/bash\nexec "$APPLE_RELEASE_FIXTURE_PYTHON" "$APPLE_RELEASE_FIXTURE_RECORDER" "$0" "$@"\n'
        )
        (self.repo / "tracked.txt").write_text("committed fixture source\n")
        self.empty_git_template = self.root / "empty git template"
        self.empty_git_template.mkdir()
        # No inherited Git configuration, hooks or credentials enter the fixture.
        self.env = {
            "PATH": os.environ.get("PATH", os.defpath),
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TEMPLATE_DIR": str(self.empty_git_template),
            "APPLE_RELEASE_FIXTURE_PYTHON": sys.executable,
            "APPLE_RELEASE_FIXTURE_RECORDER": str(self.recorder),
            "APPLE_RELEASE_FIXTURE_OUTPUT": str(self.output),
            "APPLE_RELEASE_FIXTURE_ENV_NAMES": json.dumps(["FORIT_SOURCE_COMMIT", *PASSTHROUGH]),
            **PASSTHROUGH,
        }
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "committed inert adapter fixture")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args):
        return subprocess.run(
            [shutil.which("git"), "-C", str(self.repo),
             "-c", "user.name=Release Fixture", "-c", "user.email=fixture@example.invalid",
             "-c", "core.hooksPath=" + str(self.empty_git_template), *args],
            env=self.env, check=True, capture_output=True, text=True,
        )

    def invoke(self, *args, source_commit=CURRENT_HEAD, extra_env=None, cwd=None, adapter=None):
        self.output.unlink(missing_ok=True)
        env = dict(self.env)
        if source_commit is CURRENT_HEAD:
            source_commit = self.head
        if source_commit is not None:
            env["FORIT_SOURCE_COMMIT"] = source_commit
        env.update(extra_env or {})
        return subprocess.run(
            ["/bin/bash", str(adapter or self.adapter), *args],
            cwd=cwd or self.root, env=env, capture_output=True, text=True,
        )

    def receipt(self):
        self.assertTrue(self.output.is_file(), "the recipe was not run")
        return json.loads(self.output.read_text())

    def assert_refused_before_child(self, result, expected_status):
        self.assertEqual(result.returncode, expected_status, result.stdout + result.stderr)
        self.assertFalse(self.output.exists(), "a refused request reached the recipe")
        self.assertNotIn("INERT_RECIPE_CHILD_ONLY", result.stdout)

    def test_export_and_upload_pass_the_exact_arguments(self):
        for upload in (False, True):
            with self.subTest(upload=upload):
                result = self.invoke("ios", "42", *(["--upload"] if upload else []))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                receipt = self.receipt()
                self.assertEqual(receipt["recipe"], "mini-testflight.sh")
                self.assertEqual(receipt["args"], ["42"] + (["--upload"] if upload else []))
                self.assertEqual(receipt["cwd"], str((self.repo / "ios").resolve()))
                self.assertEqual(receipt["env"]["FORIT_SOURCE_COMMIT"], self.head)

    def test_the_callers_gate_and_slot_values_reach_the_recipe_unchanged(self):
        result = self.invoke("ios", "42", "--upload")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        observed = self.receipt()["env"]
        for name, value in PASSTHROUGH.items():
            self.assertEqual(observed[name], value, name)

    def test_a_missing_wrong_or_malformed_commit_is_refused(self):
        self.assert_refused_before_child(self.invoke("ios", "42", source_commit=None), 1)
        for value in ("0" * 40, "", "HEAD", "a" * 39, "a" * 41, "g" * 40, "A" * 40,
                      " " + self.head, self.head + "\n"):
            with self.subTest(source_commit=value):
                self.assert_refused_before_child(self.invoke("ios", "42", source_commit=value), 1)

    def test_only_the_iphone_platform_is_taken(self):
        for platform in ("", "mac", "macos", "visionos", "iOS", "ios --upload"):
            with self.subTest(platform=platform):
                self.assert_refused_before_child(self.invoke(platform, "42"), 2)

    def test_a_bad_build_number_is_refused(self):
        for build in ("", "0", "00", "01", "-1", "+1", "1.0", "2e2", " 42", "42 ", "4\n2"):
            with self.subTest(build=build):
                self.assert_refused_before_child(self.invoke("ios", build), 2)

    def test_missing_unknown_and_extra_arguments_are_refused(self):
        for args in ((), ("ios",), ("ios", "42", ""), ("ios", "42", "--unknown"),
                     ("ios", "42", "--upload", "extra"), ("ios", "42", "--upload", "--upload")):
            with self.subTest(args=args):
                self.assert_refused_before_child(self.invoke(*args), 2)

    def test_changed_or_untracked_source_is_refused(self):
        (self.repo / "unsent fixture source.txt").write_text("not committed\n")
        self.assert_refused_before_child(self.invoke("ios", "42"), 1)
        (self.repo / "unsent fixture source.txt").unlink()
        (self.repo / "tracked.txt").write_text("changed fixture source\n")
        self.assert_refused_before_child(self.invoke("ios", "42", "--upload"), 1)

    def test_the_recipes_exit_status_is_kept(self):
        for status in (1, 37, 73):
            with self.subTest(status=status):
                result = self.invoke("ios", "42", "--upload",
                                     extra_env={"APPLE_RELEASE_FIXTURE_EXIT": str(status)})
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertEqual(self.receipt()["args"], ["42", "--upload"])

    def test_it_works_from_another_directory_and_through_a_link(self):
        caller = self.root / "unrelated caller with spaces"
        caller.mkdir()
        result = self.invoke("ios", "42", cwd=caller)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.receipt()["cwd"], str((self.repo / "ios").resolve()))
        alias = self.root / "linked ios directory"
        alias.symlink_to(self.repo / "ios", target_is_directory=True)
        result = self.invoke("ios", "42", adapter=alias / "Scripts/apple-release.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.receipt()["cwd"], str((self.repo / "ios").resolve()))

    def test_an_adapter_outside_ios_scripts_is_refused(self):
        moved = self.repo / "mobile"
        (self.repo / "ios").rename(moved)
        self.git("add", "-A")
        self.git("commit", "-qm", "move the fixture outside ios")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()
        self.assert_refused_before_child(self.invoke("ios", "42", adapter=moved / "Scripts/apple-release.sh"), 1)


if __name__ == "__main__":
    unittest.main()
