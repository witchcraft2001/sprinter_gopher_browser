#!/usr/bin/env python3
"""Validate the recursive UNETLD dependency and its backend manifest."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UNET_KIT = ROOT / "extern/unet_libs_asm"
CORE = UNET_KIT / "extern/core"
LIBMAN = UNET_KIT / "extern/libman"
MANIFEST = CORE / "dll/manifest.json"

SUBMODULES = {
    "extern/unet_libs_asm": (
        "https://github.com/witchcraft2001/sprinter_unet_libs_asm.git",
        "eab04c24400e05c12b137ac3cd29de500a15ca8b",
        ROOT,
        "extern/unet_libs_asm",
    ),
    "extern/unet_libs_asm/extern/core": (
        "https://github.com/witchcraft2001/unet_libs_core.git",
        "68f1bceb9cda04a623f574f61cd52c7c0004887c",
        UNET_KIT,
        "extern/core",
    ),
    "extern/unet_libs_asm/extern/libman": (
        "https://github.com/witchcraft2001/sprinter-libman.git",
        "f042e3359e516bd602a0e23c06945f6f5bfe13c2",
        UNET_KIT,
        "extern/libman",
    ),
}


class CheckError(Exception):
    pass


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def check_submodules() -> None:
    for path, (expected_url, expected_commit, config_root, config_name) in SUBMODULES.items():
        sub_dir = ROOT / path
        if not sub_dir.is_dir():
            raise CheckError(f"{path}: missing - run `git submodule update --init --recursive`")
        url = git("config", "-f", ".gitmodules", "--get", f"submodule.{config_name}.url", cwd=config_root)
        if url != expected_url:
            raise CheckError(f"{path}: remote {url!r}, expected {expected_url!r}")
        commit = git("rev-parse", "HEAD", cwd=sub_dir)
        if commit != expected_commit:
            raise CheckError(f"{path}: commit {commit}, expected {expected_commit}")
        print(f"ok  {path} @ {commit[:12]}")


def check_dlls() -> None:
    if not MANIFEST.is_file():
        raise CheckError(f"{MANIFEST.relative_to(ROOT)}: manifest missing")
    manifest = json.loads(MANIFEST.read_text())
    dll_dir = MANIFEST.parent
    actual = {path.name for path in dll_dir.glob("UNET*.DLL")}
    expected = set(manifest)
    if actual != expected:
        raise CheckError(f"core DLL set differs from manifest: actual={sorted(actual)}, expected={sorted(expected)}")
    for name, entry in manifest.items():
        path = dll_dir / name
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if len(data) != entry["size"]:
            raise CheckError(f"{path.relative_to(ROOT)}: size {len(data)}, expected {entry['size']}")
        if digest != entry["sha256"]:
            raise CheckError(f"{path.relative_to(ROOT)}: sha256 {digest}, expected {entry['sha256']}")
        print(f"ok  {path.relative_to(ROOT)} ({len(data)} B, sha256 {digest[:12]}...)")


def run_core_checks() -> None:
    env = dict(os.environ)
    env["LIBMAN_ROOT"] = str(LIBMAN)
    commands = (
        [sys.executable, str(CORE / "tools/gen_bindings.py"), "check"],
        [sys.executable, str(CORE / "tools/check_dlls.py"), "--require-mkdll"],
    )
    for command in commands:
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
        if result.returncode:
            raise CheckError(f"core validation failed: {result.stdout}{result.stderr}")
        for line in result.stdout.splitlines():
            print(line)


def main() -> int:
    try:
        check_submodules()
        check_dlls()
        run_core_checks()
    except (CheckError, subprocess.CalledProcessError) as exc:
        print(f"check_deps: FAIL: {exc}", file=sys.stderr)
        return 1
    print("check_deps: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
