#!/usr/bin/env python3
"""Extract Android 11 BPF startup diagnostics without modifying the guest image."""
from pathlib import Path
import re
import sys

out = Path(sys.argv[1])
lines = (out / "serial.log").read_text(errors="replace").splitlines()
patterns = re.compile(
    r"bpfloader|bpf\.progs_loaded|libbpf|/sys/fs/bpf|bpffs|BPF_(?:MAP|PROG|OBJ)|"
    r"verifier|invalid func|unknown opcode|reboot_on_failure|reboot,bpfloader-failed|"
    r"service .* exited|service .* failed|critical failure loading bpf|"
    r"failed to (?:load|pin|create).*bpf",
    re.I,
)
hits = [i for i, line in enumerate(lines) if patterns.search(line)]
print(f"serial_lines={len(lines)} bpf_related_lines={len(hits)}")
if not hits:
    print("No BPF-specific diagnostics found in serial; this does not prove BPF succeeded.")
else:
    # Show bounded context around each hit, coalescing overlapping windows.
    spans = []
    for i in hits:
        lo, hi = max(0, i - 12), min(len(lines), i + 5)
        if spans and lo <= spans[-1][1]:
            spans[-1] = (spans[-1][0], max(hi, spans[-1][1]))
        else:
            spans.append((lo, hi))
    for lo, hi in spans:
        print(f"--- serial.log lines {lo + 1}-{hi} ---")
        for i in range(lo, hi):
            print(f"{i + 1}: {lines[i]}")
if any("reboot,bpfloader-failed" in line for line in lines):
    print("OBSERVED init reboot reason=bpfloader-failed; underlying BPF error remains unconfirmed")
