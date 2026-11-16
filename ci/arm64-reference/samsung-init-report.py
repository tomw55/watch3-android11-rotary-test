"""Summarize Samsung-kernel first-stage init integration evidence."""
import re
import sys
from pathlib import Path

out = Path(sys.argv[1])
lines = (out / "serial.log").read_text(errors="replace").splitlines()
markers = {
    "samsung_linux_4_9_59": r"Linux version 4\.9\.59 ",
    "first_stage_init": r"init first stage started",
    "metadata_mount": r"target=/metadata,type=ext4\)=0",
    "logical_ext4": r"EXT4-fs \(dm-\d+\): mounted filesystem",
    "selinux_policy_loaded": r"policy loaded",
    "second_stage_init": r"init second stage started",
}
results = {}
for name, pattern in markers.items():
    matches = [line for line in lines if re.search(pattern, line, re.I)]
    results[name] = bool(matches)
    print(f"{name}={'OBSERVED' if matches else 'NOT OBSERVED'}")
    if matches:
        print(matches[0])
start = next((i for i, line in enumerate(lines) if "Run /init" in line or "first stage started" in line), 0)
errors = re.compile(r"Kernel panic|Failed to mount required partitions|Exec format error|"
                    r"InitFatalReboot|Failed to load SELinux policy|No working init", re.I)
failure = next((line for line in lines[start:] if errors.search(line)), "No fatal marker captured")
print("first_fatal_marker=" + failure)
sys.exit(0 if results["samsung_linux_4_9_59"] and results["second_stage_init"] else 1)
