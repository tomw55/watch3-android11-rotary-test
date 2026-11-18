#!/usr/bin/env python3
"""Verify the downloaded three-process HIDL service artifact without executing it."""
import contextlib
import io
import importlib.util
import pathlib
import struct
import sys
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

base = module('base', root / 'tools/verify-hidl-evidence.py')
serial = module('serial', root / 'ci/hidl-service/verify-serial.py')
if len(sys.argv) != 3:
    raise SystemExit('usage: verify-hidl-service-evidence.py ARTIFACT.zip EXPECTED_ZIP_SHA256')
path = pathlib.Path(sys.argv[1])
with contextlib.redirect_stdout(io.StringIO()) as base_log:
    base.verify(path, sys.argv[2])
print(base_log.getvalue().splitlines()[0])
with zipfile.ZipFile(path) as archive:
    prefix = 'samsung-virt-evidence/'
    identities = serial.verify(archive.read(prefix + 'serial.log').decode())
    files = base.unpack_newc(archive.read(prefix + 'initramfs.cpio'))
    for name in ('system/bin/hidl-fixture', 'system/lib64/android.hidl.token@1.0.so'):
        elf = files[name]
        base.require(elf[:4] == b'\x7fELF' and struct.unpack_from('<H', elf, 18)[0] == 183, name)
print('PASS registered HIDL service: 32 exact lifecycles and process receipts; client=%d server=%d manager=%d' % identities)
print('Scope update: custom test instance registration PASSED; normal property-ready discovery, production HALs and hardware NOT RUN')
