#!/usr/bin/env python3
"""Reuse an exact compiled kernel and its executed gates; do not claim a rebuild."""
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys

root,out=map(pathlib.Path,sys.argv[1:]);src=root/'samsung-virt-evidence'
expected={
 'Image':'e0a291e9bda345109d1d0b7ed2c860c9fd182663db5630436b8cb2fba5b9134d',
 'System.map':'5632a6d3c99c4e1c65468ab6a57d8f29c173193e6969783d201b245d386b921a',
 'config.final':'a95a68edf6a516666470ef213ef35db803bdafb455208df214962b5c57ec7a8f',
}
for name,digest in expected.items():
 if hashlib.sha256((src/name).read_bytes()).hexdigest()!=digest:raise SystemExit('Wrong retained kernel artifact '+name)
manifest={n:h for h,n in (line.split() for line in (src/'SHA256SUMS').read_text().splitlines())}
if manifest!=expected:raise SystemExit('Unexpected kernel manifest')
native=root/'system-native-graphics'
if (native/'kernel.sha256').read_text().split()[0]!=expected['Image']:raise SystemExit('Native evidence belongs to another kernel')
subprocess.run([sys.executable,str(pathlib.Path(__file__).with_name('verify.py')),str(native/'serial.log')],check=True)
gates=(root/'dm-gates-evidence/gates-serial.log').read_text()
for marker in ['PASS gate1:','PASS gate2:','PASS gate3:','PASS error propagation:','=== DM DEFAULT KEY GATES EXIT 0 ===']:
 if marker not in gates:raise SystemExit('Missing retained encryption evidence '+marker)
if re.search(r'BUG:|WARNING:|kernel panic|Call trace:',gates,re.I):raise SystemExit('Retained encryption evidence has kernel errors')
out.mkdir(parents=True,exist_ok=True)
for name in list(expected)+['SHA256SUMS','source-hash.txt','graphics-linked-symbols.txt']:
 shutil.copyfile(src/name,out/name)
(out/'artifact-reuse.json').write_text(json.dumps({'run':44402685525,'commit':'6a47d39d71b58b35a6eff936a80053b3f83e3aaf','hashes':expected,'compiled_in_this_run':False,'native_and_encryption_gates':'previously executed; verified here'},indent=2)+'\n')
print('PASS exact Samsung 4.9 kernel and retained native/encryption evidence; REUSED, not recompiled')
