# ForIT Dictate for iPhone: signing and TestFlight

The iPhone and iPad app is `ios/` in this repository. The Mac app is `VoiceInk.xcodeproj` at the root, signed with
Developer ID and shipped outside the App Store; nothing here touches it.

## Identity

| Bundle | Bundle id | App Store profile | In the IPA |
| --- | --- | --- | --- |
| The app | `io.forit.dictate` | ForIT Dictate App Store | `Payload/ForIT Dictate.app` |
| The keyboard | `io.forit.dictate.keyboard` | ForIT Dictate Keyboard App Store | `ForIT Dictate.app/PlugIns/ForITDictateKeyboard.appex` |

- Team `UUSSWWML2A`. Each target's Release configuration in `project.yml` is manual, "Apple Distribution", and names
  its own profile.
- Both bundles carry `com.apple.security.application-groups` [`group.io.forit.dictate`]. The keyboard asks there,
  the app listens and leaves the text there, and the keyboard types it.
- The keyboard asks for Full Access (`RequestsOpenAccess`): without it iOS keeps a keyboard out of its app group.
- The app has the `audio` background mode, so the microphone stays ready between dictations.
- Export compliance: the app's Info.plist carries `ITSAppUsesNonExemptEncryption` (false). The verify step fails
  without it, because TestFlight would otherwise hold every build at "Missing Compliance".
- The Mac app has the same bundle id, `io.forit.dictate`. It is not in App Store Connect, so the record below is the
  iPhone app's alone.

## One-time steps in Apple's pages

Nothing headless can do these, so the scripts never try.

1. **The app group.** Developer portal, Certificates, Identifiers & Profiles, Identifiers: register the App Group
   `group.io.forit.dictate`, then assign it to `io.forit.dictate` and `io.forit.dictate.keyboard` (each App ID,
   App Groups, Configure). The App Store Connect API can turn APP_GROUPS on, but it cannot assign a group to an App
   ID. Assigning it changes the App IDs and Apple marks earlier profiles invalid; the next run mints them again.
2. **The App Store Connect record.** Apps, +, New App: iOS, name "ForIT Dictate", English (U.S.), bundle id
   `io.forit.dictate`, SKU `io.forit.dictate`. The API refuses `POST /v1/apps` (403), and an upload without the
   record fails with "Error Downloading App Information". `asc_resolve.py --require` says so before the upload.

The bundle ids themselves need no step: `asc_provision.py --register-as` registers each one the first time.

## Where the signing material lives

On the Mini only, never in the repository:

| What | Where on the Mini |
| --- | --- |
| Apple Distribution certificate (DER) | `~/AppleCerts/distribution.der` |
| its private key (PEM) | `~/AppleCerts/distribution.key` |
| App Store Connect API key 78ND83SSBB (.p8) | `~/.appstoreconnect/private_keys/AuthKey_78ND83SSBB.p8` |

## Running it

for-dev owns the fleet's `apps.json` entry and runs the job; this lane does not edit that registry. Two routes, both
from the repository root of `for-Dictate-build`:

| Route | Command | What it does |
| --- | --- | --- |
| `ios-compile` | `ios/Scripts/check-native.sh --execute` | The logic tests and an unsigned device compile. No build number, no signing. |
| `ios` | `ios/Scripts/apple-release.sh ios BUILD [--upload]` | Checks, profiles, a signed archive, the exported IPA verified, and with `--upload` TestFlight. |

`apple-release.sh` refuses a checkout that is not the clean commit in `FORIT_SOURCE_COMMIT`, then runs
`mini-testflight.sh`. Its steps, each with a log in `ios/build/testflight-<n>/`: `gate` (uploads only),
`tests-scripts`, `xcodegen`, `resolve`, `tests-logic`, `build-simulator`, `profile-app`, `profile-keyboard`,
`keychain`, `archive`, `export`, `verify`, and with `--upload` `asc`, `upload`, `testers`, `processing`.

- `gate` is for-iCommon's conformance gate on the commit and on the pull request that carries it. What this cut
  does not do yet is declared as `waivers` in `forit-app.json`, each with its reason, and shows as WAIVED.
- `verify` unpacks the IPA and checks, for both bundles, the bundle id, the build number, the version, the device
  family, the embedded profile (the one just made), a distribution signature and the app group; for the app also
  the microphone reason, export compliance and the four iPad orientations; for the keyboard that it is a keyboard
  and asks for Full Access.
- TestFlight is internal testing only: the "ForIT internal" group and `TESTER_EMAILS`. No external group, no
  public link, no Beta App Review and no App Store submission: those are Ben's decisions.

The build number must be higher than every build already uploaded for the version in `project.yml`.
