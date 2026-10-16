"""Install the pinned official Godot editor + export templates into a CI workspace."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import urllib.request
import zipfile

from build import ROOT

VERSION = "4.7"


def prepare_macos_template(archive, cache):
    # Official templates contain universal executables. Godot's single-arch
    # exporter requests an explicitly named slice, matching our native runtime.
    arch = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x86_64"
    with zipfile.ZipFile(archive, "a", compression=zipfile.ZIP_DEFLATED) as app:
        names = app.namelist()
        for name in names:
            if not name.endswith(".universal"):
                continue
            target = name.removesuffix(".universal") + "." + arch
            if target in names:
                continue
            source = Path(app.extract(name, cache / "macos-template"))
            thin = source.with_suffix("." + arch)
            subprocess.run(["lipo", str(source), "-thin", arch, "-output", str(thin)], check=True)
            thin.chmod(0o755)
            app.write(thin, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor-only", action="store_true", help="skip application export templates")
    args = parser.parse_args()
    system = platform.system()
    suffix = {"Linux": "linux.x86_64.zip", "Windows": "win64.exe.zip", "Darwin": "macos.universal.zip"}[system]
    base = f"https://github.com/godotengine/godot/releases/download/{VERSION}-stable/"
    cache = ROOT / ".cache/godot"
    cache.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(base + "SHA512-SUMS.txt", timeout=120) as r:
        sums = r.read().decode()
    archives = [f"Godot_v{VERSION}-stable_{suffix}"]
    if not args.editor_only:
        archives.append(f"Godot_v{VERSION}-stable_export_templates.tpz")
    for name in archives:
        path = cache / name
        if not path.exists():
            with urllib.request.urlopen(base + name, timeout=120) as response, path.open("wb") as out:
                shutil.copyfileobj(response, out)
        expected = next(line.split()[0] for line in sums.splitlines() if line.split()[-1].lstrip("*") == name)
        with path.open("rb") as archive:
            actual = hashlib.file_digest(archive, "sha512").hexdigest()
        if actual != expected:
            raise RuntimeError("Godot archive checksum mismatch: " + name)
        with zipfile.ZipFile(path) as z:
            if name.endswith(".tpz"):
                for member in z.namelist():
                    needed = {"Linux": "linux_", "Windows": "windows_", "Darwin": "macos.zip"}[system]
                    if member == "templates/version.txt" or member.removeprefix("templates/").startswith(needed):
                        z.extract(member, cache)
            else:
                z.extractall(cache)
    executable = (cache / "Godot.app/Contents/MacOS/Godot" if system == "Darwin" else
                  cache / f"Godot_v{VERSION}-stable_{'win64.exe' if system == 'Windows' else 'linux.x86_64'}")
    executable.chmod(0o755)
    if system == "Windows":
        data = Path(os.environ["APPDATA"]) / "Godot"
    elif system == "Darwin":
        data = Path.home() / "Library/Application Support/Godot"
    else:
        data = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "godot"
    if not args.editor_only:
        templates = data / "export_templates" / f"{VERSION}.stable"
        templates.mkdir(parents=True, exist_ok=True)
        shutil.copytree(cache / "templates", templates, dirs_exist_ok=True)
        if system == "Darwin":
            prepare_macos_template(templates / "macos.zip", cache)
        # zip extraction does not retain Unix execute bits.
        for template in templates.iterdir():
            if template.is_file():
                template.chmod(0o755)
    bin_dir = cache / "bin"
    bin_dir.mkdir(exist_ok=True)
    if system == "Darwin":
        # Keep the editor in its signed app bundle. Copying just its Mach-O out
        # of the bundle can be rejected by macOS before main() is reached.
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(cache / "Godot.app")], check=True)
        launcher = bin_dir / "godot"
        launcher.write_text('#!/bin/sh\nexec "' + str(executable) + '" "$@"\n', encoding="utf-8")
        launcher.chmod(0o755)
    else:
        shutil.copy2(executable, bin_dir / ("godot.exe" if system == "Windows" else "godot"))
    if os.environ.get("GITHUB_PATH"):
        with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as out:
            out.write(str(bin_dir) + "\n")
    print(bin_dir)


if __name__ == "__main__":
    main()
