# Dictate Mac TestFlight source proposal

Task [213C5FB4](https://tasks.forit.io/?task=213C5FB4-FA07-4A5D-8211-77CEF2CF1B9E), requested by iCommon MAIN in `msg_2761ed577734`.
Base: shipped source `37848667ed2db61381a6fbdcb5d31c13e62eaae1`, Common 0.31.9 / `352f567e839b8faf61b6df5840c5275b016addce`.

This is a source proposal and read-only assessment. It installs no workflow and
does not build, sign, provision, upload, change permissions or create a worker.
The existing `.github/workflows/forit-release.yml`, release script, application
source, entitlements and project are unchanged. Verified DMG 1841 and its branch
remain available. This proposal is not a release hold or a BR3/VS1 gate.

## Concrete compatibility result

The app's current `com.apple.security.app-sandbox` entitlement is false. Both
Refine XPC configurations explicitly set `ENABLE_APP_SANDBOX = NO`. Essential
cross-app behavior uses Accessibility: selected text retrieval, permission
checks, focused-element access and HID event posting for dictation/paste.
`ASSESSMENT.json` records exact source locations and metadata hashes.

[Apple's App Sandbox documentation](https://developer.apple.com/documentation/security/app-sandbox)
requires sandboxing for Mac App Store distribution. Apple Developer Technical
Support states that [Accessibility APIs are unsupported in sandboxed apps](https://developer.apple.com/forums/thread/794253).
Consequently a sandboxed App Store-style distribution design cannot be treated
as an uploader-only change that preserves today's behavior. This is a source
compatibility finding, not an observed Apple rejection or proof that every
possible TestFlight product design is impossible. No sandbox flag was flipped.
The existing automation, screen capture, model storage/download, file selection
and XPC boundaries also need review against any proposed sandboxed variant.

[Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
states that TestFlight always requires a provisioning profile. It belongs at
`App.app/Contents/embedded.provisionprofile` on macOS. The profile must match the
bundle/team/entitlement claims. Developer ID notarization is a different channel;
its success does not establish App Store signing or TestFlight provisioning.
Use Apple's [certificate definitions](https://developer.apple.com/help/account/create-certificates/certificates-overview)
to select approved App Store application/package signing identities, rather
than reusing the Developer ID identity by assumption.

## Integration through the maintained private build route

`pipeline.json` is an **inactive, non-executable integration specification**.
After the external prerequisites and compatible product source exist, add an
explicit manual TestFlight channel to the existing private `forit-release.yml`.
Its absent/default channel must continue the unchanged Developer ID DMG job.
Do not replace the DMG job, create a second release controller, or start both
channels for the same product without checking existing in-flight work.

The proposed job preserves public-source verification, real SDK resolution,
compile/test/sign/archive/export checks, package verification and retained
receipts. Archive/export/upload commands in the specification are templates,
not instructions or tested commands to run now. Target-specific signing and
configuration are unresolved inputs; no fake scheme/profile/app ID is supplied.
BR3/VS1 remain advisory. There is no A0/GO/Core-END/recipe prerequisite.
There is deliberately no `-allowProvisioningUpdates`, device registration,
certificate/profile creation, app creation, permission grant or tester/group
creation in the plan. Those are separate security changes if needed.

An upload receipt, processing `VALID`, and existing internal-group availability
must be recorded separately. No success is synthesized from process exit zero.
Use existing approved App Store API access only after its actual app scope and
roles are verified. The prior scoped GET at 03:34Z returned HTTP 200 and zero
visible matches for `io.forit.dictate`; it did not establish global app absence.

## Named owners and exact prerequisites

| Item | Owner | Current state |
|---|---|---|
| Dictate source, compatibility assessment and proposed CI integration | for-Dictate lane, `term_83365ef6-5628-49de-9db1-aa40e6c25de2` | This proposal is reviewable; no live qualification |
| Product choice for preserving global dictation/selection/paste behavior in an App Store-style variant | Ben Thomas, with Dictate implementing the selected design | No compatible alternative has been established |
| Approval of any actual security change | Ben Thomas through a decided for-Decisions card | This follow-up is not such approval; no change performed |
| Apple Account Holder/Admin operating app access, approved certificates and profiles for team `UUSSWWML2A` | **Not independently identified**; Ben must name the authorized operator | Exact external ownership/access prerequisite; no person or role is invented |
| ASC app ID, existing internal group and upload-capable approved identity | Named Apple operator above, then Dictate integration | Not verified for this product |

Before live work: settle the compatible product design; name the Apple operator;
identify an accessible ASC app and approved distribution profiles/certificates;
record any Ben-decided security-change card before those changes run. Then review
the actual target configuration, entitlement/profile coverage and job wiring.
This source proposal does not request new credentials or perform any change.

## Reproduce the offline source assessment

```sh
python3 -B scripts/forit-testflight-assess.py
python3 -B -m unittest discover -s Tests/TestFlightProposal -v
```

The assessment reads source metadata only and prints JSON. It has no network or
subprocess path and never grants execution clearance. The five regression tests
cover the cross-app behavior issue even after a sandbox toggle, independent HID
posting, no metadata-only clearance, malformed input and external-source symlinks.

The committed 28-pin lock is the actual canonical SDK output from this same
product's successful run `40263083260`, retained in artifact `12625099583`.
Its SHA256 is `95ecbe839244ef237df31a2f5395d865e850190c063051230b0283d888c75fb9`.
All previous 27 pins are unchanged; only the genuine Common pin was added. This
is retained resolver provenance, not a claim that this proposal ran the SDK.
