#!/usr/bin/env python3
"""Build the .kpkg package and the KPM repository that serves it.

Two subcommands:

    package             build dist/<id>_<version>_kindleany.kpkg
    repo                fold every built package into dist/repo/<channel>/

The repository layout is what KPM expects — a manifest.json whose artifact
URLs are relative to the manifest itself — plus two things KPM does not read
but we do: a sha256 on every artifact, and a version.json the plugin's own
update check can poll.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN_DIR = ROOT / "plugin" / "aidict.koplugin"
PACKAGING_DIR = ROOT / "packaging"
DIST_DIR = ROOT / "dist"

PACKAGE_ID = "koreader-aidict"
PACKAGE_NAME = "AI dictionary"
PACKAGE_AUTHOR = "npwork"
PACKAGE_DESCRIPTION = (
    "Explains the word you tapped in KOReader, in context, by asking a remote AI service."
)
# KPM's C implementation reads manifest v2 (tar.gz). v3 would be zstd, which
# not every device's libarchive carries.
MANIFEST_VERSION = 2

REPO_ID = "npwork"
REPO_NAME = "npwork packages"
REPO_DESCRIPTION = "Personal KOReader and Kindle packages"
CHANNELS = ("stable", "dev")


def read_version() -> tuple[int, int, int]:
    """Parse plugin/aidict.koplugin/aidict/version.lua — the single source."""
    text = (PLUGIN_DIR / "aidict" / "version.lua").read_text()
    match = re.search(r'string\s*=\s*"(\d+)\.(\d+)\.(\d+)"', text)
    if not match:
        raise SystemExit("could not read the version out of version.lua")
    return tuple(int(part) for part in match.groups())


def version_string(version: tuple[int, int, int]) -> str:
    return ".".join(str(part) for part in version)


def display(path: Path) -> str:
    """Path relative to the repo when it is inside it, absolute otherwise."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_package(output_dir: Path) -> Path:
    version = read_version()
    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "id": PACKAGE_ID,
        "name": PACKAGE_NAME,
        "author": PACKAGE_AUTHOR,
        "description": PACKAGE_DESCRIPTION,
        "version": list(version),
        "dependencies": [],
        # None means "any Kindle": the plugin is pure Lua.
        "supported_platforms": None,
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    package_path = output_dir / f"{PACKAGE_ID}_{version_string(version)}_kindleany.kpkg"

    def entry(info: tarfile.TarInfo) -> tarfile.TarInfo:
        # Reproducible archives: no uid/gid/mtime from the build machine.
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = int(os.environ.get("SOURCE_DATE_EPOCH", 0))
        return info

    with tarfile.open(package_path, "w:gz", compresslevel=9) as archive:
        manifest_bytes = json.dumps(manifest, indent=2).encode()
        info = tarfile.TarInfo("manifest.json")
        info.size = len(manifest_bytes)
        info.mode = 0o644
        archive.addfile(entry(info), __import__("io").BytesIO(manifest_bytes))

        for hook in ("install.sh", "uninstall.sh"):
            source = PACKAGING_DIR / hook
            hook_info = archive.gettarinfo(str(source), arcname=hook)
            hook_info.mode = 0o755
            with source.open("rb") as handle:
                archive.addfile(entry(hook_info), handle)

        for path in sorted(PLUGIN_DIR.rglob("*")):
            if path.name.endswith(".swp") or "__pycache__" in path.parts:
                continue
            arcname = str(Path("aidict.koplugin") / path.relative_to(PLUGIN_DIR))
            info = archive.gettarinfo(str(path), arcname=arcname)
            info.mode = 0o755 if path.is_dir() else 0o644
            if path.is_dir():
                archive.addfile(entry(info))
            else:
                with path.open("rb") as handle:
                    archive.addfile(entry(info), handle)

    print(f"built {display(package_path)} ({package_path.stat().st_size} bytes)")
    print(f"sha256 {sha256(package_path)}")
    return package_path


def package_manifest_from(archive_path: Path) -> dict:
    with tarfile.open(archive_path, "r:*") as archive:
        member = archive.extractfile("manifest.json")
        if member is None:
            raise SystemExit(f"{archive_path} has no manifest.json")
        return json.loads(member.read())


def build_repo(packages: list[Path], channel: str, repo_root: Path, base_url: str) -> Path:
    if channel not in CHANNELS:
        raise SystemExit(f"channel must be one of {CHANNELS}")

    channel_root = repo_root / channel
    if channel_root.exists():
        shutil.rmtree(channel_root)
    channel_root.mkdir(parents=True)

    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "id": f"{REPO_ID}-{channel}" if channel != "stable" else REPO_ID,
        "name": REPO_NAME if channel == "stable" else f"{REPO_NAME} ({channel})",
        "description": REPO_DESCRIPTION,
        "packages": {},
    }
    checksums = []
    latest = {}

    for archive_path in packages:
        package = package_manifest_from(archive_path)
        version = ".".join(str(part) for part in package["version"])
        platforms = package.get("supported_platforms") or None
        suffix = "-".join(platforms) if platforms else "kindleany"

        relative = Path("packages") / package["id"] / "artifacts" / f"{package['id']}_{version}_{suffix}.kpkg"
        destination = channel_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(archive_path, destination)

        digest = sha256(destination)
        checksums.append(f"{digest}  {relative.as_posix()}")

        entry = manifest["packages"].setdefault(
            package["id"],
            {
                "name": package["name"],
                "author": package["author"],
                "description": package["description"],
                "artifacts": [],
            },
        )
        entry["artifacts"].append(
            {
                "url": relative.as_posix(),
                "version": package["version"],
                "dependencies": package.get("dependencies", []),
                "supported_platforms": platforms,
                # Ignored by KPM, read by our own update check.
                "sha256": digest,
            }
        )

        previous = latest.get(package["id"])
        if previous is None or tuple(package["version"]) > tuple(previous["version"]):
            latest[package["id"]] = {
                "version": package["version"],
                "version_string": version,
                "url": f"{base_url.rstrip('/')}/{channel}/{relative.as_posix()}",
                "sha256": digest,
            }

    for entry in manifest["packages"].values():
        entry["artifacts"].sort(key=lambda artifact: tuple(artifact["version"]))

    (channel_root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (channel_root / "SHA256SUMS").write_text("\n".join(sorted(checksums)) + "\n")
    (channel_root / "version.json").write_text(
        json.dumps(
            {
                "channel": channel,
                "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "manifest_url": f"{base_url.rstrip('/')}/{channel}/manifest.json",
                "packages": latest,
            },
            indent=2,
        )
        + "\n"
    )

    print(f"repository written to {display(channel_root)}")
    print(f"  kpm repo add {base_url.rstrip('/')}/{channel}/manifest.json")
    return channel_root


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    package_parser = sub.add_parser("package", help="build the .kpkg")
    package_parser.add_argument("--output", default=str(DIST_DIR), help="where to write the package")

    repo_parser = sub.add_parser("repo", help="build the KPM repository around built packages")
    repo_parser.add_argument("packages", nargs="*", help=".kpkg files (default: everything in dist/)")
    repo_parser.add_argument("--channel", default="stable", choices=CHANNELS)
    repo_parser.add_argument("--output", default=str(DIST_DIR / "repo"))
    repo_parser.add_argument("--base-url", default="https://repo.example/kpm")

    args = parser.parse_args(argv)

    if args.command == "package":
        build_package(Path(args.output))
        return 0

    packages = [Path(p) for p in args.packages]
    if not packages:
        packages = sorted(DIST_DIR.glob("*.kpkg"))
    if not packages:
        raise SystemExit("no .kpkg to publish — run `package` first")
    build_repo(packages, args.channel, Path(args.output), args.base_url)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
