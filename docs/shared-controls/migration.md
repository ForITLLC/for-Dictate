# Dictate shared-control migration

Task: `6A908F35-88E6-4266-A043-35CE95BEF60F` under shared-controls epic
`4D12F44F-B0E7-4417-BE35-17321BA6E3B8`.

This is source preparation. It does not authorize a native build, simulator,
device interaction, Mini contact, staging, upload, release or reuse of an old GO.
The first-dictation watcher and its expired window remain unchanged.

## Source and platform scope

The canonical baseline is `ForITLLC/for-Dictate/main` at
`0fef1a4b073ab5cc95ab7d0bb6e04786ffe0cf3c`. Its tree is
`bb00b5baa21a4e50ae87802e5cf8cd816159bae1`, identical to the related
`ForITLLC/for-Dictate-build/main` at
`05ee19bb1615d1a1c60c986153caf1d08faa80f5` when checked on 2026-10-18.
The build repository is not an independent control implementation in this
baseline. This PR changes only canonical source. Future mirror promotion and
release remain with their actual owners; content identity does not transfer
release custody.

The project currently ships a macOS 15 app and its XPC service. There is no
WidgetKit, Watch, Live Activity, Control extension or web target here. The
dashboard activity calendar is application content, not a WidgetKit extension.
iPhone, iPad and Vision remain product-platform gaps. See `audit.md` and
`inventory.json` for the complete source census and applicability matrix.

## Shared roles and adoption boundary

The published Common primary/secondary API and the unreleased role expansion
must be distinguished. The candidate working tree has text, icon, choice,
content-row, removable-chip, density and destructive-palette additions that
are not all present in its committed HEAD. Exporting HEAD does not export its
dirty source. No generated controls or forked control implementation is
introduced by this PR.

The high-leverage compatible migrations are ordinary page actions:

| Dictate source | Existing behavior | Shared destination |
| --- | --- | --- |
| `DesignSystem/Components/AppControls.swift`, `AppActionButton` | Local 32-point action style, radius 9 | Published primary/secondary roles; retain destructive behavior until supported shared semantics are admitted |
| `Features/Onboarding/Components/OnboardingSections.swift`, `OnboardingBottomBar` | Local fixed 42-point companion and main actions | Published secondary/primary roles, keeping callbacks and disabled state |
| `Features/Modes/Components/ModeViewComponents.swift`, `VoiceInkButton` | Local rounded primary action | Published primary role, keeping callback and disabled state |

All paths above are relative to `VoiceInk/`. Icon-only, selected choice,
standalone content-row, removable tag and recorder controls must use the
corresponding tested shared role once available. Do not replace an icon role
with a text CTA, shrink a canonical target to fit an existing recorder, or copy
the candidate into this app. Native menu/alert controls retain system behavior;
content cards, waveforms and activity-cell geometry are classified separately.

This PR adds exact Common `0.30.4`, commit
`e47547a6e6c9e66588ffc14dea663f9e68c6bdd4`, to the app target only. The package
was published after its exact-head release check and A0 acceptance; the retained
publication receipt's SHA256 is
`1f0b65bb212abae0d06a22fa8a7b5877138b23fe256dfe40684b521ca75e4785`.
See [Common PR 130](https://github.com/ForITLLC/for-iCommon/pull/130) and
`adoption.json`. These existing page roles are distinct from the unreleased
controls candidate and do not deliver its navy-pair or new-role fixes.

The ordinary primary/secondary branches of `AppActionButton`, the onboarding
bottom bar and the Modes empty-state action now select these published styles.
They remove app-owned ordinary action geometry while preserving callbacks,
localized labels and enabled state. The existing destructive branch remains
explicitly pending: release `0.30.4` does not render `ButtonRole`, so replacing
it would lose its semantic visual treatment. Other specialized roles remain
listed in the baseline inventory; this PR does not claim their migration.

Five affected quick-panel footers now retain 48 points as a minimum rather than
forcing that height. Their material edge grows with its real content, and the
scaffold reserves the measured additional footer space above existing scroll
insets. The default geometry remains the minimum; wrapped actions can grow
without concealing the last content row. Native AX/long-label acceptance of
that layout remains pending in the device plan.

The actual macOS 15 deployment target fits the package's macOS 14 floor without
raising the app's floor or requiring a legacy bridge. The project requirement
is exact, and the prospective lock entry names the same immutable commit.
Existing unrelated requirements and lock entries are unchanged. The stale
requirements `originHash` is removed; this field is optional in SwiftPM's v3
[resolved-store schema](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageGraph/ResolvedPackagesStore.swift).
The lock entry is source preparation, not a claim that Xcode/SwiftPM resolved
the graph. Regenerate/validate the requirements hash and resolve the exact graph
under native admission before merge. Consumer compilation and rendering remain
separate pending evidence.

## Guard and release blockers

`forit-app.json`, the input manifests and first/every-build phases prepare BR-3
for both shipping targets. `forit/control-guard/verify_wiring.py` verifies the
checked-in project membership and phase/config consistency offline. That result
is preparation evidence, not a BR-3 source-policy pass.

The inspected Common adapter requires XcodeGen and rejects this filesystem-
synchronized PBX project. The app also has generated asset-symbol Swift and
linked SwiftPM modules. Their complete compile closure, XPC target recognition,
trusted tool provisioning, retained report directory and enabled script sandbox
must be supported and validated by the maintained adapter before admission.
Do not omit these sources, disable the sandbox, introduce a wrapper/waiver or
convert an unsupported adapter result into success.

## Native acceptance still required

`device-evidence-plan.json` names the actual Mac surfaces and pending screenshot,
AX geometry and interaction cases. No screenshot or native test was run for
this PR. Native admission must precede execution. Test real component placement,
light/dark, enlarged accessibility text, wrapping, disabled/pressed/selected
states, destructive confirmation and undo where implemented, keyboard focus,
pointer hover, target bounds and sibling spacing. An isolated view image does
not prove placement in the application. There are no real widget targets to
capture; do not substitute fabricated widget screenshots for the absent target.

The controls candidate's native validation/publication, complete supported BR-3
integration and the app's own admitted acceptance matrix remain merge/release
requirements. This preparation is not an app rollout or a conformance pass.
