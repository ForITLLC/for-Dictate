# Company dictionary native UI check

This is app-owned source preparation under work
[9A177608](https://tasks.forit.io/?task=9A177608-8178-4CD2-9972-420533BF6D3C).
The UI source/seam checkpoint is `aecf716002d42e0f1b9d64ad3d84ce9aaeaeca03`.
The corrected fixture source below has not had a native retry. The first actual
attempt failed during compilation, before captures or interactions; those checks
remain **native UNRUN** until a qualified owner-pinned retry succeeds.
The earlier 141 core tests belong to `77274cf`; full-app compile PASS belongs to
`164b025`, not this check.

## First native attempt

Job `apple-for-Dictate-b4330cf379cb-d8235cefdbe3` ran exact source
`b4330cf379cba60eeadf1878f0787fd6e23072e3` and ended with exit 1 in compilation.
Its retained compile-phase receipt spans 2026-11-10 08:13:20Z–08:13:41Z.
The concrete fixture error was the SDK rename from `NSArgumentDomain` to
`UserDefaults.argumentDomain`. The same log recorded the actor-isolated `.shared`
default-argument warning in `CompanyDictionaryView.init` and the tools-6 manifest
deprecation of `swiftLanguageVersions`. This correction uses an explicit
main-actor zero-argument initializer forwarding to the injected initializer,
the renamed defaults constant and `swiftLanguageModes: [.v5]`. It preserves
Swift 5 and every fixture/isolation/assertion boundary.

The retained receipt has zero completed cells and `acceptanceComplete: false`.
The owner's terminal receipt reports source/process/gate/simulator cleanup true.
This is compiler execution evidence only, with no pixels or interaction proof.
The owner must commit and repin the corrected exact source before the sole retry;
this document is not a retry or runtime-acceptance claim.

The retained compiler invocation also references Xcode 27.2 SwiftPM backend
products under `package/.build/out/Products/Debug`. The first attempt never reached
product collection, so existence of a `.build/debug` alias was not established
and this is not a confirmed second failure. After a successful build the driver
now runs supported `xcrun swift build --package-path PACKAGE --configuration debug
--show-bin-path` through the same owned process group with a 30-second timeout.
Path stdout and stderr diagnostics have separate owned `.log` files. Accepted
stdout is at most 4096 bytes and contains exactly one absolute path; the products
directory and executable are strictly resolved and must remain inside the owned
package. There is no global/inherited product location or hardcoded backend
fallback. Binary/resource copying uses the discovered directory, and the receipt
records `nativeProductsRelativePath` and `nativeExecutableRelativePath`.

## Existing owner route

The new owner-pinned Apple platform is `macos-ui-check`. The app adapter is
`/bin/bash scripts/forit-mini-ui-check.sh`; no argument means `--plan`.
`--plan` prints JSON and performs no native/toolchain, host, credential or
environment readiness probes and writes no files. Only the maintained shared
Apple launcher supplies `--execute` after the route is registered and qualified.
The adapter itself neither creates a slot nor starts/replaces a Common gate.
The owner route declares
`common_commit=352f567e839b8faf61b6df5840c5275b016addce`: the existing shared
launcher then clones the clean official Common source, exports
`FORIT_COMMON_ROOT`, and cleans it after the job. No new rail mechanism is needed.

Execution requires Darwin, exact clean `FORIT_SOURCE_COMMIT`, the inherited
`FORIT_GATE_RUN` with its lane marker, and the existing qualified
`FORIT_COMMON_ROOT`. That root must be a clean canonical checkout of the official
`ForITLLC/for-iCommon` source at published 0.31.9 /
`352f567e839b8faf61b6df5840c5275b016addce`. It is used as a local SwiftPM dependency;
no app pin, package lock, Common implementation, macro/plugin policy or global
configuration is changed. Compile uses Debug/Swift 5 and one SwiftPM build job.
The dependency has no external package dependencies at this pin. The driver
retains hashes of every staged production/fixture file and the complete tracked
Common compiler/resource source closure, then rechecks them after execution.

There are no native builds on forit-orca, detached runners or new schedules.
All descendants stay in the existing launcher-owned process group. A timeout
returns 124 with `timeoutCleanupDelegated: true`; collection/cleanup must wait
until the launcher has reaped that group. The adapter never deletes or replaces
pre-existing outputs. The owner job budget is **3300 seconds (55 minutes)**:
20-minute compile and 32 cells bounded at 45 seconds each, with toolchain and
collection headroom. The owner must retain that actual timeout and qualify the
existing UI-session availability.

## Product view and isolated state

The fixture compiles the actual `CompanyDictionaryView`, connection model,
client, DTO, resolver and store/transport protocols. Its root hosts the production
view in a real NavigationStack with the actual shared profile menu, gate and
account section. It does not launch `VoiceInkApp` or its audio/model/preferences
startup. Summary/menu open-window routing and the real Settings destination are
outside this scoped host and remain unexercised.
The fixture host observes the connection model rather than capturing one account
value, so sign-out updates the real profile menu. Requested appearance and content
size are applied before view construction/actions. A visible attached sheet is
selected only through the main window's public `sheets` association; its real
level is preserved and must be normal for the existing ordinary-window route.
The actual target's appearance/content dimensions are verified before subsequent
actions and again before retaining its hierarchy. Unsupported sheet geometry or
level fails instead of presenting a replacement window.

Production convenience initializers remain unchanged. An injected connection
initializer accepts the client, BrowserSignIn, bundle ID, browser opener and
lifecycle-observation choice. The view accepts an owned vocabulary service;
production defaults still use `.shared`.

The fixture supplies memory-only `CompanyDictionaryStore` and transport actors,
an explicit captured clock, an owned cache and catalog/preference URLs under its
cell directory. It does not configure/open a user SwiftData container. Maintenance
polling and lifecycle subscriptions are off; the normal expiry task may exist
inside the finite fixture process and ends with it. `.task` refresh and sign-out
run the real client through these doubles. The production Keychain adapter is
not compiled into the fixture: its fixture-only counterpart aborts if a production
convenience path is accidentally selected. The actual product view/shared
controls are never replaced by test lookalikes.

BrowserSignIn is the actual pinned Common implementation, initialized with a
synthetic `auth.example.invalid` authority/client and ephemeral URLSession whose
deny-all URLProtocol fails every request before network transport. The injected
opener counts calls and returns true without opening any browser. No callback,
ID token, Support mint or private browser-state mutation is needed for real
waiting/Cancel behavior. Authorization URLs, state and nonce are not retained
or printed. Any URLSession attempt or synthetic mint fails the fixture.

The unsigned wrapper has bundle ID `io.forit.dictate.ui-fixture`. AppKit uses
that fixture domain and volatile English locale defaults; application code does
not open `io.forit.dictate`, host credentials, history, clipboard or private
preferences. Normal OS/framework rendering behavior is not a claim of a fully
virtualized macOS environment.

## Finite captures and interactions

Fourteen fixture IDs run at 900×600 content points in light and dark. `full` and
`longnames` also run at 1600×1000, for **32 capture cells**:

| Fixture | Real client/view state or control action |
| --- | --- |
| signedout | No synthetic credential; Connect is available |
| empty | Authenticated complete empty response |
| full | Complete canonical/alias/meaning records and account expiry |
| stale | Eligible saved snapshot plus synthetic 503 |
| error | Synthetic 503 without a saved snapshot |
| loading | A bounded fixture process holds its synthetic request pending |
| search | Real search field receives keyboard text matching an alias; unrelated row disappears |
| longnames | Maximum-length CJK canonical, long aliases/meaning/email and unsupported-hint notice |
| signin | Connect opens the actual shared gate sheet |
| browser-wait | The shared primary action starts actual BrowserSignIn waiting through the count-only opener |
| keyboard-close | Escape closes the actual sheet and cancels its attempt |
| close | The outer Close control closes/cancels the actual sheet |
| cancel | Common's Cancel stops browser waiting while leaving the sheet available |
| signout | Shared confirmation Cancel preserves the session; confirm clears synthetic credential and captured hint lease |

All fixture control actions target only the process's own NSAccessibility objects;
keyboard events go only to one of its registered windows. No system-wide AX,
global input or permission grant is used. If a real control/hierarchy cannot be
identified, the cell fails with its retained hierarchy instead of invoking a
view-model method and pretending the control worked. Already-created provider
payload erasure, full Tab order and real VoiceOver operation remain unexercised.

Captures use the actual published `ForITStandaloneMacHarness.runIfRequested`
ordinary-window source at 0.31.9 and its own-PID window-server capture. They are
not ImageRenderer, cacheDisplay or repainted UI. Its genuine native qualification
and permission behavior remain unverified here. If capture would prompt or the
own-window route fails, retain the refusal; do not enable permissions, capture
another process or silently substitute a bitmap. The finite shared harness
accepts only 900×600/1600×1000; the shipping 620×660 default still needs separate
qualified inspection. AppKit toolbar/profile presence must be checked in actual
pixels and hierarchy; applying the modifier is not a visible-top-bar witness.

Each child receives a newly created owned `TMPDIR` at its cell's `native/`
directory before process launch. The fixture compares actual
`NSTemporaryDirectory()` with that canonical path before any UI/capture work;
an ignored override fails rather than overwriting inherited temporary output.
The driver reads the shared harness's PNG/receipt/mark from this native directory
and joins it to the recorded actual capture surface and geometry. Only the named
native outputs and fixture result/failure JSON are eligible for the archive;
unrelated AppKit temporary files are excluded.

## Evidence contract and acceptance

Artifacts are `build/forit-ui-check/receipt.json`, `evidence.zip` and `*.log`.
Only the first two are explicit `artifactPaths`; logs use the existing automatic
suffix collector.
The ZIP retains original PNGs, each shared native capture receipt/mark and each
fixture model/AX/interaction result, plus a SHA-256 screenshot manifest. Each PNG
is bounded to 16 MiB, all encoded PNGs to 32 MiB and the archive to 40 MiB.
`evidence.zip` and `receipt.json` match the existing explicit-artifact filename
allowlist; this source does not broaden collector or gateway policy. The rail's
separate 64 MiB raw evidence-directory cap is not the explicit-artifact cap.
The driver joins native fixture/appearance/size/PID/window/pixel dimensions to
the actual PNG and source-bound synthetic result. Failed cells retain their
failure JSON/hierarchy and logs; a zero-image or failed cell is never PASS.

`CAPTURED_SCOPED` means the declared captures/local interactions completed. It
always leaves `acceptanceComplete: false`: root still reviews original pixels,
native control frames, 44-point targets, focus/dismissal, long-text wrapping,
contrast and shared profile/gate/account placement against the pinned Common
reference and forit-design-native/forit-validate-design. Missing AX geometry stays
unverified. No artifact establishes source-guard PASS, actual Support access,
Parakeet use/performance, installed Ben-Mac behavior or Ben acceptance.

The read-only PBX audit finds the VoiceInk synchronized root includes 370 tracked
Swift files and excludes only Info.plist, with no Swift membership exceptions.
Its guard manifest declares 351 sources (350 VoiceInk files plus the explicit
Shared protocol). These **20 target-owned Swift files are absent**:

```
VoiceInk/App/MenuBar/DictateGlyphAsset.swift
VoiceInk/App/MenuBar/DictateStatusIcon.swift
VoiceInk/Features/Dictionary/Views/CompanyDictionaryView.swift
VoiceInk/Features/Dictionary/Views/SharedVocabularyView.swift
VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryCallbackRoute.swift
VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryClient.swift
VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryConnectionModel.swift
VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryKeychainStore.swift
VoiceInk/Features/Dictionary/Workflows/CompanyDictionarySnapshot.swift
VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryStore.swift
VoiceInk/Features/Dictionary/Workflows/CompanyDictionaryTransport.swift
VoiceInk/Features/Dictionary/Workflows/SharedVocabulary.swift
VoiceInk/Features/Dictionary/Workflows/SharedVocabularyCatalogLock.swift
VoiceInk/Features/Dictionary/Workflows/SharedVocabularyService.swift
VoiceInk/Features/History/Integrations/TinycastHistoryExporter.swift
VoiceInk/Features/History/Integrations/TinycastHistorySnapshot.swift
VoiceInk/Features/History/Integrations/TinycastHistorySnapshotWriter.swift
VoiceInk/Features/History/Models/HistorySuccessPolicy.swift
VoiceInk/Infrastructure/Audio/Devices/RecordingDeviceSession.swift
VoiceInk/Infrastructure/SystemIntegration/Paste/ClipboardPasteSession.swift
```

The owning published source-graph generator still must refresh/verify the full
closure, including linked/generated inputs; it was not executed in this source
slice. Do not manually append this comparison list. The current app warning-only
BR3 policy is retained. Full-app compile and this fixture do not turn a missing
guard run/report into success; owner-qualified Common-root supply/source
generation remains separate.
