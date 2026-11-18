#!/usr/bin/env python3
"""A green diagnostic is not a full boot: require real framework evidence."""
import pathlib,re,sys
path=pathlib.Path(sys.argv[1])
if not path.is_file():
 print('NOT RUN framework checks: serial capture absent; inspect the earlier preparation step')
 raise SystemExit(1)
s=path.read_text(errors='replace')
checks={
 'samsung_kernel':bool(re.search(r'Linux version 4\.9\.59\b',s)),
 'second_stage_init':'init second stage started' in s,
 'boot_completed_property':bool(re.search(r'\[sys\.boot_completed\]: \[1\]',s)),
 'system_server_process':bool(re.search(r'QEMU_SYSTEM_SERVER_PIDS\r?\n(?:\d+ ?)+\r?\n',s)),
}
for name,okay in checks.items():print(('PASS ' if okay else 'NOT OBSERVED ')+name)
raise SystemExit(0 if all(checks.values()) else 1)
