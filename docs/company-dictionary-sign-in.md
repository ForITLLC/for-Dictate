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
