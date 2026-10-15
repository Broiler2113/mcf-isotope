#!/usr/bin/env python3
"""Fetch pinned CPU dependencies, build and stage the host's GDExtension binaries.

Requires Python 3.12+, CMake 3.22+ and a C++17 compiler. No Python in the game.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
LOCK = json.loads((HERE / "dependencies.json").read_text())


def download(url, path, sha256):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        temp = path.with_suffix(path.suffix + ".part")
        with urllib.request.urlopen(url, timeout=120) as response, temp.open("wb") as out:
            shutil.copyfileobj(response, out)
        temp.replace(path)
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != sha256:
        raise RuntimeError(f"checksum mismatch for {path.name}: {actual}")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cache", type=Path, default=ROOT / ".cache/policy-deps")
    p.add_argument("--build-dir", type=Path, default=ROOT / ".cache/native-policy")
    p.add_argument("--jobs", type=int, default=2)
    p.add_argument("--godot-cpp", type=Path, help="Use an existing checkout of the pinned revision")
    p.add_argument("--ort-root", type=Path, help="Use an extracted pinned ONNX Runtime distribution")
    p.add_argument("--json-include", type=Path, help="Use an existing nlohmann/json.hpp parent directory")
    a = p.parse_args()
    system = {"Linux": "linux", "Windows": "windows", "Darwin": "macos"}[platform.system()]
    arch = "arm64" if platform.machine().lower() in ("aarch64", "arm64") else "x86_64"
    target = f"{system}-{arch}"
    if target not in LOCK["ort"]:
        p.error(f"no bundled CPU runtime for {target}; the game retains socket/HARD fallback")
    cache = a.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    cpp = a.godot_cpp or cache / "godot-cpp"
    if not cpp.exists():
        subprocess.run(["git", "clone", "--depth", "1", "--branch", LOCK["godot_cpp_tag"],
                        "https://github.com/godotengine/godot-cpp.git", str(cpp)], check=True)
    revision = subprocess.check_output(["git", "-C", str(cpp), "rev-parse", "HEAD"], text=True).strip()
    if revision != LOCK["godot_cpp_commit"]:
        raise RuntimeError("godot-cpp revision differs from dependencies.json")
    ort_spec = LOCK["ort"][target]
    ort_root = a.ort_root
    if ort_root is None:
        archive = cache / ort_spec["archive"]
        download(f"https://github.com/microsoft/onnxruntime/releases/download/v{LOCK['ort_version']}/{archive.name}",
                 archive, ort_spec["sha256"])
        ort_root = cache / archive.name.removesuffix(".tgz").removesuffix(".zip")
        if not ort_root.exists():
            if archive.suffix == ".zip":
                with zipfile.ZipFile(archive) as z:
                    z.extractall(cache)
            else:
                with tarfile.open(archive) as t:
                    t.extractall(cache, filter="data")
    if (ort_root / "VERSION_NUMBER").read_text().strip() != LOCK["ort_version"]:
        raise RuntimeError("unexpected ONNX Runtime version")
    json_include = a.json_include or cache / "include"
    header = json_include / "nlohmann/json.hpp"
    download(f"https://raw.githubusercontent.com/nlohmann/json/v{LOCK['json_version']}/single_include/nlohmann/json.hpp",
             header, LOCK["json_sha256"])
    subprocess.run(["cmake", "-S", str(HERE), "-B", str(a.build_dir),
                    "-DCMAKE_BUILD_TYPE=Release", f"-DGODOT_CPP_DIR={cpp.resolve()}",
                    f"-DORT_ROOT={ort_root.resolve()}", f"-DJSON_INCLUDE_DIR={json_include.resolve()}"], check=True)
    subprocess.run(["cmake", "--build", str(a.build_dir), "--config", "Release", "--parallel", str(a.jobs)], check=True)
    output = ROOT / "addons/mcf_policy/bin" / target
    notices = output / "licenses"
    notices.mkdir(exist_ok=True)
    shutil.copy2(ort_root / "LICENSE", notices / "ONNX-Runtime-LICENSE.txt")
    shutil.copy2(ort_root / "ThirdPartyNotices.txt", notices / "ONNX-Runtime-ThirdPartyNotices.txt")
    shutil.copy2(cpp / "LICENSE.md", notices / "godot-cpp-LICENSE.txt")
    shutil.copy2(HERE / "licenses/nlohmann-json-LICENSE.txt", notices / "nlohmann-json-LICENSE.txt")
    if system == "windows":
        # App-local MSVC runtime means players do not need a redistributable installer.
        roots = [Path(os.environ["VCToolsRedistDir"])] if os.environ.get("VCToolsRedistDir") else []
        base = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Microsoft Visual Studio"
        roots += list(base.glob("*/Enterprise/VC/Redist/MSVC/*"))
        roots += list(base.glob("*/Community/VC/Redist/MSVC/*"))
        crt_dirs = sorted(d for root in roots for d in root.glob("x64/Microsoft.VC*.CRT"))
        if not crt_dirs:
            raise RuntimeError("MSVC redistributable DLLs unavailable; run from a VS developer shell")
        for name in ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"):
            shutil.copy2(crt_dirs[-1] / name, output / name)
        # The DLLs are redistributable under Visual Studio's REDIST list/license.
        redist = crt_dirs[-1].parent.parent
        for license_file in redist.glob("*.txt"):
            shutil.copy2(license_file, notices / license_file.name)
    print(f"Staged {target}: {output}")


if __name__ == "__main__":
    main()
