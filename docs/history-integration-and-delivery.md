# Tinycast history and delivery checks

ForIT Dictate's existing Tinycast integration uses a local, read-only, versioned
JSON interface. It does not open an HTTP listener. The agreed producer/consumer
path is `~/Library/Application Support/io.forit.dictate/Integrations/Tinycast/history-v1.json`.
The app exports successful history at launch and after committed changes, using
atomic publication and an 8 MiB whole-record limit. Tinycast owns Search History,
Copy Last Dictation and Paste Last Dictation in `for-MacBook/macbook/tinycast/forit-dictate`.

Original and enhanced paste-last shortcuts also already exist in Dictate's
Settings. Their existing user assignments are preserved. No additional shortcut
or launcher integration is needed to provide the agreed behavior. Deploying the
producer app and the existing consumer, then checking them together, is still
required; published source does not establish installation or delivery.

## Repeated text investigation

The reported repeated phrase is not established as a transcription-history reuse
bug. A read-only MacBook check on November 1 found the installed/running app was
1.0.0 (1834), with Tinycast 0.12.1 (124) running. Bounded SQL diagnostics returned
counts only: no matches for the reported phrase, its distinctive suffix or its
distinctive token in raw text, enhanced text or saved request messages. The
observed rows identified Parakeet V3 and no cleanup model. No transcript contents,
clipboard contents or audio were returned or changed by the investigation.

Later that day, the MacBook owner's native audit found the reported phrase in
the latest completed Monologue history entry selected by Tinycast's old
Monologue Paste Last command. The owner removed only that command's shortcut,
reloaded Tinycast and independently verified that the shortcut remained absent,
preserving Monologue's data and other bindings. This demonstrates a stale-text
source when that shortcut is used; it does not establish that every reported
insertion used that path. The replacement consumer reads only Dictate's current
versioned feed, with no Monologue fallback. The removed binding must remain
absent while the replacement is qualified.

Two independent source defects were identified:

* Clipboard paste wrote the new dictation, waited 200 ms, then posted Paste
  without checking whether another process had replaced the clipboard. It now
  requires matching text, a request marker and the original change count before
  dispatch and after each keyboard-event suspension. A mismatch stops further
  events, releases any posted keys, warns the user, prevents automatic Send and
  does not overwrite the other process's clipboard during restoration. Direct
  typing remains independent of the clipboard.
* Whisper shared its loaded actor with prewarming, imports and retries, but
  configured, decoded and collected results in separate actor calls. Another
  request could intervene. Those operations now happen in one actor turn, with
  request-local resource ownership. This is a separate correctness fix; the
  observed Parakeet records do not implicate Whisper in the reported incident.

Cross-process clipboard mutation cannot be made atomic with another application's
handling of keyboard events. The ownership checks prevent the observed unchecked
delay; they do not prove that the destination accepted the expected text.

## Verification

Eleven XCTest cases exercise the actual Foundation-only clipboard coordinator
with synthetic clipboard snapshots, injected delays and recorded key events.
They cover replacement during the pre-paste delay, replacement between Command
and V, change-away-and-back, missing ownership, AppleScript dispatch, safe
restoration, key release and clipboard-independent direct typing. The maintained
integration checker includes them alongside the previous 52 tests and the 13
Foundation-only recording-device session tests, four menu-bar icon cases and
two vocabulary timing observation cases and eight company-dictionary DTO cases
(90 total). The recording-device tests cover
following macOS input changes, deferred switches and stale-session cancellation
without opening audio devices.

Swift compilation, these XCTest cases, physical clipboard/key-event behavior,
Whisper/Parakeet model execution and installed-app acceptance must run through
the existing native release owner. They were not run in the Linux source
workspace. Do not report the repeated-phrase incident resolved from source
inspection or synthetic tests alone.

Native acceptance uses synthetic A/B phrases, with no user history or audio:

1. Paste synthetic A, then B normally and with clipboard restoration enabled
   and disabled. Verify exactly the expected text and no extra Send.
2. Replace the clipboard during the pre-paste delay and between Command and V.
   Verify no unintended paste/Send, released modifiers, a warning and preserved
   foreign clipboard contents. If V was already posted, inspect the destination
   before retrying; no automatic retry is permitted.
3. Run sequential and overlapping Parakeet and Whisper requests with distinct
   synthetic audio. Include prewarming/import alongside live transcription;
   compare each result with its own request.
4. Verify the installed producer creates and updates the snapshot after a
   successful transcription, edit and deletion. Check Tinycast Search, Copy Last
   and Paste Last against the same synthetic record, preserving other commands
   and bindings. Confirm the old Monologue Paste Last binding remains absent and
   the consumer selects the current successful Dictate record rather than the
   old Monologue entry. Report any remaining repeated-text symptom separately;
   an absent binding alone does not prove complete incident acceptance.
5. Confirm the installed build and visible ForIT icon before calling branding
   delivered. A signed DMG or a source commit alone is insufficient.

The requested delivery combines this branding/history/paste work with the
[system-default microphone change](system-default-input.md) in one signed Mac
build. Its 13 Foundation session tests join the existing 63 checks. Physical
microphone switching, destination paste behavior and actual installation remain
separate native acceptance observations; source consistency is not their result.
