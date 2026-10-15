"""Install the pinned official Godot editor + export templates into a CI workspace."""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import urllib.request
import zipfile

from build import ROOT

VERSION = "4.7"


def main():
    system = platform.system()
    suffix = {"Linux": "linux.x86_64.zip", "Windows": "win64.exe.zip", "Darwin": "macos.universal.zip"}[system]
    base = f"https://github.com/godotengine/godot/releases/download/{VERSION}-stable/"
    cache = ROOT / ".cache/godot"
    cache.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(base + "SHA512-SUMS.txt", timeout=120) as r:
        sums = r.read().decode()
    for name in (f"Godot_v{VERSION}-stable_{suffix}", f"Godot_v{VERSION}-stable_export_templates.tpz"):
        path = cache / name
        if not path.exists():
            with urllib.request.urlopen(base + name, timeout=120) as response, path.open("wb") as out:
                shutil.copyfileobj(response, out)
        expected = next(line.split()[0] for line in sums.splitlines() if line.split()[-1].lstrip("*") == name)
        if hashlib.sha512(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError("Godot archive checksum mismatch: " + name)
        with zipfile.ZipFile(path) as z:
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
    templates = data / "export_templates" / f"{VERSION}.stable"
    templates.mkdir(parents=True, exist_ok=True)
    shutil.copytree(cache / "templates", templates, dirs_exist_ok=True)
    # zip extraction does not retain Unix execute bits.
    for template in templates.iterdir():
        if template.is_file():
            template.chmod(0o755)
    bin_dir = cache / "bin"
    bin_dir.mkdir(exist_ok=True)
    shutil.copy2(executable, bin_dir / ("godot.exe" if system == "Windows" else "godot"))
    if os.environ.get("GITHUB_PATH"):
        with open(os.environ["GITHUB_PATH"], "a") as out:
            out.write(str(bin_dir) + "\n")
    print(bin_dir)


if __name__ == "__main__":
    main()
