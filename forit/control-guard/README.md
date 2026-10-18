# Dictate shared-control guard preparation

This is source preparation for task `6A908F35`. **The production guard is not
admitted, and full build-input coverage is not proven.** No native build, test,
rendering proof, upload, runner change, or previous GO is evidence for this change.

The actual project is `VoiceInk.xcodeproj/project.pbxproj`; this repository has no
XcodeGen spec. The conformance gate reads `forit-app.json` at the project root, so
the configuration lives there rather than under `forit/`.

## Current project membership

The input manifests use the upstream `forit.control-guard.inputs.v1` schema.
Their `root` is `../..`, resolved relative to each manifest, which is the actual
Xcode project root. Both target/platform records are explicitly `macOS`.

| Shipping target | Product | Project-owned Swift inputs | Membership |
| --- | --- | ---: | --- |
| VoiceInk | application | 352 | 351 synchronized `VoiceInk/` files plus explicit `Shared/VoiceInkRefineXPCProtocol.swift` |
| VoiceInkRefineXPC | XPC service | 4 | 3 synchronized `VoiceInkRefineXPC/` files plus the same explicit Shared source |

That is **356 target memberships and 355 unique project-owned Swift files**.
`VoiceInkTests` and `VoiceInkUITests` are test products. There is no other
project-owned shipping framework or extension target in this project. Linked
package products and the external `whisper.xcframework` remain separate closure
questions below. Both shipping targets inherit `SDKROOT = macosx` in Debug and
Release. Their only current synchronized membership exception is `Info.plist`.
No source folder name creates an exemption.

These manifests enumerate all current project-owned source/interface inputs
identified from the real project and filesystem, including explicit Sources
entries outside synchronized roots. They do **not** claim to enumerate derived
Swift files or every linked dependency's source. They currently contain no
bridge declarations because no canonical exported bridge is present in these
targets. A future canonical bridge must be included as actual compiled source,
declared in `bridges`, authenticated against the admitted immutable Common
revision, and matched in phase/configuration; do not create placeholder outputs.

## Prospective precompile phases

Each shipping target has `Shared controls BR-3` as its first build phase, before
Sources. Each phase has `alwaysOutOfDate = 1`, all build actions enabled, and
`runOnlyForDeploymentPostprocessing = 0`. The single shell command directly
`exec`s `/usr/bin/python3 -I` with the trusted Common checkout's
`Scripts/control-guard/control_guard.py`, one literal input manifest, and one
literal absolute report path. There is no wrapper, waiver, bypass, error masking,
dependency-analysis skip, or app-owned copy of the guard.

| Target | Input relative to `$SRCROOT` | Exact retained report path |
| --- | --- | --- |
| VoiceInk | `forit/control-guard/VoiceInk-macOS-inputs.json` | `/Users/Shared/forit-build-artifacts/for-Dictate/control-guard/VoiceInk-macOS.json` |
| VoiceInkRefineXPC | `forit/control-guard/VoiceInkRefineXPC-macOS-inputs.json` | `/Users/Shared/forit-build-artifacts/for-Dictate/control-guard/VoiceInkRefineXPC-macOS.json` |

The same exact pairs appear in root `forit-app.json`. Reports stay outside the
source checkout. A future maintained build owner must provision their parent
directory **before** invoking the guard, retain the reports with that build's
artifacts, and serialize or isolate builds sharing these fixed paths. The phases
do not create the directory or infer paths from environment variables.

`FORIT_COMMON_ROOT` must be provisioned by the maintained build owner as the
trusted, official, frozen Common tool/dependency checkout. No app-local override
or candidate revision is installed here. A missing tool/root, rejected inputs,
analysis findings, or unwritable report fails the phase. The project retains its
existing `ENABLE_USER_SCRIPT_SANDBOXING = YES`; phases declare read access to
`$(SRCROOT)` and `$(FORIT_COMMON_ROOT)` and write access to their exact report.
Native verification must establish that these declarations cover the maintained
checkout layout, including any Git indirection and tool dependencies. Sandboxing
has not been disabled to make this preparation appear operative.

## Admission blockers

1. The current Common production adapter accepts literal XcodeGen source graphs
   and `preBuildScripts`. It rejects this actual PBX project. An offline call to
   the live upstream `source_graph.load_graph` for **both** shipping targets
   returned `a literal project.yml at the compile root is required`. A tested
   upstream PBX source-graph **and phase-wiring** adapter is required. The local
   verifier below is preparation evidence only; it is not a substitute adapter
   for the maintained guard or conformance gate.
2. The inspected upstream gate's shipping-target selection includes apps,
   extensions and Watch products but does not select `xpc-service`. Dictate
   nevertheless declares and wires its XPC target. Upstream must cover that
   product and every shipping linked framework/module; omission cannot count as
   a passing gate.
3. Both configurations enable generated Swift asset symbols at project scope.
   The exact derived Swift compile paths/content and their generation ordering
   are not available from this authorized source-only run. The admitted adapter
   must capture generated inputs and invoke analysis after they exist but before
   compilation. It must also resolve linked package/module/interface inputs,
   conditional membership and the external framework's rendering boundary.
   The current app links nine package products, including published Common
   `0.30.4`; XPC links five. Common's source graph must also be covered. The checked-in manifests are not proof
   of that complete dependency/derived closure.
4. The inspected live Common checkout is a dirty source candidate, not a tested
   published immutable release. Trusted tool provisioning, package/bridge
   admission, any missing canonical roles, report custody, concurrent-build
   isolation and sandbox execution remain prerequisites. This preparation pins
   no unpublished Common code and changes no existing package requirements.
5. Source-policy acceptance, native compilation, interaction/accessibility and
   rendering are separate evidence. No production guard report or native proof
   is generated or claimed here. Existing source findings must be resolved or
   supported by reviewed upstream semantics; BR-3 has no app waiver.

The upstream contract was inspected on 2026-10-18 at
`/home/runner/orca/workspaces/for-iCommon/shared-control-audit`. The observed working
files had these SHA256 values (these identify observations, not release pins):

| File under that checkout | SHA256 |
| --- | --- |
| `Scripts/control-guard/control_guard.py` | `c5f1656a251fcbb96456db38474bd1df1cdb2e1bd884444dadb7728d4e45105b` |
| `Scripts/control-guard/source_graph.py` | `b59ad78d0719678a905e211f8fb945d19b4cace47ea3c1e242089c8a37a02499` |
| `Scripts/forit-gate/forit-gate.py` | `c9be7ef222eed0d8ff763dbfddfb306f630d116ab2fcca07cc4d179c927264fd` |

Reinspect the maintained published adapter before admission; these candidate
files can change independently of this app.

## Offline preparation checks

From the project root, on Linux or macOS, without running any native tool:

```sh
python3 -B forit/control-guard/verify_wiring.py --report /tmp/dictate-control-guard-preparation.json
python3 -B forit/control-guard/test_verify_wiring.py
git diff --check
```

The standard-library OpenStep parser independently walks the actual PBX group
hierarchy, synchronized exceptions, explicit Sources entries, all non-test
shipping targets and inherited Debug/Release settings. It compares complete
current project-owned input sets and checks first/every-build phase placement,
literal direct-exec arguments, sandbox declarations, effective
`ENABLE_USER_SCRIPT_SANDBOXING = YES` in every shipping configuration and exact
configuration pairs. Explicit Sources entries use `explicitFileType` (or
`lastKnownFileType`) before inferring type from their filename, so a Swift source
renamed to `.inc` cannot disappear from either manifest. Unsupported declared
Sources types, conditional sandbox settings, source-selection overrides,
external xcconfig settings, symlinks, duplicate inputs and custom build-rule
generation fail this preparation check. This membership accounting does not
extend the production guard's accepted filename suffixes or adapter support.

Its successful result is `PASS_PREPARATION_ONLY`, with
`fullBuildCompileInputsProven`, `productionGuardAdmitted`, and
`nativeBuildOrRenderProof` all `false`. The mutation suite tests omitted Shared
sources, omitted XPC, newly synchronized Swift/native sources even in test-like
directories, actual membership exceptions, renamed explicitly typed Swift
sources, unsupported source types, symlinks, platform/root mismatches, disabled
sandboxing in every shipping configuration, skippable or moved phases, error
masking, wrappers and mismatched report paths.
These are checks of the preparation's claimed scope, not BR-3 conformance tests.

After a reviewed source membership change, the same parser can print a fresh
project-owned input manifest for inspection with `--print-inputs VoiceInk` or
`--print-inputs VoiceInkRefineXPC`. It does not write manifests, modify the
project, invent generated/bridge inputs, or execute any build command.
