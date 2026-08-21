#!/usr/bin/env python3
"""Verify the submodule pins and UNET DLLs this build depends on.

Modeled on sources/weather-forecast/tools/check_deps.py: pins the exact
submodule commit + remote URL, and the exact size/sha256 of both shipped
DLLs, so a stale/forgotten `git submodule update` or a locally-edited DLL
fails the build loudly instead of producing a silently-wrong GOPHER.EXE.
Also byte-compares unet.inc between the wifi and rtl kits - the ABI header
is supposed to be frozen and identical in both.

Run directly (`python3 tools/check_deps.py`) or via `make deps`.
"""
from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SUBMODULES = {
    "extern/wifi": {
        "url": "git@github.com:witchcraft2001/sprinter_net.git",
        "commit": "cddd27892039895e2dc330852f2c2662dfc5b90e",
    },
    "extern/rtl": {
        "url": "https://github.com/witchcraft2001/sprinter-rtl8019a.git",
        "commit": "243fbe5ff65e494f365d0dc3d1996ced906b7c38",
    },
    "extern/libman": {
        "url": "git@github.com:witchcraft2001/sprinter-libman.git",
        "commit": "f042e3359e516bd602a0e23c06945f6f5bfe13c2",
    },
}

DLLS = {
    "extern/wifi/UNETESP.DLL": {
        "size": 16032,
        "sha256": "2bf4f90afbbdf34a68e486def7c5bc5cc17be4361f77cecb52004068c4ab5455",
    },
    "extern/rtl/UNETRTL.DLL": {
        "size": 16237,
        "sha256": "8881b534306efb00b2c871ed7044bb2c2310fb8b25b33e01880239c81632160c",
    },
}

UNET_INC_WIFI = "extern/wifi/src/include/unet.inc"
UNET_INC_RTL = "extern/rtl/src/include/unet.inc"


class CheckError(Exception):
    pass


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def check_submodules() -> None:
    for path, expect in SUBMODULES.items():
        sub_dir = ROOT / path
        if not sub_dir.is_dir():
            raise CheckError(f"{path}: missing - run `git submodule update --init`")
        url = git("config", "-f", ".gitmodules", "--get", f"submodule.{path}.url")
        if url != expect["url"]:
            raise CheckError(f"{path}: unexpected remote {url!r} (expected {expect['url']!r})")
        commit = git("rev-parse", "HEAD", cwd=sub_dir)
        if commit != expect["commit"]:
            raise CheckError(
                f"{path}: pinned at {commit}, expected {expect['commit']} "
                f"(run `git -C {path} checkout {expect['commit']}`, or update the "
                f"pin in tools/check_deps.py after a deliberate submodule bump)"
            )
        print(f"ok  {path} @ {commit[:12]}")


def check_dlls() -> None:
    for rel, expect in DLLS.items():
        f = ROOT / rel
        if not f.is_file():
            raise CheckError(f"{rel}: missing")
        data = f.read_bytes()
        if len(data) != expect["size"]:
            raise CheckError(f"{rel}: size {len(data)} B, expected {expect['size']} B")
        digest = hashlib.sha256(data).hexdigest()
        if digest != expect["sha256"]:
            raise CheckError(f"{rel}: sha256 {digest}, expected {expect['sha256']}")
        print(f"ok  {rel} ({len(data)} B, sha256 {digest[:12]}...)")


def check_unet_inc_identical() -> None:
    a = (ROOT / UNET_INC_WIFI).read_bytes()
    b = (ROOT / UNET_INC_RTL).read_bytes()
    if a != b:
        raise CheckError(
            f"{UNET_INC_WIFI} and {UNET_INC_RTL} differ - the UNET ABI header "
            "is supposed to be frozen and byte-identical across backends"
        )
    print("ok  unet.inc identical (wifi == rtl)")


def main() -> int:
    try:
        check_submodules()
        check_dlls()
        check_unet_inc_identical()
    except CheckError as exc:
        print(f"check_deps: FAIL: {exc}", file=sys.stderr)
        return 1
    print("check_deps: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
