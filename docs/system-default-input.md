# Follow macOS Default input

Audio Settings → Microphone Mode → **Follow macOS Default** follows the Mac's
current input, including while recording. Selected Microphone and Priority Order
keep their existing routing preferences. The stored `System Default` value is
unchanged, so existing selections need no migration.

The existing default-input listener refreshes device availability and requests
changes through the serial recording hardware queue. A route change keeps the
same WAV and streaming callback. Session IDs and cancellation leases reject old
queued work; changes during setup or an in-flight switch resolve the latest
usable route afterward. The existing closed-lid/disconnection fallback applies.
A failed switch attempts to restore the previous input. If recovery also fails,
the normal engine stop/canceled-history path retains the captured audio.

## Verification

The Foundation-only session tests are in
`Tests/VoiceInkTests/RecordingDeviceSessionTests.swift`. They exercise the actual
`VoiceInk/Infrastructure/Audio/Devices/RecordingDeviceSession.swift` helper,
including setup deferral, coalescing, duplicates, cancellation, stale completions,
mode changes and failure retry suppression. They do not instantiate the app,
Core Audio, a microphone, UserDefaults or user files.

For a dependency-free test run, the existing admitted Mac executor can stage that
helper as the sole source of a temporary Swift package target named `VoiceInk`
and this test file in a test target depending on it, then run `swift test --jobs 1`.
Use the existing native owner's lifecycle/process controls. This is a test recipe,
not a new executor or permission to start a separate Mini job. The app's Xcode
project also includes the tests through its existing synchronized Tests group.

Neither Swift nor Xcode is available in the source-editing Linux environment.
An actual native test/build result must be recorded separately; source review,
catalog validation and whitespace checks do not establish microphone continuity.

## Native acceptance

- While idle in Follow mode, change macOS input and confirm the displayed name
  and next recording use that input.
- During one recording, change A → B and rapidly A → B → C. Confirm the final
  current input is C, one WAV contains the captured portions and the live
  transcription session continues. Duplicate events must not reopen the file.
- Change between devices with different sample rates and channel counts; confirm
  valid 16 kHz mono output, saved per-device channel selection and no stale audio
  buffers after reconfiguration. The hardware handoff can contain a short gap;
  this change does not promise seamless, zero-gap audio.
- Stop during setup or a queued switch, then start again. Old completions must
  not change, stop, delete or dismiss the new recording.
- Change modes during a pending switch. Verify custom selection and the priority
  list survive; subsequent system-default-only events do not switch those modes.
- Disconnect the default device and close/reopen the lid. Verify usable fallback
  and return to a usable system default; no-input/recovery failure must retain
  captured audio and show a truthful error instead of continuing silently.

API references: [default input property](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydefaultinputdevice)
and [Core Audio listener registration](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)).
