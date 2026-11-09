# Dictate menu-bar microphone

Ben asked on November 9 for a better menu-bar icon, with clear light/dark
rendering and recording state. The previous build1843 showed a small permanent
microphone beside the generic brand mark; it did not change with recording.

The status item now uses one microphone-first NSImage template,24x18pt.
macOS owns its ink in light/dark and selected menus. Idle is an outlined mic.
Starting adds an open ring. Recording fills the mic and its recording dot.
Transcribing, enhancing and busy use the outlined mic with three progress dots.
Shape and an accessible state label convey status without relying on color.
The existing engine state is the sole input; constructing the icon starts no
recording, network request or timer. Menu behavior and lifecycle bridge remain.

The Dock icon remains the canonical shared Health-family microphone and ForIT
mark already adopted in forit/branding/dictate-icon-provenance.json. A large
app icon and a small monochrome status item have different native treatments
while retaining the same microphone identity. No app-specific brand copy or
new shared-control/system architecture is introduced.

Four native XCTest cases cover all six engine states, template metrics and
accessibility values, distinct shapes and actual AppKit light/dark specimens.
The native check runner writes status-icon-previews/status-light.png and
status-dark.png and retains their original bytes and hashes in
status-icon-previews.log through the existing collector. Specimens are explicitly labelled and
do not constitute screenshots of Ben's live Dock or menu bar. Final acceptance
requires the signed installed build and a separate live-device capture.
