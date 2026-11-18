#!/usr/bin/env python3
"""Host-only negative controls for the downloaded HIDL artifact verifier."""
import hashlib
import importlib.util
import pathlib
import sys
import tempfile
import zipfile

spec = importlib.util.spec_from_file_location('verify', pathlib.Path(__file__).with_name('verify-hidl-evidence.py'))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
path = pathlib.Path(sys.argv[1])
expected = 'c8d23ee4755c6355a8460d7df01f46e136739d22bcb9008008646d192fc54190'
v.verify(path, expected)
try:
    v.verify(path, '0' * 64)
except ValueError as e:
    assert 'ZIP digest' in str(e)
else:
    raise AssertionError('invalid ZIP digest accepted')
with zipfile.ZipFile(path) as original:
    entries = {n: original.read(n) for n in original.namelist()}
key = 'samsung-virt-evidence/serial.log'
markers = (b'PASS fixture SELinux policy loaded and readable', b'PASS HIDL manager list', b'PASS HIDL self lookup ping interfaceChain', b'PASS HIDL transport baseline')
with tempfile.TemporaryDirectory() as tmp:
    for marker in markers:
        changed = entries[key].replace(marker, b'REMOVED MARKER')
        assert changed != entries[key]
        candidate = pathlib.Path(tmp) / 'candidate.zip'
        with zipfile.ZipFile(candidate, 'w') as output:
            for n, data in entries.items():
                output.writestr(n, changed if n == key else data)
        try:
            v.verify(candidate, hashlib.sha256(candidate.read_bytes()).hexdigest())
        except ValueError as e:
            assert 'missing runtime evidence' in str(e), e
        else:
            raise AssertionError('missing marker accepted: ' + marker.decode())
print('PASS digest negative control and four independent missing-runtime-marker controls')
