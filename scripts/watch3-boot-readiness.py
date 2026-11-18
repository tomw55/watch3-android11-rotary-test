#!/usr/bin/env python3
"""Offline, fail-closed SM-R840 port evidence inventory. Never accesses a device."""
import argparse
import json
from pathlib import Path

CHECKS = [
    ("kernel_build_script", "scripts/build-kernel.sh", "Build driver exists; does not prove boot"),
    ("kernel_toolchain", "scripts/install-kernel-toolchain.sh", "Pinned cross-toolchain installer exists"),
    ("kernel_audit", "docs/kernel-build-audit.md", "Documented local compile evidence, not independently rerun"),
    ("recovery_audit", "docs/sm-r840-recovery-image-packaging-audit.md", "Source-level image packaging research"),
    ("recovery_plan", "docs/recovery-first-porting-plan.md", "Recovery-first safety gates"),
    ("firmware_auditor", "scripts/audit-watch-firmware.py", "Offline firmware inventory tool"),
    ("binder_patch", "ci/binder-adaptation/context-manager-stage1.patch", "Android Binder adaptation input"),
    ("servicemanager_acquisition", "ci/binder-adaptation/acquire-servicemanager.sh", "Android 11 userspace acquisition"),
    ("qemu_workflow", ".github/workflows/android11-servicemanager-qemu.yml", "Emulation workflow definition, not a passed test"),
    ("kernel_workflow", ".github/workflows/kernel-build.yml", "Compile workflow definition, not a passed test"),
]
BLOCKERS = [
    "Retail DWK2 S-Boot acceptance of unsigned recovery images is unverified",
    "No authenticated SM-R840 engineering bootloader or authorized unlock route",
    "No proven recovery image packer/signing route for retail firmware",
    "Physical board revision, read-only partition map and rollback are unverified",
    "No successful SM-R840 Android/Wear OS boot or hardware validation",
    "Real Android 11 ARM64 servicemanager QEMU launch not yet confirmed passing",
]
def build_report(root):
    items = [{"id": key, "path": path, "present": (root / path).is_file(),
              "scope": scope} for key, path, scope in CHECKS]
    return {
        "target": "Samsung Galaxy Watch3 SM-R840 45mm Bluetooth, retail R840XXU1DWK2",
        "mode": "OFFLINE_ONLY_NO_FLASH",
        "decision": "NO_GO_FOR_FLASHING",
        "inventory": items,
        "missing_repository_inputs": [x["path"] for x in items if not x["present"]],
        "unverified_blockers": BLOCKERS,
        "note": "File presence is not proof of a successful CI run, device boot, signing bypass or rollback.",
    }
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = build_report(args.root.resolve())
    data = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(data, encoding="utf-8")
    else:
        print(data, end="")
    return 1 if report["missing_repository_inputs"] else 0
if __name__ == "__main__":
    raise SystemExit(main())
