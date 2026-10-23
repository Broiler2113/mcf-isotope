"""A source checkout must never register a missing native library."""
import re
import tempfile
import unittest
from pathlib import Path
from build import ROOT, LIBRARIES, stage_manifest


class ManifestTests(unittest.TestCase):
    def test_source_checkout(self):
        self.assertFalse((ROOT / "addons/mcf_visuals/mcf_visuals.gdextension").exists())

    def test_only_complete_platform_is_registered(self):
        for target in ["linux-x86_64", "linux-arm64", "windows-x86_64", "macos-arm64", "macos-x86_64"]:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp)
                with self.assertRaises(RuntimeError): stage_manifest(output, target)
                self.assertFalse((output / "mcf_visuals.gdextension").exists())
                system, arch = target.split("-", 1)
                (output / LIBRARIES[system]).touch()
                text = stage_manifest(output, target).read_text()
                self.assertEqual(re.findall(r"^(linux|windows|macos)\.(\w+) =", text, re.M), [(system, arch)])
                self.assertIn('"' + LIBRARIES[system] + '"', text)


if __name__ == "__main__": unittest.main()
