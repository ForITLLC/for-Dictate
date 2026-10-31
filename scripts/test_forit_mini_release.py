#!/usr/bin/env python3
"""Offline adapter contract tests. No production core, launcher, credentials or Mac is used.

The byte-identical adapter runs only in an owned synthetic checkout. PATH contains
metadata-only shims and deny stubs; the two possible core targets are inert sentinels.
Parent Python rejects every subprocess except the current exact Bash adapter argv.
These tests deliberately never provide a gate run or signing keychain.
"""

import ast
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
ADAPTER = REPO / "scripts/forit-mini-release.sh"
_ORIGINAL_POPEN = subprocess.Popen
_ALLOWED_LAUNCH = None
_PATCHES = []


def _deny(*args, **kwargs):
    raise AssertionError("Network and unrelated subprocess access are forbidden in adapter contract tests")


def _guarded_popen(command, *args, **kwargs):
    allowed = _ALLOWED_LAUNCH
    if allowed is None or args or tuple(command) != allowed["command"]:
        return _deny()
    if kwargs.get("shell", False) or kwargs.get("executable") is not None:
        return _deny()
    if kwargs.get("env") != allowed["environment"] or kwargs.get("cwd") != allowed["cwd"]:
        return _deny()
    environment = kwargs["env"]
    if environment.get("HOME") != allowed["home"] or environment.get("PATH") != allowed["path"]:
        return _deny()
    if "FORIT_GATE_RUN" in environment or "FORIT_CODESIGN_KEYCHAIN" in environment:
        return _deny()
    return _ORIGINAL_POPEN(command, **kwargs)


def setUpModule():
    for name in ["socket", "create_connection", "getaddrinfo", "gethostbyname", "gethostbyname_ex", "gethostbyaddr"]:
        _PATCHES.append(mock.patch.object(socket, name, _deny))
    _PATCHES.append(mock.patch.object(subprocess, "Popen", _guarded_popen))
    for patch in _PATCHES:
        patch.start()


def tearDownModule():
    global _ALLOWED_LAUNCH
    _ALLOWED_LAUNCH = None
    for patch in reversed(_PATCHES):
        patch.stop()
    _PATCHES.clear()


def _source_head():
    """Read this checkout's HEAD without launching Git or consulting user configuration."""
    dotgit = REPO / ".git"
    if dotgit.is_file():
        pointer = dotgit.read_text().strip()
        if not pointer.startswith("gitdir: "):
            raise AssertionError("Unsupported checkout metadata")
        gitdir = (REPO / pointer.removeprefix("gitdir: ")).resolve()
    else:
        gitdir = dotgit
    head = (gitdir / "HEAD").read_text().strip()
    if head.startswith("ref: "):
        reference = head.removeprefix("ref: ")
        if not re.fullmatch(r"refs/[A-Za-z0-9_./-]+", reference) or ".." in reference.split("/"):
            raise AssertionError("Unsupported HEAD reference")
        common = gitdir
        if (gitdir / "commondir").is_file():
            common = (gitdir / (gitdir / "commondir").read_text().strip()).resolve()
        for directory in [gitdir, common]:
            if (directory / reference).is_file():
                head = (directory / reference).read_text().strip()
                break
        else:
            head = ""
            packed = common / "packed-refs"
            if packed.is_file():
                with packed.open() as stream:
                    for line in stream:
                        fields = line.strip().split()
                        if len(fields) == 2 and fields[1] == reference:
                            head = fields[0]
                            break
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", head):
        raise AssertionError("Could not resolve the source checkout's HEAD")
    return head


def _validate_adapter(source):
    """Reject absolute escape routes before allowing even the synthetic adapter copy to run."""
    code = "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("#"))
    if any(value in code for value in ["/dev/tcp", "/dev/udp", "eval ", "source "]):
        raise AssertionError("Adapter introduced a command execution escape route")
    absolute_commands = set(re.findall(r"(?<![A-Za-z0-9_$])/(?:usr/(?:bin|sbin)|bin|sbin)/[A-Za-z0-9_.-]+", code))
    if absolute_commands - {"/bin/bash", "/usr/bin/python3"}:
        raise AssertionError("Adapter introduced an unguarded absolute command")
    allowed_execs = {
        "exec /usr/bin/python3 scripts/check-dictate-integrations.py --output build/forit-release/integration-tests",
        "exec /bin/bash scripts/forit-release.sh",
    }
    for line in code.splitlines():
        if line.strip().startswith("exec ") and line.strip() not in allowed_execs:
            raise AssertionError("Adapter introduced an unguarded exec target")


# This interpreter starts with -S: no user/global sitecustomize code is loaded. It
# never starts another process. Git/dirname/uname return narrowly controlled metadata;
# python3 accepts only the adapter's JSON plan program, checked and sandboxed below.
_SHIM = r'''
import ast, json, os, re, sys, types
name = os.path.basename(sys.argv[0])
arguments = sys.argv[1:]
def record(kind):
    with open(os.environ["FORIT_TEST_COMMAND_LOG"], "a", encoding="utf-8") as stream:
        stream.write(json.dumps({"kind": kind, "command": name, "argv": arguments}) + "\n")
def denied():
    record("denied")
    raise SystemExit(97)
if name == "dirname" and arguments == [os.environ["FORIT_TEST_ADAPTER"]]:
    record("metadata")
    print(os.path.dirname(arguments[0]))
elif name == "git" and arguments == ["rev-parse", "HEAD"]:
    record("metadata")
    print(os.environ["FORIT_TEST_SOURCE_HEAD"])
elif name == "uname" and arguments == ["-s"] and os.environ["FORIT_TEST_UNAME"] in ["Linux", "Darwin"]:
    record("metadata")
    print(os.environ["FORIT_TEST_UNAME"])
elif name == "python3" and len(arguments) == 3 and arguments[:2] == ["-", os.environ["FORIT_TEST_SOURCE_HEAD"]] and re.fullmatch(r"[1-9][0-9]*", arguments[2]):
    program = sys.stdin.read(65537)
    if len(program) > 65536:
        denied()
    try:
        tree = ast.parse(program)
    except SyntaxError:
        denied()
    nodes = (ast.Module, ast.Import, ast.alias, ast.Expr, ast.Call, ast.Name, ast.Load,
             ast.Attribute, ast.Dict, ast.Constant, ast.Subscript, ast.List, ast.keyword)
    for node in ast.walk(tree):
        if not isinstance(node, nodes):
            denied()
        if isinstance(node, ast.Import) and any(alias.name not in {"json", "sys"} or alias.asname for alias in node.names):
            denied()
        if isinstance(node, ast.Attribute) and not (isinstance(node.value, ast.Name) and
                (node.value.id, node.attr) in {("json", "dumps"), ("sys", "argv")}):
            denied()
        if isinstance(node, ast.Call) and not ((isinstance(node.func, ast.Name) and node.func.id == "print") or
                (isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name) and
                 node.func.value.id == "json" and node.func.attr == "dumps")):
            denied()
    modules = {"json": types.SimpleNamespace(dumps=json.dumps), "sys": types.SimpleNamespace(argv=arguments)}
    def restricted_import(module, *args, **kwargs):
        if module not in modules:
            denied()
        return modules[module]
    record("metadata")
    exec(compile(tree, "<owned-adapter-plan>", "exec"),
         {"__builtins__": {"__import__": restricted_import, "print": print}, "__name__": "__main__"})
else:
    denied()
'''


class MiniReleaseContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = ADAPTER.read_bytes()
        _validate_adapter(cls.source.decode())
        cls.head = _source_head()
        cls.interpreter = str(Path(sys.executable).resolve())
        if not cls.interpreter.startswith("/") or any(char.isspace() for char in cls.interpreter):
            raise AssertionError("A safe absolute Python interpreter path is required")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dictate-mini-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.shims = self.root / "shims"
        self.scripts = self.root / "checkout/scripts"
        for directory in [self.home, self.shims, self.scripts, self.root / "tmp"]:
            directory.mkdir(parents=True, mode=0o700)
        self.adapter = self.scripts / ADAPTER.name
        self.adapter.write_bytes(self.source)
        self.command_log = self.root / "commands.jsonl"
        # Even an erroneous gate bypass can reach only owned deny sentinels, never a real core.
        (self.scripts / "forit-release.sh").write_text(
            '#!/bin/bash\nprintf \'%s\\n\' \'{"kind":"denied","command":"release-core"}\' >> "$FORIT_TEST_COMMAND_LOG"\nexit 98\n')
        (self.scripts / "check-dictate-integrations.py").write_text(
            'raise SystemExit("DENIED: unexpected integration helper invocation")\n')
        commands = {
            "dirname", "git", "uname", "python3", "python", "ssh", "scp", "sftp", "curl", "wget", "rsync",
            "security", "codesign", "xcrun", "xcodebuild", "swift", "clang", "clang++", "cmake", "make",
            "hdiutil", "ditto", "notarytool", "stapler", "spctl", "open", "osascript", "launchctl", "defaults",
            "nc", "netcat", "ncat", "env", "bash", "sh", "node", "npm", "kill", "pkill", "pgrep", "sleep",
        }
        for command in commands:
            shim = self.shims / command
            shim.write_text(f"#!{self.interpreter} -S\n" + _SHIM)
            shim.chmod(0o700)
        self.environment = {
            "HOME": str(self.home), "PATH": str(self.shims), "TMPDIR": str(self.root / "tmp"),
            "LANG": "C", "LC_ALL": "C", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "FORIT_TEST_COMMAND_LOG": str(self.command_log), "FORIT_TEST_ADAPTER": str(self.adapter),
            "FORIT_TEST_SOURCE_HEAD": self.head, "FORIT_TEST_UNAME": "Linux",
        }

    def invoke(self, *arguments, system="Linux", actions=None, source_commit=None):
        global _ALLOWED_LAUNCH
        environment = dict(self.environment, FORIT_TEST_UNAME=system)
        if actions is not None:
            environment["GITHUB_ACTIONS"] = actions
        if source_commit is not None:
            environment["FORIT_SOURCE_COMMIT"] = source_commit
        command = ("/bin/bash", str(self.adapter), *arguments)
        _ALLOWED_LAUNCH = {"command": command, "environment": environment, "cwd": str(self.scripts.parent),
                           "home": str(self.home), "path": str(self.shims)}
        try:
            result = subprocess.run(command, cwd=str(self.scripts.parent), env=environment,
                                    capture_output=True, text=True, timeout=5, check=False)
        finally:
            _ALLOWED_LAUNCH = None
        records = [json.loads(line) for line in self.command_log.read_text().splitlines()] if self.command_log.exists() else []
        self.assertFalse([record for record in records if record["kind"] == "denied"], records)
        self.assertNotIn("DENIED:", result.stderr)
        return result, records

    def rejected(self, arguments, message, **kwargs):
        result, records = self.invoke(*arguments, **kwargs)
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn(message, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("python3", [record["command"] for record in records])
        return result, records

    def test_plan_reports_source_head_and_explicit_build(self):
        result, _ = self.invoke("1901", "--plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["commit"], self.head)
        self.assertEqual(plan["build"], "1901")
        self.assertEqual(plan["app"], "for-Dictate")
        self.assertEqual(plan["platform"], "macos")

    def test_plan_is_metadata_only_without_native_or_upload(self):
        result, records = self.invoke("1901", "--plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertIs(plan["nativeExecution"], False)
        self.assertIs(plan["upload"], False)
        self.assertEqual(plan["tests"], 52)
        self.assertEqual(plan["channel"], "Developer ID notarized DMG")
        self.assertEqual(plan["requiredEnvironment"], ["FORIT_GATE_RUN", "FORIT_CODESIGN_KEYCHAIN"])
        self.assertEqual([record["command"] for record in records], ["dirname", "git", "python3"])
        self.assertFalse((self.scripts.parent / "build").exists())

    def test_matching_inherited_full_source_is_accepted_without_replacing_it(self):
        result, records = self.invoke("1901", "--plan", source_commit=self.head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["commit"], self.head)
        self.assertEqual([record["command"] for record in records], ["dirname", "git", "python3"])
        self.assertFalse((self.scripts.parent / "build").exists())

    def test_mismatched_inherited_full_source_fails_before_plan_or_native_preflight(self):
        different = ("0" if self.head[0] != "0" else "1") + self.head[1:]
        for mode in [[], ["--plan"], ["--check-only"]]:
            with self.subTest(mode=mode):
                _, records = self.rejected(["1901", *mode], "does not match checkout HEAD",
                                           system="Darwin", source_commit=different)
                self.assertEqual(set(record["command"] for record in records), {"dirname", "git"})
                self.assertFalse((self.scripts.parent / "build").exists())

    def test_invalid_inherited_source_fails_before_plan_or_native_preflight(self):
        for value in ["a" * 39, "a" * 41, "A" * 40, "g" * 40, " ", "a" * 40 + "\n"]:
            for mode in [[], ["--plan"], ["--check-only"]]:
                with self.subTest(value=value, mode=mode):
                    _, records = self.rejected(["1901", *mode], "full lowercase 40-hex SHA",
                                               system="Darwin", source_commit=value)
                    self.assertEqual(set(record["command"] for record in records), {"dirname", "git"})
                    self.assertFalse((self.scripts.parent / "build").exists())

    def test_empty_inherited_source_keeps_metadata_plan_head_fallback(self):
        result, records = self.invoke("1901", "--plan", source_commit="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["commit"], self.head)
        self.assertEqual([record["command"] for record in records], ["dirname", "git", "python3"])

    def test_plan_preserves_each_positive_explicit_build(self):
        for build in ["1", "1902", "999999"]:
            with self.subTest(build=build):
                result, _ = self.invoke(build, "--plan")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["build"], build)

    def test_help_never_reads_source_or_starts_native_tools(self):
        result, records = self.invoke("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)
        self.assertEqual(records, [])

    def test_missing_build_is_rejected(self):
        self.rejected([], "explicit positive integer BUILD")

    def test_flag_cannot_replace_build(self):
        self.rejected(["--plan"], "explicit positive integer BUILD")

    def test_invalid_build_values_are_rejected(self):
        for value in ["", "0", "-1", "001", "1.5", "abc", "1;curl invalid", "$(curl invalid)"]:
            with self.subTest(build=value):
                self.rejected([value, "--plan"], "explicit positive integer BUILD")

    def test_upload_is_rejected_in_all_modes(self):
        for arguments in [["1901", "--upload"], ["1901", "--plan", "--upload"], ["1901", "--check-only", "--upload"]]:
            with self.subTest(arguments=arguments):
                self.rejected(arguments, "does not upload to TestFlight")

    def test_unknown_arguments_are_rejected(self):
        for flag in ["--unknown", "--release", "extra", "--plan=true"]:
            with self.subTest(flag=flag):
                self.rejected(["1901", flag], "unsupported argument")

    def test_conflicting_modes_are_rejected(self):
        for modes in [["--plan", "--check-only"], ["--check-only", "--plan"]]:
            with self.subTest(modes=modes):
                self.rejected(["1901", *modes], "choose one mode")

    def test_repeated_modes_are_rejected(self):
        for flag in ["--plan", "--check-only"]:
            with self.subTest(flag=flag):
                self.rejected(["1901", flag, flag], "choose one mode")

    def test_github_actions_rejects_plan(self):
        self.rejected(["1901", "--plan"], "GitHub Actions are retired", actions="true")

    def test_github_actions_rejects_native_modes(self):
        for arguments in [["1901"], ["1901", "--check-only"]]:
            with self.subTest(arguments=arguments):
                self.rejected(arguments, "GitHub Actions are retired", actions="true")

    def test_linux_release_fails_before_native_build(self):
        self.rejected(["1901"], "native execution requires the maintained Mac", system="Linux")

    def test_linux_checks_fail_before_native_execution(self):
        self.rejected(["1901", "--check-only"], "native execution requires the maintained Mac", system="Linux")

    def test_darwin_release_requires_missing_gate(self):
        self.rejected(["1901"], "inherited active Common gate run is required", system="Darwin")

    def test_darwin_checks_require_missing_gate(self):
        self.rejected(["1901", "--check-only"], "inherited active Common gate run is required", system="Darwin")

    def test_explicit_non_actions_plan_is_allowed(self):
        result, _ = self.invoke("1901", "--plan", actions="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["tests"], 52)


if __name__ == "__main__":
    unittest.main()
