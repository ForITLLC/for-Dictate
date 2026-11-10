# Dictate artwork

`dictate-glyph.svg` is the editable product master for both the Dock artwork
and the menu-bar glyph. Ben requested a different shape and colour from
Squelch on November 10, 2026 (Dispatch `ba-018a751f84d3`). Squelch stays unchanged.

Ben rejected the yellow/gold artwork and requested the ForIT logo on top, with
colour changing when engaged (`ba-ee58ec51afeb`, `ba-60ba975ab71f`). The master now
embeds the exact canonical ForIT mark above a small dictation waveform on the
shared navy background. The menu image is neutral white with a navy keyline at
rest and turns red only while the real engine state is recording. Starting and
processing retain their distinct state marks. The same SVG produces the menu
PDF and app icon; regenerate every derivative together.

Run `scripts/render-dictate-artwork.py --output <new-directory>` on the existing
build server. It reads the exact published Health renderer and canonical Common
mark, verifies their hashes and reuses shared optical placement, Mac mask/shadow
and asset-slot generation. Ben's explicit top-mark placement is inside the master;
the old footer is omitted to avoid a duplicate logo. An existing local copy can be passed
with `--health-recipe`; its exact hash is still required. The `FORIT_HEX` local
mark option also retains the shared byte/dimension checks. No shared recipe,
profile validator or ForIT mark is replaced.

Adopt the complete generated `AppIcon.appiconset`, `DictateGlyph.pdf`,
`DictateGlyphAsset.swift` and provenance together. The Swift payload embeds the
same PDF bytes so app and standalone native checks do not have different asset
lookup paths. This folder's provenance binds the master, shared inputs and all
derived bytes; preparation is distinct from native compilation and installation.

Dictate currently ships on macOS only. The app icon retains all ten Mac slots;
no unshipped platform is represented as tested. Native fixtures cover idle,
starting, recording and processing in light, dark and selected-menu backgrounds.
They are synthetic state specimens. Installed capture is a separate device check.
