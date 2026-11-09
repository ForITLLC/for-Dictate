# Company dictionary sign-in binding

Dictate adopts the existing ForITCommon browser sign-in and Support native-session contract. This declaration prepares its own callback registration; it does not enable sign-in or company dictionary synchronization yet.

| Build | Bundle and URL scheme | Exact callback for Auth enrollment |
| --- | --- | --- |
| Release | `io.forit.dictate` | `io.forit.dictate://oauth/callback` |
| Debug | `io.forit.dictate.dev` | `io.forit.dictate.dev://oauth/callback` |

`VoiceInk/Info.plist` expands `$(PRODUCT_BUNDLE_IDENTIFIER)` for its URL scheme so installed Debug builds do not claim the production callback. Auth owns enrollment of these exact callbacks on the existing shared public client. Registration must preserve all other apps' entries.

The future app-owned coordinator must retain the pinned Common `BrowserSignIn`, use `SignInConfiguration.forIT(redirectURI:)` with the callback matching the app bundle, and route callback URLs to `BrowserSignIn.handle(_:)` before the existing media-file handler. One callback consumer preserves file imports. PKCE S256, state, nonce and scopes remain the shared implementation; no secret or offline access is added.

After a fresh sign-in, exchange the ID token once at Support's `/api/app/v1/session`, then discard Microsoft tokens and retain only the app-owned Support session. An uncertain exchange must not automatically replay the same token. Dictionary identity and company binding, snapshot validation, storage failure handling and sign-out remain required integration work. Parsed JWT claims and ETags cannot stand in for verified account identity.

No sign-in UI, callback handling, session acquisition, credentials or installed app changes are introduced by this preparation. It stays separate from the signed 1844 microphone-icon release.

Work: https://tasks.forit.io/?task=9A177608-8178-4CD2-9972-420533BF6D3C

## Snapshot decoder preparation

`CompanyDictionarySnapshot` decodes the complete Support schema-1 DTO separately
from the local recognition catalog. It retains inactive rows, aliases, meanings,
stable IDs and the complete quoted ETag. Validation follows Support source
`41601511ce16afa0a1f5b25c0aa84e20fea98a4c` (unchanged in inspected
`3438ba6d373fd3ab0fd75980bda437efefcd0a7d`): at most 1,000 rows, UTF-16
text limits and NFKC matching, SQL-int revisions and UTC millisecond timestamps.
It does not apply the local 160-byte recognition limit to server text.

Eight hermetic cases join the existing 82 native checks (90 total). They cover
complete and empty responses, field preservation, bounds, malformed input,
Unicode/alias validation and version/date handling. The decoder performs no
network or file access and provides no session, cache or refresh integration.
No response-byte ceiling is invented here; bounded transport remains future
consumer work under the producer contract. Source preparation does not establish
server deployment, native execution or authenticated dictionary adoption.
