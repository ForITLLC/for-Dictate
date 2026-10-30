# Dictate Apple release adapter

This is source preparation for Ben's October 29 ban on GitHub Actions for Apple
builds. The shared launcher is owned by for-dev. Publication of this adapter is
not native build, signing, notarization, installation or migration-completion proof.
The existing branding/Tinycast/vocabulary source and native review holds remain.

## Entry point

The app-owned command is:

```sh
/bin/bash scripts/forit-mini-release.sh BUILD
```

`BUILD` is a required positive integer. `BUILD --plan` reads source metadata and
prints a plan without native commands, network requests, credential probes or
file writes. `BUILD --check-only` runs the 52 synthetic Swift checks through the
same inherited native job. `--upload` is rejected: Dictate's established channel
is a Developer ID signed, notarized DMG, not TestFlight or an App Store upload.

For-dev's proposed manifest entry uses repository `for-Dictate-build`, cwd `.`,
platform `macos`, command `["/bin/bash", "scripts/forit-mini-release.sh", "{build}"]`.
The public fork and private build mirror must contain the identical source SHA.
Set `upload_args` to `["--upload"]` so a caller's `--upload` reaches the adapter's
explicit rejection; omitting that array would silently ignore the request.

The shared public API, planning by default, is:

```sh
python3 infra/apple-builds/mini-build.py \
  --app for-Dictate --commit FULL_MERGED_SHA --platform macos --build BUILD
```

Do not add `--execute` during source preparation. Execution waits for the reviewed
common publication and current installed host capacity. The retired A0 process
is not required. Do not dispatch an Actions job, make another queue or lane, add
a wake, change credentials or host settings, or create a replacement scheduler.

## Existing host and identity contract

The outer launcher acquires `/Users/Shared/ci-runner/ci-runner-job-slot.sh`, begins
`/Users/Shared/forit-gate/mini-gate.sh`, and supplies `FORIT_GATE_RUN`. Its run must
have the installed `lane` marker. The app joins that run and does not begin/end
another one. `~/bin/xcodebuild` remains the installed slot-aware compiler wrapper.
The outer job owns final process-group cleanup, Common end, artifact copy and
source cleanup. The app and its Swift test child keep the inherited process group.
On timeout the app fails, retains compiler inputs under its output, and leaves
verified owned-process cleanup to that outer owner; it never signals guessed PIDs.

The adapter supplies the established Developer ID identity name, team
`UUSSWWML2A`, notary key ID `78ND83SSBB`, issuer
`b21bbf92-e667-43f9-b358-29908a814489` and existing local key path
`~/AppleCerts/AuthKey_78ND83SSBB.p8`. Values can be supplied by the approved host
environment; key contents never appear in source or receipts.

`FORIT_CODESIGN_KEYCHAIN` **must be supplied as the approved existing keychain
path**. Its installed path and availability have not been verified by this
source-only task. The core reads `security find-identity` and fails if that
identity is unavailable. It never creates, imports, unlocks or deletes a keychain,
changes a search list/partition list/ACL, copies keys, or stores a notary profile.
Missing signing material is an execution blocker, not authority to provision it.

## Build numbers and exact source

The outer launcher fetches a depth-one checkout, so commit count is not a build
number. The explicit argument becomes `FORIT_BUILD_NUMBER`, Xcode's
`CURRENT_PROJECT_VERSION`, the DMG name and the receipt. The built app's actual
`CFBundleVersion`, bundle identifier and version must match before signing.
No Actions run number or shallow-history count is used.

Dictate has no established App Store upload in this channel. Before a future
release the owner must read the existing signed release/installed app receipts
and choose a greater build number; old receipts are not a fresh allocation.
The last delivered DMG was 1.0.0 (1841), while the last separately observed
MacBook installation was 1834. Neither establishes a newly reserved number.
If the channel changes, actual Apple build records must be read before assigning
an App Store build, and upload/status verification needs its own accepted adapter.

The core requires a clean checkout including untracked source, checks the exact
staged HEAD, and retains the public-commit HTTP check formerly in the workflow.
This public-source API read does not schedule builds through GitHub Actions.

## Required checks and retained evidence

The release keeps this sequence: exact 52 synthetic tests and a genuine producer
fixture; pinned Whisper framework build; SDK package resolution and genuine
`Package.resolved`; frozen package versions during the app build; zero compiler
exit plus build-success marker; actual app bundle/version/build and no upstream
Sparkle feed; deepest-first nested signing followed by hardened-runtime app
signing; strict signature/team and entitlements; app notarization Accepted,
stapling/validation and Gatekeeper assessment; signed DMG with the same independent
notarization/stapling/assessment; final DMG SHA-256 and public source attribution.
The Common pin remains 0.31.9 at `352f567e839b8faf61b6df5840c5275b016addce`.

The core's exit trap emits `build/forit-release/release-evidence.log`: a structured
receipt containing the selected raw test, fixture, genuine resolver, actual
bundle, signing, entitlements, Apple notary and assessment records with hashes.
This file uses `.log` because the common launcher's current collector only keeps
`.log`, `.dmg`, `.sha256`, `.ipa` and `.pkg`. The DMG, checksum, compiler/test,
toolchain and stapler logs are also retained separately. No credential files are
in the collector's allowlist. A missing required record makes a nominally
successful core fail; partial failure records never claim a shipped release.

Later acceptance requires the common receipt's exact app/commit/platform/build/
upload/job tuple, successful adapter, verified process and gate cleanup, complete
artifact copy and source cleanup, followed by app-owner verification of the DMG
hash, actual bundle build and both Apple Accepted receipts. An exit code alone
is not migration proof. Do not retry an unknown notarization/job without reading
its existing submission and cleanup state.

## Remaining migration work

The prepared branch removes its sole Apple workflow and rejects
`GITHUB_ACTIONS=true` in both release entry points. The default branches' workflow
state and queued jobs still require readback at adoption; source deletion alone
does not retire historical dispatch paths. Do not alter runner credentials.

The actual existing Orca automation's worktree and conversation-reuse setting
must be read back before completion. No automation is created or modified here.
The preparation readback found the old finite first-dictation probe disabled on
the Dictate lane with conversation reuse enabled. The only active Dictate-repo
automation was worktree maintenance on the main checkout, with reuse disabled.
Neither is a verified active release automation. Both were left unchanged;
do not repurpose or reactivate them as a build wake without separate authority.
The common source publication, exact merged commit, native proof, actual Apple
receipts, old workflow retirement and automation readback are all separate required
evidence. Until then this is prepared source, with execution pending.
