#!/usr/bin/env python3
"""Read-only, offline inspection of a Samsung watch firmware archive.

No device access, flashing, extraction or writes. Never execute archive members.
Usage: python3 scripts/audit-watch-firmware.py /path/to/firmware.tar[.md5] --model SM-R840
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tarfile

MAX_MEMBERS = 5000
READ_CHUNK = 1024 * 1024
PARTITION_HINTS = ("sboot", "boot", "recovery", "ramdisk", "dzimage", "rootfs",
                   "system-data", "param", "csc", "pit", "user", "nad_fw")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--model", default="SM-R840", choices=("SM-R840",))
    args = parser.parse_args()
    path = args.archive
    if not path.is_file():
        parser.error("Firmware archive is not a regular file")
    if path.is_symlink():
        parser.error("Refusing a symbolic link")
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(READ_CHUNK):
            sha.update(chunk)
    findings = []
    total_members = 0
    try:
        with tarfile.open(path, mode="r:") as archive:
            for member in archive:
                total_members += 1
                if total_members > MAX_MEMBERS:
                    raise ValueError("Archive exceeds member limit")
                if not member.isfile():
                    findings.append({"name": member.name, "type": "non-regular", "size": member.size})
                    continue
                basename = member.name.rsplit("/", 1)[-1]
                is_relevant = any(token in basename.lower() for token in PARTITION_HINTS)
                if is_relevant:
                    findings.append({"name": member.name, "type": "regular", "size": member.size})
    except (tarfile.TarError, ValueError, OSError) as exc:
        print(f"ERROR: Cannot inspect archive as tar: {exc}", file=sys.stderr)
        return 2
    name = path.name.upper()
    model_token = args.model.replace("SM-", "")
    embedded = sorted(set(re.findall(r"R(?:800|810|840|845|850|855)", name)))
    flags = []
    if embedded and model_token not in embedded:
        flags.append("STOP: archive filename references other watch model(s): " + ", ".join(embedded))
    if not embedded:
        flags.append("UNVERIFIED: no supported model identifier in archive filename")
    if any(item["type"] != "regular" for item in findings):
        flags.append("WARNING: archive contains non-regular members; no members were extracted")
    flags.append("UNVERIFIED: authenticity, bootloader revision, anti-rollback, signatures and safe rollback")
    print(json.dumps({
        "mode": "offline-read-only", "target_model": args.model,
        "archive_name": path.name, "archive_bytes": path.stat().st_size,
        "sha256": sha.hexdigest(), "member_count": total_members,
        "partition_related_members": findings, "flags": flags,
        "flash_authorized": False
    }, indent=2))
    return 0

if __name__ == "__main__":
    sys.exit(main())
