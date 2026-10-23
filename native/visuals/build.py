#!/usr/bin/env python3
"""Build optional visual kernels; source-only Godot projects retain GDScript fallback."""
import argparse
import json
from pathlib import Path
import platform
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
# Share the verified bindings revision with the existing policy extension.
LOCK = json.loads((HERE.parent / "policy/dependencies.json").read_text())
LIBRARIES = {"linux": "mcf_visuals.so", "windows": "mcf_visuals.dll", "macos": "mcf_visuals.dylib"}


def stage_manifest(output: Path, target: str):
    system, arch = target.split("-", 1)
    if system not in LIBRARIES or arch not in ("x86_64", "arm64"):
        raise ValueError("Unsupported native visual target: " + target)
    if not (output / LIBRARIES[system]).is_file():
        raise RuntimeError("Native visual library is missing; refusing to register it")
    template = (ROOT / "addons/mcf_visuals/mcf_visuals.gdextension.in").read_text()
    lines = []
    for line in template.splitlines():
        if " = " in line and line.split(" = ", 1)[0].startswith(("linux.", "windows.", "macos.")):
            if not line.startswith(f"{system}.{arch} = "):
                continue
        lines.append(line)
    manifest = output / "mcf_visuals.gdextension"
    manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot-cpp", type=Path)
    parser.add_argument("--cache", type=Path, default=ROOT / ".cache/visual-deps")
    parser.add_argument("--build-dir", type=Path, default=ROOT / ".cache/native-visuals")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    system = {"Linux": "linux", "Windows": "windows", "Darwin": "macos"}.get(platform.system())
    machine = platform.machine().lower()
    arch = {"aarch64": "arm64", "arm64": "arm64", "amd64": "x86_64", "x86_64": "x86_64"}.get(machine)
    if system is None or arch is None or (system == "windows" and arch != "x86_64"):
        parser.error("No native build for this platform; GDScript remains available")
    cpp = (args.godot_cpp or args.cache / "godot-cpp").resolve()
    if not cpp.exists():
        cpp.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--depth", "1", "--branch", LOCK["godot_cpp_tag"],
                        "https://github.com/godotengine/godot-cpp.git", str(cpp)], check=True)
    revision = subprocess.check_output(["git", "-C", str(cpp), "rev-parse", "HEAD"], text=True).strip()
    if revision != LOCK["godot_cpp_commit"]:
        raise RuntimeError("godot-cpp revision differs from the pinned dependencies")
    subprocess.run(["cmake", "-S", str(HERE), "-B", str(args.build_dir),
                    "-DCMAKE_BUILD_TYPE=Release", f"-DGODOT_CPP_DIR={cpp}"], check=True)
    subprocess.run(["cmake", "--build", str(args.build_dir), "--config", "Release",
                    "--parallel", str(args.jobs)], check=True)
    target = f"{system}-{arch}"
    output = ROOT / "addons/mcf_visuals/bin" / target
    notices = output / "licenses"
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(cpp / "LICENSE.md", notices / "godot-cpp-LICENSE.txt")
    stage_manifest(output, target)
    print(f"Staged {target}: {output}")


if __name__ == "__main__":
    main()
