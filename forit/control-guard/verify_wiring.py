#!/usr/bin/env python3
"""Offline source-preparation checks; this is not the Common guard or its adapter.

Read the actual OpenStep project, including synchronized membership and explicit
Sources entries. Compare only checked-in Swift membership and prospective phase
wiring. Never run a compiler, Package.swift, or the production guard.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


REPORT_ROOT = "/Users/Shared/forit-build-artifacts/for-Dictate/control-guard"
PROJECT = "VoiceInk.xcodeproj/project.pbxproj"
INPUT_SCHEMA = "forit.control-guard.inputs.v1"
GUARD_NAME = "Shared controls BR-3"
SOURCE_SUFFIXES = {".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".cxx", ".storyboard", ".xib"}
# Known compiler/source-generator inputs outside the upstream guard's supported
# source/interface suffixes must not disappear from synchronized membership.
# This is a refusal set, not a claim that every language compiles in stock Xcode.
# Clang's extension dispatch: clang/lib/Driver/Types.cpp, lookupTypeForExtension.
# Apple documents Metal compilation and lex/yacc-derived sources here:
# https://developer.apple.com/documentation/metal/metal-libraries
# https://developer.apple.com/documentation/xcode/build-settings-reference
UNSUPPORTED_COMPILER_SUFFIXES = {
    ".s", ".asm", ".metal", ".l", ".lm", ".lex", ".y", ".ym", ".yacc", ".yy", ".ypp",
    ".cp", ".c++", ".i", ".ii", ".mi", ".mii", ".ccm", ".cppm", ".cxxm", ".c++m", ".iim",
    ".cl", ".cli", ".clcpp", ".clii", ".ll", ".cu", ".cui", ".hip", ".hlsl",
    ".defs", ".mig", ".d", ".f", ".for", ".ftn", ".fpp", ".f90", ".f95", ".f03", ".f08",
    ".applescript", ".r", ".rez",
}
DECLARED_SOURCE_TYPES = {
    "sourcecode.swift": ".swift", "sourcecode.c.c": ".c",
    "sourcecode.c.objc": ".m", "sourcecode.cpp.cpp": ".cpp",
    "sourcecode.cpp.objcpp": ".mm", "file.storyboard": ".storyboard",
    "file.xib": ".xib",
}


class VerificationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


class OpenStep:
    """Parse dictionaries/arrays without treating comments as project membership."""
    def __init__(self, text):
        self.tokens = []
        pattern = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', re.S)
        offset = 0
        for match in pattern.finditer(text):
            require(match.start() == offset, "unparsed OpenStep input")
            offset = match.end()
            token = match.group()
            if token.isspace() or token.startswith(("/*", "//")):
                continue
            self.tokens.append(token)
        require(offset == len(text), "incomplete OpenStep input")
        self.index = 0

    def take(self, expected=None):
        require(self.index < len(self.tokens), "incomplete OpenStep value")
        token = self.tokens[self.index]
        self.index += 1
        require(expected is None or token == expected, "expected " + str(expected) + ", found " + token)
        return token

    def value(self):
        token = self.take()
        if token == "{":
            result = {}
            while self.tokens[self.index] != "}":
                key = self.value()
                require(isinstance(key, str) and key not in result, "duplicate/nonliteral dictionary key")
                self.take("=")
                result[key] = self.value()
                self.take(";")
            self.take("}")
            return result
        if token == "(":
            result = []
            while self.tokens[self.index] != ")":
                result.append(self.value())
                if self.tokens[self.index] != ",":
                    break
                self.take(",")
            self.take(")")
            return result
        require(token not in "})=;,", "invalid OpenStep scalar")
        if token.startswith('"'):
            # The project's quoted scalars use JSON-compatible escapes.
            return json.loads(token)
        return token

    def parse(self):
        result = self.value()
        require(self.index == len(self.tokens), "trailing OpenStep input")
        return result


def load_project(root):
    path = root / PROJECT
    data = OpenStep(path.read_text()).parse()
    objects = data["objects"]
    project = objects[data["rootObject"]]
    require(project["isa"] == "PBXProject", "rootObject is not PBXProject")
    require(not project.get("projectDirPath") and not project.get("projectRoot"), "nondefault project roots need review")
    return objects, project


def reference_paths(root, objects, project):
    paths = {}

    def visit(identifier, parent):
        require(identifier not in paths, "multiple group parents need review: " + identifier)
        item = objects[identifier]
        tree = item.get("sourceTree", "<group>")
        require(tree in {"<group>", "SOURCE_ROOT", "SDKROOT", "BUILT_PRODUCTS_DIR"}, "unsupported sourceTree " + tree)
        if tree in {"SDKROOT", "BUILT_PRODUCTS_DIR"}:
            return
        raw = item.get("path", "")
        if "$" in raw:
            # Framework search paths are not source references. Resolve a compiled
            # reference below only if its path is a literal inside the checkout.
            paths[identifier] = None
            return
        path = (root if tree == "SOURCE_ROOT" else parent) / raw
        paths[identifier] = path
        for child in item.get("children", []):
            visit(child, path)

    visit(project["mainGroup"], root)
    return paths


def config_settings(objects, identifier):
    configs = objects[objects[identifier]["buildConfigurationList"]]["buildConfigurations"]
    require(all(not objects[c].get("baseConfigurationReference") for c in configs), "xcconfig-derived settings need a reviewed adapter")
    return {objects[c]["name"]: objects[c]["buildSettings"] for c in configs}


def source_name(root, path):
    require(path is not None and path.is_file() and not path.is_symlink(), "missing/nonliteral/symlink compile source: " + str(path))
    require(root in path.resolve().parents, "source escapes project root: " + str(path))
    return path.resolve().relative_to(root).as_posix()


def declared_source_kind(reference, path):
    require(reference.get("isa") == "PBXFileReference", "unsupported Sources reference kind")
    # Xcode's declared type controls compilation even when the filename suffix
    # differs. Never silently drop a Sources entry with an unreviewed type.
    declared = reference.get("explicitFileType", reference.get("lastKnownFileType"))
    if declared is not None:
        require(declared in DECLARED_SOURCE_TYPES, "unsupported declared Sources file type: " + str(declared))
        return DECLARED_SOURCE_TYPES[declared]
    suffix = path.suffix.lower()
    require(suffix in SOURCE_SUFFIXES, "unsupported inferred Sources file type: " + str(path))
    return suffix


def inventory(root):
    """Current project-owned source/interface inputs, not derived/package inputs."""
    root = root.resolve()
    objects, project = load_project(root)
    paths = reference_paths(root, objects, project)
    project_configs = config_settings(objects, next(k for k, v in objects.items() if v is project))
    targets = {}
    for tid in project["targets"]:
        target = objects[tid]
        require(target["isa"] == "PBXNativeTarget", "non-native project target needs review")
        product_type = target["productType"]
        if product_type in {"com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ui-testing"}:
            continue
        name = target["name"]
        require(name not in targets, "duplicate target name")
        require(not target.get("buildRules"), name + ": custom build-rule generated inputs need review")
        target_configs = config_settings(objects, tid)
        require(set(target_configs) == set(project_configs), name + ": build configuration mismatch")
        settings = {}
        for config_name, config in target_configs.items():
            merged = dict(project_configs[config_name], **config)
            require(merged.get("SDKROOT") == "macosx", name + ": non-macOS SDK")
            require(merged.get("ENABLE_USER_SCRIPT_SANDBOXING") == "YES", name + "/" + config_name + ": ENABLE_USER_SCRIPT_SANDBOXING must be YES")
            for key in merged:
                require(not key.startswith(("EXCLUDED_SOURCE_FILE_NAMES", "INCLUDED_SOURCE_FILE_NAMES")), name + ": conditional source selection needs review")
                require(not key.startswith("ENABLE_USER_SCRIPT_SANDBOXING["), name + ": conditional sandbox settings need review")
            settings[config_name] = merged
        source_list = []
        swift_sources = set()
        sync_roots = []
        for gid in target.get("fileSystemSynchronizedGroups", []):
            group = objects[gid]
            require(group["isa"] == "PBXFileSystemSynchronizedRootGroup", "unsupported synchronized group")
            require(not group.get("explicitFileTypes") and not group.get("explicitFolders"), "synchronized explicit type/folder overrides need review")
            path = paths[gid]
            require(path is not None and path.is_dir() and not path.is_symlink(), "missing/symlink synchronized root")
            excluded = set()
            for eid in group.get("exceptions", []):
                exception = objects[eid]
                require(exception["isa"] == "PBXFileSystemSynchronizedBuildFileExceptionSet", "unsupported synchronized exception")
                require(set(exception) <= {"isa", "target", "membershipExceptions"}, "synchronized exception overrides need review")
                if exception["target"] == tid:
                    excluded.update(exception.get("membershipExceptions", []))
            for candidate in sorted(path.rglob("*")):
                require(not candidate.is_symlink(), "symlink in synchronized root: " + str(candidate))
                relative = candidate.relative_to(path).as_posix()
                if any(relative == e or relative.startswith(e.rstrip("/") + "/") for e in excluded):
                    continue
                suffix = candidate.suffix.lower()
                require(suffix not in UNSUPPORTED_COMPILER_SUFFIXES, name + ": unsupported synchronized compiler input needs a reviewed adapter: " + relative)
                if suffix in SOURCE_SUFFIXES:
                    source = source_name(root, candidate)
                    source_list.append(source)
                    if suffix == ".swift":
                        swift_sources.add(source)
            sync_roots.append(path.relative_to(root).as_posix())
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            for build_id in phase.get("files", []):
                build_file = objects[build_id]
                require(build_file["isa"] == "PBXBuildFile" and not build_file.get("settings") and not build_file.get("platformFilter") and not build_file.get("platformFilters"), "filtered/overridden Sources entry needs review")
                reference = objects[build_file["fileRef"]]
                path = paths[build_file["fileRef"]]
                require(path is not None, "nonliteral Sources entry")
                kind = declared_source_kind(reference, path)
                source = source_name(root, path)
                source_list.append(source)
                if kind == ".swift":
                    swift_sources.add(source)
        require(source_list and len(source_list) == len(set(source_list)), name + ": empty/duplicate compile inputs")
        targets[name] = {"target": target, "sources": sorted(source_list), "swiftSources": swift_sources, "settings": settings,
                         "syncRoots": sync_roots, "productType": product_type}
    require(targets, "no shipping targets")
    return objects, targets


def manifest_for(root, target_name):
    _, targets = inventory(root)
    return {"schema": INPUT_SCHEMA, "root": "../..", "target": target_name, "platform": "macOS",
            "sources": targets[target_name]["sources"], "bridges": []}


def verify(root):
    root = root.resolve()
    objects, targets = inventory(root)
    config = json.loads((root / "forit-app.json").read_text())
    records = config["controlGuard"]["targets"]
    require(set(records) == set(targets), "config omits/adds a shipping target, including XPC")
    result = {}
    for name, data in targets.items():
        input_rel = "forit/control-guard/" + name + "-macOS-inputs.json"
        report_path = REPORT_ROOT + "/" + name + "-macOS.json"
        require(records[name] == [{"platform": "macOS", "inputs": input_rel, "report": report_path}], name + ": wrong inputs/report platform record")
        inputs = json.loads((root / input_rel).read_text())
        require(inputs.get("schema") == INPUT_SCHEMA and inputs.get("target") == name and inputs.get("platform") == "macOS", name + ": manifest schema/identity mismatch")
        require((root / input_rel).parent.joinpath(inputs["root"]).resolve() == root, name + ": manifest root mismatch")
        sources = inputs["sources"]
        require(isinstance(sources, list) and len(sources) == len(set(sources)), name + ": duplicate/invalid manifest input")
        require(sources == data["sources"], name + ": checked-in Swift compile inputs differ (missing=" + repr(sorted(set(data["sources"]) - set(sources))) + ", extra=" + repr(sorted(set(sources) - set(data["sources"]))) + ")")
        # A future canonical bridge added to a synchronized root must be listed as
        # actual source, then explicitly declared and revision-bound. No fake bridge.
        require(inputs.get("bridges") == [], name + ": bridge requires reviewed canonical export/admission")
        phases = [objects[p] for p in data["target"]["buildPhases"]]
        phase = phases[0]
        require(phase.get("isa") == "PBXShellScriptBuildPhase" and phase.get("name") == GUARD_NAME, name + ": guard phase must be first")
        require(phase.get("alwaysOutOfDate") == "1" and phase.get("buildActionMask") == "2147483647" and phase.get("runOnlyForDeploymentPostprocessing") == "0", name + ": guard must run every build")
        command = 'exec /usr/bin/python3 -I "$FORIT_COMMON_ROOT/Scripts/control-guard/control_guard.py" --inputs "$SRCROOT/' + input_rel + '" --report "' + report_path + '"\n'
        require(phase.get("shellPath") == "/bin/sh" and phase.get("shellScript") == command, name + ": guard must directly exec the exact trusted tool/input/report pair")
        require(phase.get("inputPaths") == ["$(SRCROOT)", "$(FORIT_COMMON_ROOT)"] and phase.get("outputPaths") == [report_path], name + ": sandbox declarations differ")
        require(sum(p.get("name") == GUARD_NAME for p in phases) == 1, name + ": duplicate guard phases")
        result[name] = {"platform": "macOS", "projectOwnedSourceAndInterfaceInputs": len(sources), "projectOwnedSwiftCompileInputs": len(data["swiftSources"]), "synchronizedRoots": data["syncRoots"], "productType": data["productType"], "configurations": sorted(data["settings"]), "generatedAssetSymbolsEnabled": any(v.get("ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS") == "YES" for v in data["settings"].values()), "packageProducts": [objects[p]["productName"] for p in data["target"].get("packageProductDependencies", [])]}
    return {"schema": "forit.dictate.guard-preparation-check.v1", "state": "PASS_PREPARATION_ONLY", "projectSHA256": hashlib.sha256((root / PROJECT).read_bytes()).hexdigest(), "targets": result, "fullBuildCompileInputsProven": False, "productionGuardAdmitted": False, "nativeBuildOrRenderProof": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--print-inputs", metavar="TARGET", help="print project-owned Swift manifest for review; does not write it")
    parser.add_argument("--report", type=Path, help="optional preparation evidence outside the checkout; parent must exist")
    args = parser.parse_args()
    try:
        report = manifest_for(args.root, args.print_inputs) if args.print_inputs else verify(args.root)
        encoded = json.dumps(report, indent=2) + "\n"
        if args.report:
            destination = args.report.resolve()
            require(args.root.resolve() not in destination.parents, "preparation report must be outside the checkout")
            destination.write_text(encoded)
        print(encoded, end="")
        return 0
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        print("guard preparation verification failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
