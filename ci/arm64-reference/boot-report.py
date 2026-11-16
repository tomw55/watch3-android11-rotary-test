"""Report only what the stock Ranchu serial log establishes."""
import re
import sys
from pathlib import Path

out = Path(sys.argv[1])
log = (out / "serial.log").read_text(errors="replace")
facts = {
    "first_stage": r"init first stage started",
    "second_stage": r"init second stage started",
    "userdata_disk_at_vdc": r"virtio_blk.*\[vdc\] 2097152 512-byte",
    "metadata_mount": r"target=/metadata,type=ext4\)=0",
    "logical_mounts": r"EXT4-fs \(dm-\d+\): mounted filesystem",
    "data_mount": r"target=/data,type=ext4\)=0",
    "data_rw": r"EXT4-fs \(vdc\):.*(?:r/w|read-write|rw[, )])|(?:Mounted /data|/data mounted).*read.write",
    **{name + "_start": rf"starting service '{name}'" for name in
       ("servicemanager", "hwservicemanager", "vold", "zygote")},
    "system_server": r"SystemServer:.*(?:Entered|Starting|Start)|(?:Start proc|am_proc_start).*system_server",
    "boot_completed_1": r"processing action \(sys\.boot_completed=1\)|sys\.boot_completed\s*[:=]\s*1\b",
    "egl_error": r"eglQueryStringImplementationANDROID\(EGL_VERSION\) failed",
}
observed = {name: bool(re.search(pattern, log, re.IGNORECASE)) for name, pattern in facts.items()}
# A temporary ext4 mount and a changed image do not prove that Android
# retained a writable /data after vold's encryption setup.
before = out / "userdata-before.sha256"
after = out / "userdata-after.sha256"
changed = before.read_text().split()[0] != after.read_text().split()[0]
post_fs = re.search(r"processing action \(post-fs-data\)", log)
post_fs_log = log[post_fs.start():] if post_fs else ""
data_ro = bool(re.search(r"(?:/data(?:/|\b)).*Read-only file system", post_fs_log, re.I))
encryption_failed = bool(re.search(r"Encryption failed|encryptFstab.*Failed", log, re.I))
observed["post_fs_data_seen"] = bool(post_fs)
# Require a positive write check or explicit read-write observation.
observed["data_rw"] = observed["data_rw"] and bool(post_fs) and not data_ro and not encryption_failed
report = ["kernel=stock SDK revision 16 kernel-ranchu (not Samsung Linux 4.9)"]
report += [f"{name}={'OBSERVED' if success else 'NOT OBSERVED'}" for name, success in observed.items()]
report.append(f"post_fs_data_read_only={'YES' if data_ro else 'NOT OBSERVED'}")
report.append(f"encryption_setup_failed={'YES' if encryption_failed else 'NOT OBSERVED'}")
report.append(f"userdata_backing_changed={'YES' if changed else 'NO'}")
report.append("egl_blocks_framework=NO (boot completed despite EGL error)" if
              observed["egl_error"] and observed["boot_completed_1"] else
              "egl_blocks_framework=UNRESOLVED")
(out / "boot-observations.txt").write_text("\n".join(report) + "\n")
print("\n".join(report))
required = (name for name in facts if name != "egl_error")
sys.exit(0 if all(observed[name] for name in required) else 1)
