# Dictate artwork

`dictate-glyph.svg` is the editable product master for both the Dock artwork
and the menu-bar glyph. Ben requested a different shape and colour from
Squelch on November 10, 2026 (Dispatch `ba-018a751f84d3`). Squelch stays unchanged.

The gold speech bubble and waveform replace the microphone silhouette. The
native menu image preserves its colours and adds the real engine-state marks;
it remains distinguishable by shape. The same SVG produces the embedded menu
PDF and the app icon. Edit the master and regenerate all derivatives together.

Run `scripts/render-dictate-artwork.py --output <new-directory>` on the existing
build server. It reads the exact published Health renderer and canonical Common
mark, verifies their hashes and reuses the shared optical placement, footer,
Mac mask/shadow and asset-slot generation. An existing local copy can be passed
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
