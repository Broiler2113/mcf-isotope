"""Native registration must never advertise missing or foreign libraries."""
import re
import tempfile
import unittest
from pathlib import Path

from build import ROOT, stage_manifest


class ManifestTests(unittest.TestCase):
    def test_source_checkout_has_no_unconditional_extension(self):
        self.assertFalse((ROOT / "addons/mcf_policy/mcf_policy.gdextension").exists())

    def test_complete_platforms_only(self):
        platforms = {
            "linux-x86_64": ["mcf_policy.so", "libonnxruntime.so.1"],
            "windows-x86_64": ["mcf_policy.dll", "onnxruntime.dll", "msvcp140.dll",
                               "vcruntime140.dll", "vcruntime140_1.dll"],
            "macos-arm64": ["mcf_policy.dylib", "libonnxruntime.1.22.0.dylib"],
            "macos-x86_64": ["mcf_policy.dylib", "libonnxruntime.1.22.0.dylib"],
        }
        for target, files in platforms.items():
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp)
                for filename in files[:-1]:
                    (output / filename).touch()
                with self.assertRaisesRegex(RuntimeError, "Incomplete native policy build"):
                    stage_manifest(output, target)
                self.assertFalse((output / "mcf_policy.gdextension").exists())
                (output / files[-1]).touch()
                manifest = stage_manifest(output, target).read_text()
                selectors = re.findall(r"^(linux|windows|macos)\.(\w+) =", manifest, re.M)
                self.assertEqual(selectors, [tuple(target.split("-"))] * 2)
                self.assertNotIn("bin/", manifest)
                for filename in files:
                    self.assertIn('"' + filename + '"', manifest)


if __name__ == "__main__":
    unittest.main()
