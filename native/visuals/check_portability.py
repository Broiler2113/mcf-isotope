#!/usr/bin/env python3
"""Reject native release libraries with unsupported OS or external runtime dependencies."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ("windows-x86_64", "macos-x86_64", "macos-arm64")
LIBRARIES = {"windows": "mcf_visuals.dll", "macos": "mcf_visuals.dylib"}
WINDOWS_SYSTEM = {"kernel32.dll", "advapi32.dll", "bcrypt.dll", "crypt32.dll", "ntdll.dll",
                  "ole32.dll", "oleaut32.dll", "shell32.dll", "shlwapi.dll", "user32.dll",
                  "version.dll", "ws2_32.dll", "winmm.dll", "secur32.dll", "rpcrt4.dll",
                  "ucrtbase.dll", "msvcrt.dll", "gdi32.dll"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unpack(data, offset, fmt):
    require(0 <= offset <= len(data) - struct.calcsize(fmt), "Truncated native library metadata")
    return struct.unpack_from(fmt, data, offset)


def cstring(data, offset, end):
    require(0 <= offset < end <= len(data), "Invalid native library string offset")
    stop = data.find(b"\0", offset, end)
    require(stop >= 0, "Unterminated native library string")
    try:
        return data[offset:stop].decode("ascii")
    except UnicodeDecodeError as error:
        raise ValueError("Non-ASCII native dependency name") from error


def inspect_pe(data):
    require(data[:2] == b"MZ", "Expected a PE library")
    pe, = unpack(data, 0x3c, "<I")
    require(data[pe:pe + 4] == b"PE\0\0", "Invalid PE signature")
    machine, count, _, _, _, optional_size, _ = unpack(data, pe + 4, "<HHIIIHH")
    require(machine == 0x8664, "Expected an x86_64 PE library")
    optional = pe + 24
    require(optional_size >= 112 and optional + optional_size <= len(data), "Invalid PE optional header")
    magic, = unpack(data, optional, "<H")
    require(magic == 0x20b, "Expected a PE32+ library")
    image_base, = unpack(data, optional + 24, "<Q")
    directory_count, = unpack(data, optional + 108, "<I")
    require(directory_count <= (optional_size - 112) // 8, "Invalid PE data directory count")
    sections = []
    for index in range(count):
        location = optional + optional_size + index * 40
        _, virtual_size, rva, raw_size, raw, _, _, _, _, _ = unpack(data, location, "<8sIIIIIIHHI")
        require(raw + raw_size <= len(data), "Truncated PE section")
        sections.append((rva, max(virtual_size, raw_size), raw, raw_size))

    def resolve(rva, size):
        for start, span, raw, raw_size in sections:
            if start <= rva < start + span:
                delta = rva - start
                require(delta + size <= raw_size, "PE import points outside stored section data")
                return raw + delta, raw + raw_size
        raise ValueError("PE import points outside every section")

    dependencies = set()
    # Check both ordinary and delay-loaded imports. No disassembler or VS shell is needed.
    for directory, stride in ((1, 20), (13, 32)):
        if directory >= directory_count:
            continue
        rva, size = unpack(data, optional + 112 + directory * 8, "<II")
        if rva == 0:
            continue
        require(stride <= size <= len(data), "Invalid PE import directory size")
        terminated = False
        for relative in range(0, size - stride + 1, stride):
            location, _ = resolve(rva + relative, stride)
            fields = unpack(data, location, "<" + "I" * (stride // 4))
            if not any(fields):
                terminated = True
                break
            name_rva = fields[3] if directory == 1 else fields[1]
            if directory == 13 and not (fields[0] & 1):
                name_rva -= image_base
            name, end = resolve(name_rva, 1)
            dependencies.add(cstring(data, name, end).lower())
        require(terminated, "Unterminated PE import directory")
    require(dependencies, "PE library has no recorded system dependencies")
    for name in dependencies:
        api_set = name.startswith(("api-ms-win-core-", "api-ms-win-crt-", "ext-ms-win-")) and name.endswith(".dll")
        require("/" not in name and "\\" not in name and (name in WINDOWS_SYSTEM or api_set), "Non-system Windows dependency: " + name)
    return {"architecture": "x86_64", "dependencies": sorted(dependencies)}


def inspect_macho(data, target):
    magic, cpu, _, file_type, count, command_bytes, _, _ = unpack(data, 0, "<IiiIIIII")
    require(magic == 0xfeedfacf and file_type == 6, "Expected a thin 64-bit Mach-O dynamic library")
    architecture = target.split("-", 1)[1]
    require(cpu == {"x86_64": 0x01000007, "arm64": 0x0100000c}[architecture], "Mach-O architecture differs from its target")
    end = 32 + command_bytes
    require(end <= len(data) and count <= command_bytes // 8, "Truncated Mach-O load commands")
    offset = 32
    dependencies = set()
    minimums = []
    signed = False
    for _ in range(count):
        command, size = unpack(data, offset, "<II")
        require(size >= 8 and size % 8 == 0 and offset + size <= end, "Invalid Mach-O load command")
        if command in (0xc, 0x80000018, 0x8000001f, 0x80000023, 0x20):
            require(size >= 24, "Truncated Mach-O dylib command")
            relative, = unpack(data, offset + 8, "<I")
            require(relative >= 24, "Invalid Mach-O dylib name")
            name = cstring(data, offset + relative, offset + size)
            require(name.startswith(("/usr/lib/", "/System/Library/Frameworks/")) and "/../" not in name,
                    "Non-system macOS dependency: " + name)
            dependencies.add(name)
        elif command == 0x8000001c:
            raise ValueError("macOS library contains a runtime search path")
        elif command in (0x32, 0x24):
            require(size >= (24 if command == 0x32 else 16), "Truncated Mach-O version command")
            if command == 0x32:
                os_platform, version = unpack(data, offset + 8, "<II")
                require(os_platform == 1, "Mach-O library targets a non-macOS platform")
            else:
                version, = unpack(data, offset + 8, "<I")
            minimums.append((version >> 16, (version >> 8) & 255, version & 255))
        elif command == 0x1d:
            require(size >= 16, "Truncated Mach-O signature command")
            signature, length = unpack(data, offset + 8, "<II")
            require(length > 0 and end <= signature <= len(data) - length, "Invalid Mach-O code signature range")
            signed = True
        offset += size
    require(offset == end, "Mach-O load command sizes do not match the header")
    require(dependencies, "Mach-O library has no recorded system dependencies")
    require(len(minimums) == 1, "Mach-O library must declare one minimum macOS version")
    maximum = (13, 0, 0) if architecture == "arm64" else (11, 0, 0)
    require(minimums[0] <= maximum, "macOS minimum exceeds Godot 4.7's supported baseline")
    require(signed, "Mach-O library is missing a code signature")
    return {"architecture": architecture, "dependencies": sorted(dependencies),
            "minimum_macos": ".".join(map(str, minimums[0]))}


def inspect_library(library, target):
    require(target in TARGETS, "Unsupported release target")
    data = library.read_bytes()
    if target.startswith("windows-"):
        result = inspect_pe(data)
    else:
        result = inspect_macho(data, target)
        require(platform.system() == "Darwin", "macOS code signatures must be verified on a macOS runner")
        subprocess.run(["codesign", "--verify", "--strict", str(library)], check=True)
        result["code_signature_verified"] = True
    return {"schema": 1, "target": target, "sha256": hashlib.sha256(data).hexdigest(), **result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    library = args.library or ROOT / "addons/mcf_visuals/bin" / args.target / LIBRARIES[args.target.split("-", 1)[0]]
    try:
        report = {**inspect_library(library, args.target), "passed": True}
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        report = {"schema": 1, "target": args.target, "passed": False, "error": str(error)}
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(text, encoding="utf-8", newline="\n")
    print(text, end="")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
