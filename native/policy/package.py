"""Export a host-platform game with the staged native policy, runtime, and model."""
import argparse
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import zipfile

from build import ROOT, stage_manifest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--godot", default="godot")
    p.add_argument("--output", type=Path, default=ROOT / ".cache/policy-release")
    a = p.parse_args()
    subprocess.run([sys.executable, str(ROOT / "tools/audio/bake_audio.py"), "--check"], check=True)
    system = platform.system()
    target = {"Linux": "Linux", "Windows": "Windows Desktop", "Darwin": "macOS"}[system]
    arch = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x86_64"
    native_target = {"Linux": "linux", "Windows": "windows", "Darwin": "macos"}[system] + "-" + arch
    binaries = ROOT / "addons/mcf_policy/bin" / native_target
    model = ROOT / "assets/policy/baseline.onnx"
    if not binaries.is_dir() or not model.is_file():
        p.error("build native/policy/build.py and export a baseline model first")
    stage_manifest(binaries, native_target)
    output = a.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    stage = output / "project"
    stage.mkdir(exist_ok=True)
    # An isolated export tree keeps local saves, Python environments and training runs out.
    for name in ("src", "scenes", "fonts", "textures", "interface_textures", "assets", "addons", "rl", "audio"):
        shutil.copytree(ROOT / name, stage / name, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("runs", "__pycache__", "*.py", "*.sh", "*.yaml", ".streamlit"))
    staged_addon = stage / "addons/mcf_policy"
    # Previous exports may contain the former unconditional root manifest.
    for old in staged_addon.glob("*.gdextension*"):
        if not old.name.endswith((".in", ".in.uid")):
            old.unlink()
    staged_bins = staged_addon / "bin"
    for platform_dir in staged_bins.iterdir():
        if platform_dir.is_dir() and platform_dir.name != native_target:
            shutil.rmtree(platform_dir)
    shutil.copy2(ROOT / "project.godot", stage / "project.godot")
    smoke_dir = stage / "native/policy"
    smoke_dir.mkdir(parents=True, exist_ok=True)
    for filename in ("export_smoke.gd", "export_smoke.tscn"):
        shutil.copy2(ROOT / "native/policy" / filename, smoke_dir / filename)
    preset = f'''[preset.0]
name="Native Policy"
platform="{target}"
runnable=true
export_filter="all_resources"
include_filter="*.onnx,*.json,addons/mcf_policy/bin/*/licenses/*"
exclude_filter=""

[preset.0.options]
binary_format/architecture="{arch}"
application/export_angle=0
'''
    if system == "Darwin":
        preset += 'application/bundle_identifier="org.mcf.isotope"\ncodesign/codesign=1\n'
    (stage / "export_presets.cfg").write_text(preset, encoding="utf-8")
    game_dir = output / native_target
    game_dir.mkdir(exist_ok=True)
    name = "MCF-Isotope" + {"Linux": ".x86_64", "Windows": ".exe", "Darwin": ".zip"}[system]
    subprocess.run([a.godot, "--headless", "--editor", "--path", str(stage), "--import"], check=True, timeout=240)
    subprocess.run([a.godot, "--headless", "--path", str(stage), "--export-release", "Native Policy", str(game_dir / name), "--quit"],
                   check=True, timeout=240)
    # Keep third-party license notices readily accessible alongside each export.
    shutil.copytree(binaries / "licenses", game_dir / "licenses", dirs_exist_ok=True)
    executable = game_dir / name
    if system == "Darwin":
        with zipfile.ZipFile(executable) as z:
            exe_name = next(n for n in z.namelist() if "/Contents/MacOS/" in n and not n.endswith("/"))
            z.extractall(game_dir)
        executable.unlink()
        executable = game_dir / exe_name
        executable.chmod(0o755)
    subprocess.run([str(executable), "--headless", "--", "--native-policy-smoke"],
                   check=True, timeout=90)
    shutil.make_archive(str(output / native_target), "zip", game_dir)
    print(output / (native_target + ".zip"))


if __name__ == "__main__":
    main()
