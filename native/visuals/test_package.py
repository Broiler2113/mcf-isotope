"""Native bundles must match their source, contain every desktop target, and reject unsafe ZIPs."""
from pathlib import Path
import json
import stat
import tempfile
import unittest
import warnings
import zipfile

from package import (ROOT, TARGETS, FIXED_SOURCES, EXTENSION, LICENSE, STAMP, assemble,
                     create_package, digest, library_name, read_package, record_build,
                     source_identity, verify_bundle)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in FIXED_SOURCES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / name).read_bytes().replace(b"\r\n", b"\n"))
        self.source = self.root / "native/visuals/src/test.cpp"
        self.source.parent.mkdir(parents=True, exist_ok=True)
        self.source.write_bytes(b"// Native fixture\nint example() { return 1; }\n")
        self.cpp_commit = json.loads((self.root / "native/policy/dependencies.json").read_text())["godot_cpp_commit"]
        self.archives = []
        self.outputs = {}
        for target in TARGETS:
            output = self.root / "build" / target
            (output / "licenses").mkdir(parents=True)
            (output / library_name(target)).write_bytes(b"native test fixture: " + target.encode())
            (output / LICENSE).write_bytes(b"godot-cpp license fixture\n")
            (output / EXTENSION).write_bytes(("[configuration]\nentry_symbol = \"mcf_visuals_init\"\n"
                "reloadable = false\n[libraries]\n" + target.replace("-", ".") + ' = "' + library_name(target) + '"\n').encode())
            record_build(output, target, self.cpp_commit, self.root, "1" * 40)
            archive = self.root / ("mcf-kernels-" + target + ".zip")
            create_package(target, output, archive, "4.7.stable.test", self.root)
            self.archives.append(archive)
            self.outputs[target] = output
        self.bundle = self.root / "prebuilt"

    def test_complete_bundle_has_verified_platform_payloads(self):
        assemble(self.archives, self.bundle, self.root)
        manifest = verify_bundle(self.bundle, self.root)
        self.assertEqual(set(manifest["platforms"]), set(TARGETS))
        self.assertTrue((self.bundle / ".gdignore").is_file())
        for target, entry in manifest["platforms"].items():
            self.assertEqual(entry["sha256"], digest((self.bundle / entry["library"]).read_bytes()))
            self.assertEqual(entry["extension_sha256"], digest((self.bundle / entry["extension"]).read_bytes()))
            self.assertEqual(entry["library_size"], (self.bundle / entry["library"]).stat().st_size)

    def test_packaging_is_deterministic(self):
        another = self.root / "another.zip"
        create_package(TARGETS[0], self.outputs[TARGETS[0]], another, "4.7.stable.test", self.root)
        self.assertEqual(another.read_bytes(), self.archives[0].read_bytes())

    def test_source_zip_builds_do_not_require_project_git_metadata(self):
        target = TARGETS[0]
        stamp = record_build(self.outputs[target], target, self.cpp_commit, self.root)
        self.assertIsNone(stamp["source_commit"])
        self.assertEqual(stamp["source_fingerprint"], source_identity(self.root)[1])
        with self.assertRaisesRegex(ValueError, "source commit"):
            create_package(target, self.outputs[target], self.root / "unversioned.zip", "4.7.stable.test", self.root)

    def test_source_fingerprints_accept_crlf_but_not_code_changes(self):
        original = source_identity(self.root)
        for name in original[0]:
            path = self.root / name
            path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(original, source_identity(self.root))
        assemble(self.archives, self.bundle, self.root)
        self.source.write_bytes(self.source.read_bytes() + b"int changed = 2;\n")
        with self.assertRaisesRegex(ValueError, "current kernel sources"):
            verify_bundle(self.bundle, self.root)

    def test_packager_rejects_a_binary_changed_after_build(self):
        output = self.outputs[TARGETS[0]]
        (output / library_name(TARGETS[0])).write_bytes(b"changed after the tested build")
        with self.assertRaisesRegex(ValueError, "hash or size"):
            create_package(TARGETS[0], output, self.root / "bad.zip", "4.7.stable.test", self.root)

    def test_incomplete_or_duplicate_packages_leave_existing_bundle_intact(self):
        assemble(self.archives, self.bundle, self.root)
        before = (self.bundle / "manifest.json").read_bytes()
        for packages in [self.archives[:-1], self.archives + [self.archives[0]]]:
            with self.assertRaises(ValueError): assemble(packages, self.bundle, self.root)
            self.assertEqual(before, (self.bundle / "manifest.json").read_bytes())
            verify_bundle(self.bundle, self.root)

    def test_mixed_commits_are_not_assembled(self):
        target = TARGETS[0]
        record_build(self.outputs[target], target, self.cpp_commit, self.root, "2" * 40)
        create_package(target, self.outputs[target], self.archives[0], "4.7.stable.test", self.root)
        with self.assertRaisesRegex(ValueError, "same source commit"):
            assemble(self.archives, self.bundle, self.root)
        self.assertFalse(self.bundle.exists())

    def test_tampered_bundled_library_or_index_is_rejected(self):
        assemble(self.archives, self.bundle, self.root)
        library = self.bundle / TARGETS[0] / library_name(TARGETS[0])
        original = library.read_bytes()
        library.write_bytes(original + b"x")
        with self.assertRaises(ValueError): verify_bundle(self.bundle, self.root)
        library.write_bytes(original)
        index_path = self.bundle / "manifest.json"
        index = json.loads(index_path.read_text())
        index["platforms"][TARGETS[0]]["extension"] = "../outside.gdextension"
        index_path.write_text(json.dumps(index))
        with self.assertRaises(ValueError): verify_bundle(self.bundle, self.root)

    def test_archives_cannot_write_traversal_or_unexpected_paths(self):
        for name in ["../escape", "/absolute", "licenses/../../escape", "licenses\\escape", "extra.dll"]:
            with self.subTest(name=name):
                archive = self.root / "unsafe.zip"
                archive.write_bytes(self.archives[0].read_bytes())
                with zipfile.ZipFile(archive, "a") as zipped: zipped.writestr(name, b"bad")
                with self.assertRaisesRegex(ValueError, "unexpected path"):
                    read_package(archive, self.root)
        self.assertFalse((self.root.parent / "escape").exists())

    def test_duplicate_members_and_symlinks_are_rejected(self):
        duplicate = self.root / "duplicate.zip"
        duplicate.write_bytes(self.archives[0].read_bytes())
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(duplicate, "a") as zipped: zipped.writestr("provenance.json", b"{}")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            read_package(duplicate, self.root)
        linked = self.root / "linked.zip"
        with zipfile.ZipFile(self.archives[0]) as source, zipfile.ZipFile(linked, "w") as target:
            for member in source.infolist():
                if member.filename == library_name(TARGETS[0]):
                    member.external_attr = (stat.S_IFLNK | 0o777) << 16
                target.writestr(member, source.read(member.filename))
        with self.assertRaisesRegex(ValueError, "non-file"):
            read_package(linked, self.root)

    def test_binding_pin_and_payload_set_are_required(self):
        target = TARGETS[0]
        stamp_path = self.outputs[target] / STAMP
        stamp = json.loads(stamp_path.read_text())
        stamp["godot_cpp_commit"] = "0" * 40
        stamp_path.write_text(json.dumps(stamp))
        with self.assertRaisesRegex(ValueError, "bindings"):
            create_package(target, self.outputs[target], self.root / "wrong-pin.zip", "4.7.stable.test", self.root)


if __name__ == "__main__":
    unittest.main()
