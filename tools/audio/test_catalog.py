"""Build-gate fault injection: missing, stale and damaged assets must fail."""
import contextlib
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest

import bake_audio


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mcf-audio-assets-")
        self.source = bake_audio.AUDIO
        bake_audio.AUDIO = Path(self.temp.name) / "audio"
        shutil.copytree(self.source, bake_audio.AUDIO)
        self.catalog = json.loads((bake_audio.AUDIO / "catalog.json").read_text())

    def tearDown(self):
        bake_audio.AUDIO = self.source
        self.temp.cleanup()

    def test_complete_catalog(self):
        with contextlib.redirect_stdout(io.StringIO()):
            bake_audio.check(self.catalog)

    def test_missing_voice_fails(self):
        (bake_audio.AUDIO / "voice/mortar_warn.wav").unlink()
        with self.assertRaisesRegex(RuntimeError, "missing audio asset"):
            bake_audio.check(self.catalog)

    def test_changed_audio_fails(self):
        (bake_audio.AUDIO / "sfx/rifle_1.ogg").write_bytes(b"damaged")
        with self.assertRaisesRegex(RuntimeError, "changed without updating"):
            bake_audio.check(self.catalog)

    def test_missing_take_fails(self):
        (bake_audio.AUDIO / "sfx/explosion_2.ogg").unlink()
        with self.assertRaisesRegex(RuntimeError, "missing audio asset"):
            bake_audio.check(self.catalog)

    def test_stray_asset_fails(self):
        (bake_audio.AUDIO / "sfx/rifle_99.ogg").write_bytes((bake_audio.AUDIO / "sfx/rifle_1.ogg").read_bytes())
        with self.assertRaisesRegex(RuntimeError, "not in the catalog"):
            bake_audio.check(self.catalog)

    def test_stale_catalog_fails(self):
        with (bake_audio.AUDIO / "catalog.json").open("a") as out:
            out.write("\n")
        with self.assertRaisesRegex(RuntimeError, "catalog changed"):
            bake_audio.check(self.catalog)


if __name__ == "__main__":
    unittest.main()
