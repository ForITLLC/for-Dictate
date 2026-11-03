# Native offscreen image specimens

This app-owned adapter renders the native Dictate menu label and a branded
reference-identity fixture on a non-Ben macOS build host. It uses SwiftUI
`ImageRenderer`, the app's committed menu-label expression, and the same
published ForITCommon revision as release 1.0.0 (1843).

It creates no window, activates no application, captures no display, reads no
Dictate store/history or credentials, and changes no device settings. The
window-request bridge is omitted from the isolated label because it exists to
route product lifecycle requests, rather than draw the label.

## Executor contract

The for-dev executor owns host selection, registration, its existing shared
gate, and execution. This adapter never takes another gate slot. It requires a
macOS 14+ native build host with the existing Xcode/Swift toolchain and existing
access to the published dependency. No signing identity, Keychain provisioning,
app build number allocation, app installation, upload or personal-desktop
automation is required.

Plan only:

```sh
/bin/bash scripts/forit-offscreen-proof.sh
```

Execute only on the authorized macOS build executor:

```sh
/bin/bash scripts/forit-offscreen-proof.sh --execute
```

The source contract is a reviewed commit of this repository, including these
scripts and its existing `VoiceInk/App/VoiceInk.swift`. The adapter generates a
small Swift package using that committed native label, then compiles and runs
only its headless XCTest with `swift test` (not XCUITest). Its package depends on `ForITCommon` at revision
`352f567e839b8faf61b6df5840c5275b016addce`. It does not rebuild the product.

The renderer produces native light and dark specimens for two surfaces:

- The microphone mark: the actual source-derived label, at shipped glyph sizes,
  on a standalone native surface.
- The branded identity: a shared-mark fixture with supplied reference identity
  `ForIT Dictate 1.0.0 (1843)`, explicitly labelled as reference metadata.

Each image visibly states its fixture origin, render hostname and reference
identity. The receipt records renderer/release-source attribution, native
method, real host/OS/process, package resolution, image dimensions and hashes.

## Retained artifacts

Register these existing collector-compatible paths relative to repository root:

```json
[
  "build/offscreen-proof/receipt.json",
  "build/offscreen-proof/evidence.zip"
]
```

Each attempt uses its own `runs/<uuid>` directory. The archive retains original
PNGs, native metadata, source provenance, generated native source and package
inputs. Failed compilation/rendering is a failed
receipt, never a visual pass. A successful render is
`RENDERED_AWAITING_VISUAL_REVIEW`; inspect actual pixels before claiming that
glyphs, colour or clipping passed.

## Tinycast slice and proof boundaries

for-MacBook owns Tinycast's integration/source and native history renderer. Its
separate slice should retain a genuine native history image and receipt with
its real host/process, Tinycast runtime/source and consumer identities,
nonprivate fixture origin, actual rows/error, and image dimensions/hash. A
different host or process keeps its own attribution. The existing 887-row
diagnostic returns counts only and cannot supply an image.

An alternate-host fixture is not a screenshot of Ben's running app. These
images do not verify his installed build, menu-bar placement or visibility,
physical dictation, or the live Tinycast History window. Keep
`liveBenMacAppearanceProven` and `installedBuildVerifiedByThisRun` false.
Source/build delivery and Ben-device acceptance have separate evidence.
