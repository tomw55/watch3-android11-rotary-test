#!/usr/bin/env python3
"""Extract storage mount and early userspace crash evidence from QEMU serial."""
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
lines = (out / "serial.log").read_text(errors="replace").splitlines()
patterns = {
    "storage": re.compile(r"mount_all|mountFstab|libfs_mgr|fstab|userdata|/data|vold|checkpoint|dm-|read-only file system|EROFS|encrypt", re.I),
    "crashes": re.compile(r"zygote|tombstoned|SIGABRT|signal 6|Abort message|AndroidRuntime|Fatal signal|art/runtime", re.I),
}
for label, pattern in patterns.items():
    matches = [(i + 1, line) for i, line in enumerate(lines) if pattern.search(line)]
    # Preserve the first events, where the root cause is likeliest; keep a
    # bounded tail to show whether the failure persists through the run.
    chosen = matches[:180] + (matches[-50:] if len(matches) > 230 else matches[180:])
    report = [f"total_matches={len(matches)}", f"selected_matches={len(chosen)}"]
    report += [f"{i}: {line}" for i, line in chosen]
    (out / f"{label}-serial-diagnostics.txt").write_text("\n".join(report) + "\n")
    print(f"{label}_serial_matches={len(matches)}")
config = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
if config and config.is_file():
    wanted = re.compile(r"^(?:CONFIG_(?:SECCOMP|SECCOMP_FILTER|ASHMEM|ASHMEM_ANDROID|MEMFD_CREATE|SHMEM|TMPFS|USERFAULTFD|EXT4_FS|FS_ENCRYPTION|QUOTA|QFMT_V2)=|# CONFIG_(?:SECCOMP|SECCOMP_FILTER|ASHMEM|ASHMEM_ANDROID|MEMFD_CREATE|SHMEM|TMPFS|USERFAULTFD|EXT4_FS|FS_ENCRYPTION|QUOTA|QFMT_V2) is not set)")
    selected = [line for line in config.read_text(errors="replace").splitlines() if wanted.search(line)]
    (out / "storage-zygote-kernel-config.txt").write_text("\n".join(selected) + "\n")
    print("storage_zygote_config_entries=" + str(len(selected)))
