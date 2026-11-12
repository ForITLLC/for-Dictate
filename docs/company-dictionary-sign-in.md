# Company dictionary sign-in binding

Dictate uses the published ForITCommon browser sign-in and Support native-session contract. The optional Company Dictionary window is reachable from Dictionary or the shared profile menu. Opening the app restores its own saved Support session without opening a browser or changing the selected recognition engine.

| Build | Bundle and URL scheme | Exact callback for Auth enrollment |
| --- | --- | --- |
| Release | `io.forit.dictate` | `io.forit.dictate://oauth/callback` |
| Debug | `io.forit.dictate.dev` | `io.forit.dictate.dev://oauth/callback` |

`VoiceInk/Info.plist` expands `$(PRODUCT_BUNDLE_IDENTIFIER)` for its URL scheme so installed Debug builds do not claim the production callback. Auth owns enrollment of these exact callbacks on the existing shared public client. Registration must preserve all other apps' entries.

The app-owned coordinator retains the pinned Common `BrowserSignIn`, uses `SignInConfiguration.forIT(redirectURI:)` with the callback matching the app bundle, and routes owned callback URLs before the existing media-file handler. Cancelled callbacks are consumed too; unrelated media imports retain their existing handling. PKCE S256, state, nonce and scopes remain the shared implementation; no secret or offline access is added.

After a fresh sign-in, the client exchanges the ID token once at Support's `/api/app/v1/session`, then discards Microsoft tokens and retains only its own Support session. An uncertain exchange is not replayed. `/api/app/v1/me` establishes the staff identity, and a validated dictionary response establishes its company. Parsed JWT claims and ETags never stand in for verified account identity.

The private cache retains the complete response separately from personal and local vocabulary stores. Its envelope binds the server user, company, origin, schema, representation and session incarnation; its ETag is an opaque content validator. Credentials use this app's existing login-Keychain adapter, without claiming Data Protection or synchronisation guarantees that adapter does not implement.

A complete 200 response replaces the prior snapshot, including an empty result. A 304 needs the matching bound cache and validator. Authentication or access denial removes company hints; temporary failure can retain an unexpired same-session copy marked stale. Sign-out removes current in-process company publication before awaiting storage or server revocation. Storage failures are shown truthfully, including when durable sign-out cannot be confirmed.

Refresh runs outside recording: foreground/wake events and an in-process maintenance check, with throttling, backoff and Support's Retry-After. No host scheduler is introduced. Responses use a cookie-free ephemeral transport with no shared credentials or cache, fixed Support origin, rejected redirects and bounded decompressed bodies (16 MiB for dictionary GET; 24 MiB for the persisted envelope).

Company canonical spellings enter the bounded recognition projection after personal words and existing spelling choices, ahead of local catalog defaults. Rich aliases and meanings remain available in the company window. Whisper and optional AI cleanup consume the projection; the saved Parakeet V3 realtime path does not yet consume company vocabulary. Recognition benefit and performance on that path remain required work. This source checkpoint is not proof of a live company sign-in, installed company dictionary, or improved recognition.

Work: https://tasks.forit.io/?task=9A177608-8178-4CD2-9972-420533BF6D3C

## Snapshot decoder preparation

`CompanyDictionarySnapshot` decodes the complete Support schema-1 DTO separately
from the local recognition catalog. It retains inactive rows, aliases, meanings,
stable IDs and the complete quoted ETag. Validation follows Support source
`41601511ce16afa0a1f5b25c0aa84e20fea98a4c` (unchanged in inspected
`3438ba6d373fd3ab0fd75980bda437efefcd0a7d`): at most 1,000 rows, UTF-16
text limits and NFKC matching, SQL-int revisions and UTC millisecond timestamps.
It does not apply the local 160-byte recognition limit to server text.

Eight hermetic decoder cases join the native checks. They cover
complete and empty responses, field preservation, bounds, malformed input,
Unicode/alias validation and version/date handling. The decoder performs no
network or file access and provides no session, cache or refresh integration.
The decoder is separate from the bounded transport and persistence layer. Native
execution and authenticated adoption must be verified independently; source and
synthetic fixtures alone do not establish either installed behavior or better
recognition on a person's saved engine.
