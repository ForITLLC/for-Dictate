# Dictate shared-control source audit

Task `6A908F35`, 2026-10-18. **Source preparation only; no native, screenshot, AX, build, shipment or conformance pass.** Baseline is canonical `ForITLLC/for-Dictate` commit `0fef1a4b073ab5cc95ab7d0bb6e04786ffe0cf3c`. Every source hash and source line below refers to that immutable commit, read with `git show`, even when the working tree changes during migration. Root-owned adoption/migration artifacts describe subsequent edits separately.

Governing requirements: `/home/runner/dispatch/specs/apple-app-goals.md` and the exact Dictate entry in `/home/runner/handoffs/for-iCommon/shared-control-audit-20261018/census.json`. Their hashes are retained in [inventory.json](inventory.json). No worktree/ancestor `CLAUDE.md` or `AGENTS.md` file was found in the checked paths; session instructions apply. Upstream `CONTRIBUTING.md` says PRs are not accepted; this internal ForIT source task has explicit authorization.

## Targets and platforms

The PBX target list, synchronized roots, membership exceptions and explicit source phases were examined together ([project](../../VoiceInk.xcodeproj/project.pbxproj), baseline lines 94, 111, 240, 442). Synchronized-root exclusions contain only `Info.plist`; the shared XPC protocol is an explicit source of both shipping targets.

| Target | Kind | Local Swift inputs | Lines | Platform |
|---|---|---:|---:|---|
| VoiceInk | App | 352 = 351 under VoiceInk + shared protocol | 68,224 | Native Mac, minimum 15.0 |
| VoiceInkRefineXPC | Embedded XPC service | 4 = 3 under service + shared protocol | 552 | Native Mac, minimum 15.0 |
| VoiceInkTests | Unit test | 0; synchronized source directory absent | 0 | Mac |
| VoiceInkUITests | UI test | 2 | 76 | Mac |

There are **357 tracked Swift files / 68,798 lines**, **355 unique shipping Swift inputs**, and **358 target memberships** including tests. The protocol is counted twice in target memberships, once in the unique union. This is declared repository input coverage; no compiler invocation was performed. External SwiftPM products are listed per target in the inventory, with versions in the baseline lockfile; their resolved-checkout compiler inputs were not obtained.

| Platform/surface | Observed source | Applicability |
|---|---|---|
| Mac | One app plus XPC service | Shipping source in this audit |
| iPhone / iPad / Vision Pro | No targets or SDK configurations | **Product gaps** against the governing cross-platform goal; not presumed excluded |
| Web | No counterpart source or target found | “Where present” has no existing counterpart in this tree |
| Watch | No target | Absent; no Watch runtime claim |
| WidgetKit / Live Activity / Control extension | No targets or imports | No actual widget families, rendering modes or captures to test |

Canonical `0fef1a4` and related build-repository `05ee19bb1615d1a1c60c986153caf1d08faa80f5` both resolve locally to tree `bb00b5baa21a4e50ae87802e5cf8cd816159bae1`; `git diff --stat` is empty. Baseline **content identity is verified**: there is no separate controls implementation in the build baseline. This does not transfer release custody or establish future mirror promotion. The actual release owner still owns that route; no foreign repository was edited.

## Control inventory and root cause

[inventory.json](inventory.json) enumerates every detected control source site with compact file IDs resolving to path/hash, baseline line, owning type, local style/geometry/appearance modifiers, disabled/destructive/AX declarations, native-host category and required role. `categoryKey` and `roleKey` decode short classification codes; array fields are documented in `methodology.compactSchema`. Comments and strings are masked before exact-constructor matching. Counts are **source sites**, including a DEBUG-only button and compiled helpers/previews; they are not visible element totals or proof that every helper is reachable.

| Primitive constructor | Sites |
|---|---:|
| Button | 228 |
| Picker | 38 |
| Toggle | 27 |
| TextField | 21 |
| Menu | 18 |
| TextEditor / SecureField | 6 / 5 |
| Link / NSButton | 3 / 3 |
| **Total** | **349** |

A separate 32 sites cover 21 tap handlers, 2 gestures, 1 simultaneous gesture and 8 NSAlert buttons. Seven legacy SwiftUI Alert.Button factory sites are also enumerated; these preserve native destructive/cancel semantics. Another 15 host sites cover 5 alerts, 5 open panels, 4 save panels and the real `LockedTextView` input. The inventory also lists 258 local composite calls, including nested screens; these are not additional button totals. Of 388 constructor/interaction sites, source classification finds 74 system-hosted, 135 system-default, 149 plain/app-label chrome, 6 custom-style and 24 gesture sites. A native system menu or save panel is not an app-owned rounded control merely because its source contains `Button`.

The baseline has **no Common package/product/import**. Control geometry is owned by local wrappers and feature views. Representative duplication and missing roles:

| Source at baseline | Finding and migration need |
|---|---|
| `VoiceInk/DesignSystem/Components/AppControls.swift:73`, `:81` | `AppActionButtonStyle` owns 32-point height, radius 9, fill, border and disabled opacity for primary/secondary/destructive actions. Existing shared action APIs are candidates only where semantics and sizing match. |
| `VoiceInk/Features/Onboarding/Components/OnboardingSections.swift:114`, `:130` | Back/Continue own local surfaces, fonts and disabled colors; metrics at `:86` use 132-point width and 42-point height. Shared-style adoption must remove inner height overrides and test the actual 950×750 onboarding layout at AX5. |
| `VoiceInk/DesignSystem/Components/AppControls.swift:32`, `VoiceInk/Features/History/Components/HistoryComponents.swift:213` | Icon controls use 40/28-point and 34×32 local geometry. Need a shared compact/icon role with equivalent name/help/focus behavior. |
| `VoiceInk/Features/Recording/Components/RecorderComponents.swift:65`, `:85`, `:163` | Recorder state/close faces use 21-point circles; state labels and disabled busy states are functional. Need a canonical stateful recorder/icon role, not an unreviewed full-size action substitution. |
| `VoiceInk/App/Navigation/AppSidebar.swift:136`, `VoiceInk/Features/Dashboard/Components/DashboardInsightCardBackground.swift:39` | Selected navigation rows and insight period buttons own their geometry. Need selected-row/choice APIs, preserving selection traits and binding. |
| `VoiceInk/Features/History/Components/TranscriptionListItem.swift:12`, `:70` | Circular checkbox style renders a Button and toggles the binding. Preserve checkbox state and test AX role rather than assuming the appearance establishes semantics. |
| `VoiceInk/Features/Dictionary/Views/DictionaryPill.swift:40`, `VoiceInk/DesignSystem/Components/InfoTip.swift:43` | Removable chips and image/popover tap actions need canonical chip/info-link roles plus AX names/actions. |
| `VoiceInk/App/MenuBar/MenuBarView.swift:51`, `VoiceInk/Features/Settings/Backup/ImportExportService.swift:15` | Native menu choices and native panel radio/check accessories retain system hosting; preserve keyboard, checkmark, binding and cancellation semantics. |
| `VoiceInk/Features/Onboarding/Components/OnboardingLockedTextEditor.swift:20` | Custom NSTextView subclass intentionally locks manual editing. A generic field replacement would change behavior. |

All 324 shape/corner-radius source sites are separately categorized: **173 control chrome, 81 domain/status art, 61 passive containers/decoration and 9 mixed-use surface helper sites**. These source-context classifications are review aids, not visual conformance proof. Shared card helpers can supply a button label or a passive card; their consumer context matters. Do not forbid data colors or radii indiscriminately.

`DashboardActivityCalendarCard.swift` is a **SwiftUI dashboard heatmap compiled into VoiceInk**, not a WidgetKit extension: source line 1 imports SwiftUI, line 92 creates calendar cells and line 175 handles hover. Its intensity colors are domain data. The three census “widget test” paths are recording/dictionary/statistics snapshot logic, not widget test targets. There are no widget screenshots in this deliverable.

The current window uses a local sidebar/settings destination and hidden titlebar (`VoiceInk/App/VoiceInk.swift:349`; `VoiceInk/App/Windows/WindowManager.swift:82`), so this audit does not claim the shared ForIT top-bar/menu goal is met. A separate pre-existing behavior gap is explicit: History's delete confirmation says it cannot be undone (`VoiceInk/Features/History/Views/HistoryView.swift:150`), while the governing spec requires undo. Confirmation exists at `:141`; undo remains unproved/missing and must not be reported as passing.

## Native evidence preparation

[device-evidence-plan.json](device-evidence-plan.json) defines **33 actual-Mac surface cases × light/dark × default/AX5 = 132 planned case/variant pairs**, with applicable disabled, selected, busy and destructive states. It assigns all 388 constructor/interaction sites and 15 native hosts to real app routes. Main navigation, dashboard, modes/triggers, model/provider/settings panels, dictionary, audio import/settings, history/detail/playback, onboarding, recorder, menu bar, notifications and native file/alert panels are covered.

Every case requires actual-app screenshots, AX hierarchy/bounds/actions and keyboard/interaction receipts against deterministic fake state. No capture harness or fixture seam was implemented by this documentation task. AX5 on Mac needs an approved actual-host accessibility fixture and explicit setting metadata; a scaled image is not AX5 evidence. Gated/unused compiled helpers require runtime reachability confirmation and must not receive fabricated screenshots.

Existing UI tests only launch/measure and attach a generic launch screenshot; they do not assert this control matrix (`Tests/VoiceInkUITests/VoiceInkUITests.swift:29`, `VoiceInkUITestsLaunchTests.swift:22`). **Captures, AX runs and interactions executed: zero.** Fresh exact-source native admission from sole custodian `term_82c6de35-132b-4181-9a96-ce0f798bed9a` is required. All Mini, native, upload, old-GO and schedule holds remain in force. Five additional footer layout cases explicitly require AX5/long-label growth and final scroll-content visibility in the actual affected consumers.

Verification completed for these artifacts: JSON parse/readback, all target-member SHA-256 values against immutable baseline bytes, all control/shape/native-host anchors within baseline files, unique IDs and complete one-to-one case assignments. No source, project, script, test, remote or runtime change was made by this audit subtask.
