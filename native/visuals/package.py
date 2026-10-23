#!/usr/bin/env python3
"""Package tested native kernels and assemble the Windows/Mac source-project bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ("windows-x86_64", "macos-x86_64", "macos-arm64")
LIBRARIES = {"linux": "mcf_visuals.so", "windows": "mcf_visuals.dll", "macos": "mcf_visuals.dylib"}
FIXED_SOURCES = (
    "native/visuals/CMakeLists.txt", "native/visuals/build_profile.json", "native/visuals/build.py",
    "native/policy/dependencies.json", "addons/mcf_visuals/mcf_visuals.gdextension.in",
)
LICENSE = "licenses/godot-cpp-LICENSE.txt"
EXTENSION = "mcf_visuals.gdextension"
STAMP = ".build-provenance.json"
MAX_FILE_SIZE = 64 * 1024 * 1024
MAX_TOTAL_SIZE = 96 * 1024 * 1024
COMMIT = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=True, indent=2) + "\n").encode("utf-8")


def fingerprint(files):
    """SHA256(sorted UTF-8 path + NUL + lowercase hash + LF), without whitespace stripping."""
    return digest("".join(path + "\0" + files[path] + "\n" for path in sorted(files)).encode("utf-8"))


def source_identity(root=ROOT):
    paths = list(FIXED_SOURCES)
    paths += [p.relative_to(root).as_posix() for p in (root / "native/visuals/src").rglob("*")
              if p.is_file() and p.suffix in (".cpp", ".h", ".hpp")]
    if len(paths) == len(FIXED_SOURCES):
        raise ValueError("Native kernel sources are missing")
    files = {path: digest((root / path).read_bytes().replace(b"\r\n", b"\n")) for path in sorted(paths)}
    return files, fingerprint(files)


def library_name(target):
    if target not in TARGETS and target not in ("linux-x86_64", "linux-arm64"):
        raise ValueError("Unsupported native kernel target: " + target)
    return LIBRARIES[target.split("-", 1)[0]]


def payload_names(target):
    return {EXTENSION, library_name(target), LICENSE}


def read_file(base, name):
    path = base / name
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(base.resolve()):
        raise ValueError("Invalid native payload file: " + name)
    if path.stat().st_size > MAX_FILE_SIZE:
        raise ValueError("Native payload file exceeds its size limit: " + name)
    return path.read_bytes()


def file_record(data):
    return {"sha256": digest(data), "size": len(data)}


def record_build(output, target, godot_cpp_commit, root=ROOT, source_commit=None):
    """Called after linking/signing/staging. Packaging refuses changed binaries or inputs."""
    sources, source_hash = source_identity(root)
    if source_commit is None:
        # A downloaded source ZIP has no .git directory, but developer builds
        # must still work. Only distributable CI packages require a commit.
        try:
            top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=root,
                                          text=True, stderr=subprocess.DEVNULL).strip()
            if Path(top).resolve() == root.resolve():
                source_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root,
                                                       text=True, stderr=subprocess.DEVNULL).strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            source_commit = None
    if source_commit is not None and not COMMIT.fullmatch(source_commit):
        raise ValueError("Build provenance requires a Git commit")
    record = {"schema": 1, "target": target, "source_commit": source_commit,
              "source_fingerprint": source_hash, "source_files": sources,
              "godot_cpp_commit": godot_cpp_commit,
              "files": {name: file_record(read_file(output, name)) for name in sorted(payload_names(target))}}
    (output / STAMP).write_bytes(json_bytes(record))
    return record


def verify_provenance(provenance, payload, root=ROOT):
    if not isinstance(provenance, dict) or provenance.get("schema") != 1:
        raise ValueError("Unknown native package schema")
    target = provenance.get("target")
    if target not in TARGETS:
        raise ValueError("Native package is not a release platform")
    sources, source_hash = source_identity(root)
    if provenance.get("source_files") != sources or provenance.get("source_fingerprint") != source_hash:
        raise ValueError("Native package does not match the current kernel sources")
    lock = json.loads((root / "native/policy/dependencies.json").read_text(encoding="utf-8"))
    if provenance.get("godot_cpp_commit") != lock["godot_cpp_commit"]:
        raise ValueError("Native package uses different godot-cpp bindings")
    if not COMMIT.fullmatch(str(provenance.get("source_commit", ""))):
        raise ValueError("Native package has no source commit")
    if set(payload) != payload_names(target) or provenance.get("files") != {
            name: file_record(data) for name, data in payload.items()}:
        raise ValueError("Native package payload hash or size differs from its provenance")
    if not isinstance(provenance.get("godot_version"), str) or not provenance["godot_version"]:
        raise ValueError("Native package has no tested Godot version")
    return target


def create_package(target, output, archive, godot_version, root=ROOT, require_ci=False):
    if target not in TARGETS:
        raise ValueError("Only the three release platforms can be bundled")
    provenance = json.loads(read_file(output, STAMP))
    if provenance.get("target") != target:
        raise ValueError("Build provenance belongs to another platform")
    provenance["godot_version"] = godot_version.strip()
    provenance["ci"] = {key: os.environ.get(env, "") for key, env in (
        ("repository", "GITHUB_REPOSITORY"), ("run_id", "GITHUB_RUN_ID"),
        ("run_attempt", "GITHUB_RUN_ATTEMPT"), ("workflow", "GITHUB_WORKFLOW"))}
    if require_ci and (os.environ.get("GITHUB_ACTIONS") != "true" or
                       not provenance["ci"]["run_id"].isdigit() or
                       provenance["source_commit"] != os.environ.get("GITHUB_SHA")):
        raise ValueError("Release artifacts must come from the tested CI commit")
    payload = {name: read_file(output, name) for name in sorted(payload_names(target))}
    verify_provenance(provenance, payload, root)
    payload["provenance.json"] = json_bytes(provenance)
    archive.parent.mkdir(parents=True, exist_ok=True)
    # Fixed metadata and sorted members make repeated packaging byte-identical.
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zipped:
        for name, data in sorted(payload.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zipped.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    return archive


def read_package(archive, root=ROOT):
    # Never extract an archive. Validate every member, then write known payload names.
    with zipfile.ZipFile(archive) as zipped:
        members = zipped.infolist()
        names = [member.filename for member in members]
        allowed = {EXTENSION, LICENSE, "provenance.json", *LIBRARIES.values()}
        if len(names) != len(set(names)) or "provenance.json" not in names:
            raise ValueError("Native archive has duplicate members or no provenance")
        if any(name not in allowed or PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts for name in names):
            raise ValueError("Native archive contains an unexpected path")
        if sum(member.file_size for member in members) > MAX_TOTAL_SIZE:
            raise ValueError("Native archive exceeds its unpacked size limit")
        for member in members:
            kind = stat.S_IFMT(member.external_attr >> 16)
            if member.file_size > MAX_FILE_SIZE or kind not in (0, stat.S_IFREG) or member.is_dir():
                raise ValueError("Native archive contains a non-file or oversized member")
        data = {name: zipped.read(name) for name in names}
    provenance = json.loads(data.pop("provenance.json"))
    target = verify_provenance(provenance, data, root)
    return target, provenance, data


def bundle_manifest(packages, root=ROOT):
    sources, source_hash = source_identity(root)
    platforms = {}
    for target in TARGETS:
        provenance, payload = packages[target]
        library = library_name(target)
        platforms[target] = {"extension": target + "/" + EXTENSION,
                             "extension_sha256": digest(payload[EXTENSION]),
                             "library": target + "/" + library,
                             "sha256": digest(payload[library]), "library_size": len(payload[library]),
                             "provenance": target + "/provenance.json",
                             "provenance_sha256": digest(json_bytes(provenance))}
    return {"schema": 1, "source_fingerprint": source_hash, "source_files": sources, "platforms": platforms}


def verify_bundle(output, root=ROOT):
    if not output.is_dir() or output.is_symlink() or not (output / ".gdignore").is_file():
        raise ValueError("Native bundle must be a directory hidden from automatic Godot discovery")
    manifest = json.loads(read_file(output, "manifest.json"))
    if not isinstance(manifest, dict) or manifest.get("schema") != 1 or set(manifest.get("platforms", {})) != set(TARGETS):
        raise ValueError("Native bundle must contain all three release platforms")
    expected_files = {".gdignore", "manifest.json"}
    packages = {}
    for target in TARGETS:
        folder = output / target
        if folder.is_symlink():
            raise ValueError("Native bundle platform directory cannot be a symlink")
        provenance = json.loads(read_file(folder, "provenance.json"))
        payload = {name: read_file(folder, name) for name in payload_names(target)}
        if verify_provenance(provenance, payload, root) != target:
            raise ValueError("Native bundle payload belongs to another platform")
        packages[target] = (provenance, payload)
        expected_files.update(target + "/" + name for name in [*payload, "provenance.json"])
    actual_files = {path.relative_to(output).as_posix() for path in output.rglob("*") if path.is_file()}
    if actual_files != expected_files or any(path.is_symlink() for path in output.rglob("*")):
        raise ValueError("Native bundle contains unexpected files or symlinks")
    if manifest != bundle_manifest(packages, root):
        raise ValueError("Native bundle index does not match its payloads and sources")
    return manifest


def assemble(archives, output, root=ROOT):
    packages = {}
    for archive in archives:
        target, provenance, payload = read_package(archive, root)
        if target in packages:
            raise ValueError("Duplicate native package for " + target)
        packages[target] = (provenance, payload)
    if set(packages) != set(TARGETS):
        raise ValueError("Assembling a native bundle requires all three release platforms")
    if len({p[0]["source_commit"] for p in packages.values()}) != 1:
        raise ValueError("Native packages must be tested from the same source commit")
    if output.is_symlink():
        raise ValueError("Native bundle output cannot be a symlink")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".native-bundle-", dir=output.parent) as temporary:
        staging = Path(temporary) / "staged"
        staging.mkdir()
        (staging / ".gdignore").write_bytes(b"")
        for target, (provenance, payload) in packages.items():
            folder = staging / target
            for name, data in payload.items():
                destination = folder / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            (folder / "provenance.json").write_bytes(json_bytes(provenance))
        (staging / "manifest.json").write_bytes(json_bytes(bundle_manifest(packages, root)))
        verify_bundle(staging, root)
        backup = Path(temporary) / "previous"
        if output.exists(): output.rename(backup)
        try:
            staging.rename(output)
        except BaseException:
            if backup.exists(): backup.rename(output)
            raise
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("fingerprint")
    create = commands.add_parser("create")
    create.add_argument("--target", required=True, choices=TARGETS)
    create.add_argument("--input", type=Path)
    create.add_argument("--output", type=Path, required=True)
    create.add_argument("--godot", default="godot")
    create.add_argument("--require-ci", action="store_true")
    merge = commands.add_parser("assemble")
    merge.add_argument("--artifacts", type=Path, required=True)
    merge.add_argument("--output", type=Path, default=ROOT / "addons/mcf_visuals/prebuilt")
    verify = commands.add_parser("verify")
    verify.add_argument("--bundle", type=Path, default=ROOT / "addons/mcf_visuals/prebuilt")
    args = parser.parse_args()
    if args.command == "fingerprint":
        sources, source_hash = source_identity()
        print(json_bytes({"source_fingerprint": source_hash, "source_files": sources}).decode(), end="")
    elif args.command == "create":
        version = subprocess.check_output([args.godot, "--version"], text=True).strip()
        output = args.input or ROOT / "addons/mcf_visuals/bin" / args.target
        print(create_package(args.target, output, args.output, version, require_ci=args.require_ci))
    elif args.command == "assemble":
        print(assemble(sorted(args.artifacts.rglob("mcf-kernels-*.zip")), args.output))
    else:
        manifest = verify_bundle(args.bundle)
        print("Verified Windows/Mac native bundle: " + manifest["source_fingerprint"])


if __name__ == "__main__":
    main()
