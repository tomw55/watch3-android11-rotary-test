import re
import sys
from pathlib import Path

nonce = sys.argv[1]
records = {}
for line in Path(sys.argv[2]).read_text().splitlines():
    match = re.fullmatch(
        r"\S+\s+\S+\s+(\d+)\s+\d+\s+I\s+Watch3BinderCI\s*:\s*"
        r"(CLIENT|SERVER) ([0-9a-f]{32}) (\d+) (\d+) (\d+)",
        line.strip(),
    )
    if not match or match[3] != nonce:
        continue
    pid, role = int(match[1]), match[2]
    caller, server, uid = map(int, match.groups()[3:])
    if role in records or caller <= 0 or server <= 0 or caller == server or uid <= 0:
        sys.exit(1)
    if pid != (caller if role == "CLIENT" else server):
        sys.exit(1)
    records[role] = (caller, server, uid)
if set(records) != {"CLIENT", "SERVER"} or records["CLIENT"] != records["SERVER"]:
    sys.exit(1)
print(f"PASS Binder nonce={nonce} client_pid=%d server_pid=%d uid=%d" % records["CLIENT"])
