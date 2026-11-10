"""Prevent independently stale Dock, menu and master artwork from shipping."""
import base64
import hashlib
import json
from pathlib import Path
import re
import struct
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


class ArtworkContractTests(unittest.TestCase):
    def test_dock_and_embedded_menu_bytes_match_the_same_recorded_master(self):
        branding = ROOT / "forit/branding"
        receipt = json.loads((branding / "dictate-icon-provenance.json").read_text())
        master = (branding / "dictate-glyph.svg").read_bytes()
        self.assertEqual(hashlib.sha256(master).hexdigest(), receipt["productMaster"]["sha256"])
        paths = {name: ROOT / "VoiceInk/Assets.xcassets" / name for name in receipt["files"]
                 if name.startswith("AppIcon.appiconset/")}
        paths["DictateGlyph.pdf"] = branding / "dictate-glyph.pdf"
        paths["DictateGlyphAsset.swift"] = ROOT / "VoiceInk/App/MenuBar/DictateGlyphAsset.swift"
        for name, path in paths.items():
            with self.subTest(artifact=name):
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), receipt["files"][name]["sha256"])
        source = paths["DictateGlyphAsset.swift"].read_text()
        payload = re.search(r'pdfData = Data\(base64Encoded: "([A-Za-z0-9+/=]+)"', source)
        self.assertIsNotNone(payload)
        self.assertEqual(base64.b64decode(payload.group(1), validate=True), paths["DictateGlyph.pdf"].read_bytes())
        palette = ET.fromstring(master).attrib
        self.assertIn("0x" + palette["data-accent"][1:], source)
        self.assertIn("0x" + palette["data-ink"][1:], source)

    def test_every_mac_asset_slot_has_the_declared_pixel_dimensions(self):
        folder = ROOT / "VoiceInk/Assets.xcassets/AppIcon.appiconset"
        slots = json.loads((folder / "Contents.json").read_text())["images"]
        self.assertEqual(len(slots), 10)
        self.assertEqual({row["idiom"] for row in slots}, {"mac"})
        for row in slots:
            with self.subTest(slot=row):
                data = (folder / row["filename"]).read_bytes()
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                size = int(row["size"].split("x")[0]) * int(row["scale"][0])
                self.assertEqual(struct.unpack(">II", data[16:24]), (size, size))


if __name__ == "__main__":
    unittest.main()
