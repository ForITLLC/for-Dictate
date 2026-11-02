#!/usr/bin/env python3
"""Portable installer fixtures; no real Apple tools, app, device or user store.

Run this module alone in its own Python process. The unconditional audit guard is
installed before the remaining imports and refuses every process except the one
exact owned Bash fixture invocation. Its PATH has only synthetic command shims.
The installer copy differs only in three asserted fixed platform constants.
"""

import sys

_ALLOWED_BASH = None


def _offline_audit(event, arguments):
    if event.startswith("socket.") or event in {
        "os.system", "os.exec", "os.posix_spawn", "os.spawn", "os.fork", "os.forkpty"
    }:
        raise AssertionError("installer fixture refused network/process operation: " + event)
    if event == "subprocess.Popen":
        allowed = _ALLOWED_BASH
        if allowed is None or len(arguments) != 4:
            raise AssertionError("installer fixture refused an unowned subprocess")
        executable, command, cwd, environment = arguments
        if (executable != "/bin/bash" or tuple(command) != allowed["command"]
                or cwd != allowed["cwd"] or environment != allowed["environment"]):
            raise AssertionError("installer fixture refused a changed process boundary")


sys.addaudithook(_offline_audit)

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().with_name("forit-install.sh")
PLISTBUDDY = "/usr/libexec/PlistBuddy"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
APP_NAME = "ForIT Dictate.app"
TEAM = "UUSSWWML2A"


# Every command is an inert Python shim, started directly by its absolute -S
# interpreter shebang. The shim itself refuses any child process or network use.
SHIM = r'''
import sys
def deny_process(event, arguments):
    if event == "subprocess.Popen" or event.startswith("socket.") or event in {
        "os.system", "os.exec", "os.posix_spawn", "os.spawn", "os.fork", "os.forkpty"
    }:
        raise AssertionError("synthetic installer command refused process/network")
sys.addaudithook(deny_process)
import hashlib, json, os, pathlib, plistlib, re, shutil, tempfile
ROOT = pathlib.Path(__ROOT__)
CONFIG = ROOT / "scenario.json"
LOG = ROOT / "commands.jsonl"
cfg = json.loads(CONFIG.read_text())
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def record(kind="command", **extra):
    with LOG.open("a") as stream:
        stream.write(json.dumps({"command": name, "argv": args, "kind": kind, **extra}) + "\n")
def refuse():
    record("denied")
    raise SystemExit(97)
def owned(value):
    path = pathlib.Path(value)
    if not path.is_absolute():
        path = pathlib.Path.cwd() / path
    if path == ROOT or not path.resolve().is_relative_to(ROOT):
        refuse()
    return path
def operands():
    return [arg for arg in args if not arg.startswith("-")]
def role(value):
    return "dmg" if str(value).endswith(".dmg") else "app"
def marker(path):
    mark = path / "fixture-version"
    return mark.read_text() if mark.is_file() else ""
record()
if name == "dirname" and len(args) == 1:
    print(owned(args[0]).parent)
elif name == "basename" and len(args) == 1:
    print(owned(args[0]).name)
elif name == "uname" and args == ["-s"]:
    print("Darwin")
elif name == "shasum":
    if args[:3] == ["-a", "256", "-c"] and len(args) == 4:
        receipt = owned(args[3]).read_text()
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\n]+)\n?", receipt)
        if not match:
            raise SystemExit(1)
        target = owned(match[2])
        raise SystemExit(0 if hashlib.sha256(target.read_bytes()).hexdigest() == match[1] else 1)
    if args[:2] != ["-a", "256"] or len(args) != 3:
        refuse()
    target = owned(args[2])
    print(hashlib.sha256(target.read_bytes()).hexdigest() + "  " + str(target))
elif name == "codesign":
    target = owned(args[-1])
    kind = role(target)
    if args[0].startswith("-d"):
        print("Identifier=" + cfg.get(kind + "_identifier", "io.forit.dictate"))
        print("Authority=" + cfg.get(kind + "_authority", "Developer ID Application: ForIT Limited Liability Company (UUSSWWML2A)"))
        print("TeamIdentifier=" + cfg.get(kind + "_team", "UUSSWWML2A"))
    elif args[0] == "--verify":
        if target == ROOT / "Applications" / "ForIT Dictate.app" and cfg.get("installed_signature_failure"):
            raise SystemExit(1)
        raise SystemExit(1 if cfg.get(kind + "_signature_failure") else 0)
    else:
        refuse()
elif name == "spctl":
    target = owned(args[-1])
    raise SystemExit(1 if cfg.get(role(target) + "_gatekeeper_failure") else 0)
elif name == "xcrun":
    if args[:2] != ["stapler", "validate"]:
        refuse()
    target = owned(args[-1])
    raise SystemExit(1 if cfg.get(role(target) + "_staple_failure") else 0)
elif name == "pgrep":
    if args != ["-x", "VoiceInk"]:
        refuse()
    prior = [json.loads(line) for line in LOG.read_text().splitlines()]
    index = sum(row["command"] == "pgrep" for row in prior) - 1
    codes = cfg.get("pgrep_status", [1, 1])
    status = codes[min(index, len(codes) - 1)]
    if status == 0:
        print("424242")
    raise SystemExit(status)
elif name == "hdiutil":
    if args and args[0] == "attach" and "-mountpoint" in args:
        mount = owned(args[args.index("-mountpoint") + 1])
        owned(args[-1])
        if not cfg.get("missing_app"):
            shutil.copytree(ROOT / "media" / "ForIT Dictate.app", mount / "ForIT Dictate.app")
    elif args and args[0] == "detach":
        mount = owned(args[-1])
        for child in mount.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
    else:
        refuse()
elif name == "PlistBuddy":
    if len(args) != 3 or args[0] != "-c" or not args[1].startswith("Print "):
        refuse()
    key = args[1][len("Print "):].lstrip(":")
    value = plistlib.loads(owned(args[2]).read_bytes())
    if key not in value:
        raise SystemExit(1)
    print(value[key])
elif name == "ditto" and len(args) == 2:
    source, target = map(owned, args)
    record("mutation", target=str(target))
    if cfg.get("copy_failure"):
        target.mkdir(parents=True, exist_ok=True)
        (target / "partial-copy").write_text("synthetic partial copy")
        raise SystemExit(1)
    shutil.copytree(source, target)
elif name == "mv" and len(operands()) == 2:
    source, target = map(owned, operands())
    record("mutation", source=str(source), target=str(target))
    if cfg.get("swap_failure") and target == ROOT / "Applications" / "ForIT Dictate.app" and marker(source) == "new":
        raise SystemExit(1)
    source.rename(target)
elif name == "mktemp":
    if "-d" not in args:
        refuse()
    patterns = operands()
    if patterns:
        if len(patterns) != 1 or not patterns[0].endswith("XXXXXX"):
            refuse()
        template = owned(patterns[0])
        print(tempfile.mkdtemp(prefix=template.name[:-6], dir=template.parent))
    else:
        print(tempfile.mkdtemp(prefix="synthetic-mount-", dir=ROOT / "tmp"))
elif name == "mkdir":
    for arg in operands():
        target = owned(arg)
        record("mutation", target=str(target))
        target.mkdir(parents="-p" in args, exist_ok="-p" in args)
elif name == "rm":
    for arg in operands():
        target = owned(arg)
        record("mutation", target=str(target))
        if target.is_symlink() or target.is_file():
            target.unlink()
        elif target.is_dir():
            shutil.rmtree(target)
        elif "f" not in "".join(a for a in args if a.startswith("-")):
            raise SystemExit(1)
elif name == "rmdir":
    for arg in operands():
        owned(arg).rmdir()
elif name == "cmp":
    paths = [arg for arg in args if arg not in ("-s", "--")]
    if len(paths) != 2:
        refuse()
    values = [sys.stdin.buffer.read() if path == "-" else owned(path).read_bytes() for path in paths]
    raise SystemExit(0 if values[0] == values[1] else 1)
elif name == "wc" and args == ["-c"]:
    print(len(sys.stdin.buffer.read()))
elif name == "grep":
    nonflags = operands()
    if not nonflags:
        refuse()
    pattern = nonflags[0]
    data = "".join(owned(arg).read_text() for arg in nonflags[1:]) if len(nonflags) > 1 else sys.stdin.read()
    fixed = any("F" in arg for arg in args if arg.startswith("-"))
    exact = any("x" in arg for arg in args if arg.startswith("-"))
    matches = [line for line in data.splitlines() if (pattern == line if fixed and exact else
               pattern in line if fixed else re.search(pattern, line))]
    if not any("q" in arg for arg in args if arg.startswith("-")):
        print("\n".join(matches), end="\n" if matches else "")
    raise SystemExit(0 if matches else 1)
elif name == "lsregister":
    if len(args) != 2 or args[0] != "-f" or owned(args[1]) != ROOT / "Applications" / "ForIT Dictate.app":
        refuse()
    raise SystemExit(1 if cfg.get("registration_failure") else 0)
else:
    refuse()
'''


class InstallContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = INSTALLER.read_text()
        cls.interpreter = str(Path(sys.executable).resolve())
        if not cls.interpreter.startswith("/") or any(char.isspace() for char in cls.interpreter):
            raise AssertionError("A safe absolute fixture interpreter is required")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dictate-install-offline-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.applications = self.root / "Applications"
        self.shims = self.root / "bin"
        for path in (self.applications, self.shims, self.root / "home", self.root / "tmp", self.root / "input", self.root / "checkout"):
            path.mkdir()
        self.destination = self.applications / APP_NAME
        self.media_app = self.root / "media" / APP_NAME
        self.make_app(self.destination, "old", "1841")
        self.make_app(self.media_app, "new", "1842")
        self.dmg = self.root / "input" / "ForIT-Dictate-1.0.0-1842.dmg"
        self.dmg.write_bytes(b"synthetic dmg fixture, never an Apple image\x00")
        self.checksum = Path(str(self.dmg) + ".sha256")
        self.checksum.write_text(hashlib.sha256(self.dmg.read_bytes()).hexdigest() + "  " + self.dmg.name + "\n")
        self.config = {}
        self.config_path = self.root / "scenario.json"
        self.log = self.root / "commands.jsonl"
        self.installer = self.root / "checkout" / "forit-install.sh"
        substitutions = [
            ('DEST="/Applications/$APP_NAME.app"', 'DEST="' + str(self.applications) + '/$APP_NAME.app"'),
            ("PLISTBUDDY=" + PLISTBUDDY, "PLISTBUDDY=" + str(self.shims / "PlistBuddy")),
            ("LSREG=" + LSREGISTER, "LSREG=" + str(self.shims / "lsregister")),
        ]
        adjusted = self.source
        for before, after in substitutions:
            self.assertEqual(adjusted.count(before), 1, "Fixed installer constant drift: " + before)
            adjusted = adjusted.replace(before, after, 1)
        reversed_copy = adjusted
        for before, after in reversed(substitutions):
            self.assertEqual(reversed_copy.count(after), 1)
            reversed_copy = reversed_copy.replace(after, before, 1)
        self.assertEqual(reversed_copy, self.source, "Only fixed platform constants may differ")
        code = "\n".join(line for line in adjusted.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotRegex(code, r"(?<![A-Za-z0-9_$./-])/(?:usr/(?:bin|sbin|libexec)|bin|sbin|System/Library)/[A-Za-z0-9_./-]+", "Unstubbed absolute command")
        # Gatekeeper's fixed assessment type is data, not the app-launch command.
        # Exempt only this one literal in the scan; executed fixture bytes stay intact.
        assessment = "spctl -a -t open --context context:primary-signature"
        self.assertEqual(code.count(assessment), 1, "Fixed Gatekeeper assessment drift")
        execution_scan = code.replace(assessment, "spctl -a -t synthetic-assessment --context context:primary-signature", 1)
        self.assertNotRegex(execution_scan, r"\b(?:eval|source|exec|osascript|pkill|killall|kill|open|launchctl|curl|wget|ssh|scp)\b", "Installer added an unsafe execution route")
        self.assertNotIn("/dev/tcp", code)
        self.assertNotIn("/dev/udp", code)
        self.installer.write_text(adjusted)
        commands = {
            "dirname", "basename", "uname", "shasum", "codesign", "spctl", "xcrun", "pgrep", "hdiutil", "ditto", "mv",
            "mktemp", "mkdir", "rm", "rmdir", "cmp", "wc", "grep", "PlistBuddy", "lsregister",
            "ssh", "scp", "curl", "wget", "security", "xcodebuild", "swift", "osascript", "pkill", "killall", "open", "launchctl",
        }
        shim = "#!" + self.interpreter + " -S\n" + SHIM.replace("__ROOT__", repr(str(self.root)))
        for name in commands:
            path = self.shims / name
            path.write_text(shim)
            path.chmod(0o700)
        self.environment = {
            "HOME": str(self.root / "home"), "PATH": str(self.shims), "TMPDIR": str(self.root / "tmp"),
            "LANG": "C", "LC_ALL": "C", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
        }
        self.before = self.inventory(self.applications)

    @staticmethod
    def make_app(path, marker, build):
        (path / "Contents" / "MacOS").mkdir(parents=True)
        (path / "fixture-version").write_text(marker)
        (path / "Contents" / "MacOS" / "VoiceInk").write_text("inert fixture, not executable")
        (path / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "io.forit.dictate", "CFBundleExecutable": "VoiceInk",
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": build,
        }))

    @staticmethod
    def inventory(directory):
        return {str(path.relative_to(directory)): (path.stat().st_ino, path.stat().st_mode,
                hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
                for path in directory.rglob("*")}

    def invoke(self, *arguments):
        global _ALLOWED_BASH
        self.config_path.write_text(json.dumps(self.config))
        self.log.write_text("")
        command = ("/bin/bash", str(self.installer), *(arguments or (str(self.dmg),)))
        _ALLOWED_BASH = {"command": command, "cwd": str(self.root / "checkout"), "environment": self.environment.copy()}
        try:
            result = subprocess.run(command, cwd=_ALLOWED_BASH["cwd"], env=self.environment.copy(),
                                    capture_output=True, text=True, timeout=10, check=False)
        finally:
            _ALLOWED_BASH = None
        records = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        self.assertFalse([row for row in records if row["kind"] == "denied"], (result.stderr, records))
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotEqual(result.returncode, 97, result.stderr)
        self.assertFalse({row["command"] for row in records} & {"open", "osascript", "pkill", "killall", "launchctl", "ssh", "scp", "security"})
        return result, records

    def refused_without_install_mutation(self):
        result, records = self.invoke()
        self.assertNotEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertEqual(self.inventory(self.applications), self.before, result.stderr)
        self.assertFalse([row for row in records if row["kind"] == "mutation" and
                          str(row.get("target", "")).startswith(str(self.applications) + "/")], records)
        self.assertNotIn("installed ", result.stdout)
        return result, records

    def edit_plist(self, **changes):
        path = self.media_app / "Contents" / "Info.plist"
        value = plistlib.loads(path.read_bytes())
        value.update(changes)
        path.write_bytes(plistlib.dumps(value))

    def test_checksum_missing_wrong_target_mismatch_and_extra_records_refuse(self):
        valid = self.checksum.read_text()
        for content in (None, valid.replace(self.dmg.name, "another.dmg"),
                        "0" * 64 + "  " + self.dmg.name + "\n", valid * 2, valid.replace("\n", "\r\n")):
            with self.subTest(content=content):
                if content is None:
                    self.checksum.unlink(missing_ok=True)
                else:
                    self.checksum.write_text(content)
                _, records = self.refused_without_install_mutation()
                self.assertFalse({row["command"] for row in records} & {"codesign", "hdiutil", "ditto"})

    def test_dmg_signature_identity_staple_and_gatekeeper_refusals(self):
        cases = [{"dmg_signature_failure": True}, {"dmg_team": "OTHERTEAM0"},
                 {"dmg_authority": "Apple Development: Synthetic Fixture"},
                 {"dmg_staple_failure": True}, {"dmg_gatekeeper_failure": True}]
        for case in cases:
            with self.subTest(case=case):
                self.config = case
                self.refused_without_install_mutation()

    def test_app_absence_signature_identity_staple_and_gatekeeper_refusals(self):
        cases = [{"missing_app": True}, {"app_signature_failure": True}, {"app_team": "OTHERTEAM0"},
                 {"app_identifier": "io.forit.other"}, {"app_authority": "Apple Development: Synthetic Fixture"},
                 {"app_staple_failure": True}, {"app_gatekeeper_failure": True}]
        for case in cases:
            with self.subTest(case=case):
                self.config = case
                self.refused_without_install_mutation()

    def test_app_plist_identity_executable_and_invalid_version_build_refuse(self):
        path = self.media_app / "Contents" / "Info.plist"
        valid = path.read_bytes()
        for changes in ({"CFBundleIdentifier": "io.forit.other"}, {"CFBundleExecutable": "AnotherApp"},
                        {"CFBundleVersion": "0"}, {"CFBundleShortVersionString": "invalid"}):
            with self.subTest(changes=changes):
                path.write_bytes(valid)
                self.edit_plist(**changes)
                self.refused_without_install_mutation()

    def test_active_app_refuses_without_quitting_or_launching(self):
        self.config["pgrep_status"] = [0, 0]
        self.refused_without_install_mutation()
        self.config["pgrep_status"] = [1, 0]
        result, records = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.inventory(self.applications), self.before)
        self.assertEqual(sum(row["command"] == "pgrep" for row in records), 2)

    def test_pgrep_error_refuses_instead_of_treating_it_as_idle(self):
        self.config["pgrep_status"] = [2, 2]
        self.refused_without_install_mutation()
        self.config["pgrep_status"] = [1, 2]
        result, records = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.inventory(self.applications), self.before)
        self.assertEqual(sum(row["command"] == "pgrep" for row in records), 2)

    def test_copy_failure_preserves_existing_app(self):
        self.config["copy_failure"] = True
        before = self.inventory(self.destination)
        result, records = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.inventory(self.destination), before)
        self.assertIn("could not stage the new app", result.stderr)
        self.assertTrue(any(row["command"] == "ditto" for row in records))
        self.assertNotIn("installed ", result.stdout)

    def test_failed_swap_or_registration_restores_existing_app(self):
        before = self.inventory(self.destination)
        for case in ({"swap_failure": True}, {"registration_failure": True}):
            with self.subTest(case=case):
                self.config = case
                result, records = self.invoke()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.inventory(self.destination), before)
                self.assertIn("restored the previous app", result.stderr)
                self.assertTrue(any(row["command"] == "mv" for row in records))
                if case.get("registration_failure"):
                    rejected = list(self.applications.glob(".forit-dictate-install.*/rejected.app/fixture-version"))
                    self.assertEqual([path.read_text() for path in rejected], ["new"])
                self.assertNotIn("installed ", result.stdout)

    def test_first_install_verification_or_registration_failure_retains_rejected_app(self):
        shutil.rmtree(self.destination)
        for case in ({"installed_signature_failure": True}, {"registration_failure": True}):
            with self.subTest(case=case):
                self.config = case
                stages_before = set(self.applications.iterdir())
                result, records = self.invoke()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.destination.exists())
                stages_after = set(self.applications.iterdir())
                self.assertEqual(len(stages_after - stages_before), 1)
                stage = (stages_after - stages_before).pop()
                self.assertEqual((stage / "rejected.app" / "fixture-version").read_text(), "new")
                self.assertFalse((stage / "previous.app").exists())
                self.assertTrue(any(row["command"] == "mv" and row["argv"][-1].endswith("/rejected.app") for row in records))
                self.assertNotIn("installed ", result.stdout)

    def test_success_replaces_app_keeps_old_copy_and_never_launches(self):
        result, records = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "fixture-version").read_text(), "new")
        backups = list(self.applications.glob(".forit-dictate-install.*/previous.app/fixture-version"))
        self.assertEqual([path.read_text() for path in backups], ["old"])
        self.assertEqual(sum(row["command"] == "pgrep" for row in records), 2)
        self.assertEqual(sum(row["command"] == "lsregister" for row in records), 1)
        staples = [row for row in records if row["command"] == "xcrun"]
        self.assertTrue(any(row["argv"][-1].endswith(".dmg") for row in staples))
        self.assertTrue(any(row["argv"][-1].endswith(".app") for row in staples))
        self.assertIn("1842", result.stdout)

    def test_parent_guard_refuses_process_and_network_without_launching(self):
        with self.assertRaisesRegex(AssertionError, "unowned subprocess"):
            subprocess.run(["/bin/true"], check=True)
        with self.assertRaisesRegex(AssertionError, "network/process"):
            socket.create_connection(("127.0.0.1", 9), timeout=0.01)


if __name__ == "__main__":
    unittest.main()
