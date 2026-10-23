"""Dependency and OS-baseline regressions for the distributable native kernels."""
import struct
import unittest

from check_portability import inspect_macho, inspect_pe


def pe_fixture(imports=("KERNEL32.dll",), delayed=()):
    data = bytearray(0x1400)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3c, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", data, 0x84, 0x8664, 1, 0, 0, 0, 240, 0x2022)
    optional = 0x98
    struct.pack_into("<H", data, optional, 0x20b)
    struct.pack_into("<Q", data, optional + 24, 0x140000000)
    struct.pack_into("<I", data, optional + 108, 16)
    struct.pack_into("<8sIIIIIIHHI", data, optional + 240, b".rdata\0\0", 0x1000, 0x1000, 0x1000, 0x400, 0, 0, 0, 0, 0x40000040)
    name_offset = 0x700
    for directory, offset, stride, names in ((1, 0x400, 20, imports), (13, 0x500, 32, delayed)):
        if not names:
            continue
        struct.pack_into("<II", data, optional + 112 + directory * 8, offset + 0xc00, (len(names) + 1) * stride)
        for index, name in enumerate(names):
            name_bytes = name.encode("ascii") + b"\0"
            data[name_offset:name_offset + len(name_bytes)] = name_bytes
            if directory == 1:
                struct.pack_into("<IIIII", data, offset + index * stride, 0, 0, 0, name_offset + 0xc00, 0)
            else:
                struct.pack_into("<8I", data, offset + index * stride, 1, name_offset + 0xc00, 0, 0, 0, 0, 0, 0)
            name_offset += len(name_bytes)
    return data


def macho_fixture(architecture="arm64", minimum=(13, 0, 0), dependency="/usr/lib/libc++.1.dylib", signed=True, extra=b""):
    name = dependency.encode("ascii") + b"\0"
    dylib_size = (24 + len(name) + 7) & ~7
    commands = [struct.pack("<6I", 0xc, dylib_size, 24, 0, 0, 0) + name + bytes(dylib_size - 24 - len(name))]
    version = minimum[0] << 16 | minimum[1] << 8 | minimum[2]
    commands.append(struct.pack("<6I", 0x32, 24, 1, version, 0, 0))
    if extra:
        commands.append(extra)
    if signed:
        end = 32 + sum(map(len, commands)) + 16
        commands.append(struct.pack("<4I", 0x1d, 16, end, 4))
    command_data = b"".join(commands)
    header = struct.pack("<IiiIIIII", 0xfeedfacf, 0x0100000c if architecture == "arm64" else 0x01000007,
                         0, 6, len(commands), len(command_data), 0, 0)
    return header + command_data + (b"sign" if signed else b"")


class PortabilityTests(unittest.TestCase):
    def test_windows_accepts_system_and_api_set_imports(self):
        report = inspect_pe(pe_fixture(("KERNEL32.dll", "api-ms-win-core-synch-l1-2-0.dll"), ("USER32.dll",)))
        self.assertEqual(report["dependencies"], ["api-ms-win-core-synch-l1-2-0.dll", "kernel32.dll", "user32.dll"])

    def test_windows_rejects_dynamic_cpp_runtime_in_both_import_tables(self):
        for data in (pe_fixture(("VCRUNTIME140.dll",)), pe_fixture(delayed=("MSVCP140.dll",))):
            with self.assertRaisesRegex(ValueError, "Non-system Windows dependency"):
                inspect_pe(data)

    def test_windows_rejects_wrong_architecture_and_invalid_import_bounds(self):
        data = pe_fixture()
        struct.pack_into("<H", data, 0x84, 0xaa64)
        with self.assertRaisesRegex(ValueError, "x86_64"):
            inspect_pe(data)
        data = pe_fixture()
        struct.pack_into("<I", data, 0x40c, 0x8000)
        with self.assertRaisesRegex(ValueError, "outside every section"):
            inspect_pe(data)
        data = pe_fixture()
        struct.pack_into("<I", data, 0x98 + 112 + 12, 20)
        with self.assertRaisesRegex(ValueError, "Unterminated"):
            inspect_pe(data)

    def test_macos_accepts_both_supported_baselines(self):
        for arch, minimum in (("arm64", (13, 0, 0)), ("x86_64", (11, 0, 0))):
            report = inspect_macho(macho_fixture(arch, minimum), "macos-" + arch)
            self.assertEqual(report["minimum_macos"], ".".join(map(str, minimum)))

    def test_macos_rejects_runner_os_minimum_and_wrong_architecture(self):
        with self.assertRaisesRegex(ValueError, "minimum exceeds"):
            inspect_macho(macho_fixture(minimum=(15, 0, 0)), "macos-arm64")
        with self.assertRaisesRegex(ValueError, "architecture"):
            inspect_macho(macho_fixture(), "macos-x86_64")

    def test_macos_rejects_external_dependency_rpath_and_unsigned_binary(self):
        for data, message in (
            (macho_fixture(dependency="/opt/homebrew/lib/libtest.dylib"), "Non-system"),
            (macho_fixture(extra=struct.pack("<4I", 0x8000001c, 16, 12, 0)), "search path"),
            (macho_fixture(signed=False), "missing a code signature"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                inspect_macho(data, "macos-arm64")

    def test_malformed_library_headers_fail_closed(self):
        for parser in (inspect_pe, lambda data: inspect_macho(data, "macos-arm64")):
            for data in (b"", b"\0" * 80, b"MZ" + bytes(100)):
                with self.subTest(parser=parser, size=len(data)), self.assertRaises(ValueError):
                    parser(data)


if __name__ == "__main__":
    unittest.main()
