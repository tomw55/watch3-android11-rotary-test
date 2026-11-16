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
# The expected fstab has no ro flag. A success record with the exact source
# and target plus an ext4 write to the real backing image is stronger than
# a generic kernel ext4 mount line, which does not name the mount point.
before = out / "userdata-before.sha256"
after = out / "userdata-after.sha256"
changed = before.read_text().split()[0] != after.read_text().split()[0]
direct_mount = bool(re.search(r"__mount\(source=/dev/block/vdc,target=/data,type=ext4\)=0", log))
observed["data_rw"] |= direct_mount and changed and observed["userdata_disk_at_vdc"]
report = ["kernel=stock SDK revision 16 kernel-ranchu (not Samsung Linux 4.9)"]
report += [f"{name}={'OBSERVED' if success else 'NOT OBSERVED'}" for name, success in observed.items()]
report.append(f"userdata_backing_changed={'YES' if changed else 'NO'}")
report.append("egl_blocks_framework=NO (boot completed despite EGL error)" if
              observed["egl_error"] and observed["boot_completed_1"] else
              "egl_blocks_framework=UNRESOLVED")
(out / "boot-observations.txt").write_text("\n".join(report) + "\n")
print("\n".join(report))
required = (name for name in facts if name != "egl_error")
sys.exit(0 if all(observed[name] for name in required) else 1)
