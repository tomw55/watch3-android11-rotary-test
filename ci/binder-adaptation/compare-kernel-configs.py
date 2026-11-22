#!/usr/bin/env python3
"""Compare R800 Android 4.19 reference with an SM-R840 kernel config.

Usage: python3 compare-kernel-configs.py --reference r800.config [--target r840.config]
If --target is omitted, output clearly identifies target values as UNKNOWN.
No hardware interaction. Does not claim servicemanager execution.
"""
import argparse
import json
from pathlib import Path

FEATURES = {
    "binder": ["CONFIG_ANDROID_BINDER_IPC", "CONFIG_ANDROID_BINDER_DEVICES", "CONFIG_ANDROID_BINDERFS"],
    "memory": ["CONFIG_ASHMEM", "CONFIG_MEMFD_CREATE"],
    "security": ["CONFIG_SECURITY_SELINUX", "CONFIG_SECCOMP", "CONFIG_SECCOMP_FILTER"],
    "isolation": ["CONFIG_NAMESPACES", "CONFIG_CGROUPS"],
    "filesystem": ["CONFIG_OVERLAY_FS"],
    "rotary": ["CONFIG_INPUT_TIZEN_DETENT"],
}


def parse(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            values[line[2:].split(" ", 1)[0]] = "n"
    return values


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reference", required=True)
    ap.add_argument("--target")
    ap.add_argument("--output", default="kernel-compatibility.json")
    args = ap.parse_args()
    reference = parse(args.reference)
    target = parse(args.target) if args.target else None
    rows = []
    for group, keys in FEATURES.items():
        for key in keys:
            r = reference.get(key, "ABSENT")
            t = target.get(key, "UNKNOWN") if target is not None else "UNKNOWN"
            rows.append({
                "group": group, "option": key, "r800_reference": r,
                "r840_target": t,
                "status": "UNKNOWN" if target is None else (
                    "MATCH" if r == t else "DIFFERENT_OR_ABSENT"
                ),
            })
            print(f"{group:11} {key:37} R800={r:28} R840={t}")
    result = {
        "reference": args.reference, "target": args.target,
        "target_evidence_available": target is not None,
        "features": rows,
        "limitations": [
            "SM-R800 and SM-R840 hardware configurations are not interchangeable.",
            "Matching kernel options does not establish ABI compatibility or Android boot.",
            "This audit does not execute Android servicemanager under QEMU.",
            "No flashing is authorized.",
        ],
    }
    Path(args.output).write_text(json.dumps(result, indent=2) + "\n")
    print("PASS: comparison report generated; no execution or hardware claims")


if __name__ == "__main__":
    main()
