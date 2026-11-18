#!/usr/bin/env python3
"""Offline verification of the exact passing servicemanager artifact; no execution."""
import hashlib,pathlib,struct,sys,zipfile
p=pathlib.Path(sys.argv[1])
assert hashlib.sha256(p.read_bytes()).hexdigest()=='27341ce69f75953960c0fc9935163c2b119aca97aae27a38372fe72185672d9b'
z=zipfile.ZipFile(p);prefix='samsung-virt-evidence/'
for line in z.read(prefix+'SHA256SUMS').decode().splitlines():
    digest,name=line.split(maxsplit=1)
    assert hashlib.sha256(z.read(prefix+name)).hexdigest()==digest,name
image=z.read(prefix+'Image');assert image[56:60]==bytes.fromhex('41524d64')
policy=z.read(prefix+'test.policy');magic,n=struct.unpack_from('<II',policy)
version,flags=struct.unpack_from('<II',policy,8+n)
assert magic==0xf97cff8c and version==30 and flags&1 and not flags&4
config=z.read(prefix+'config.final').decode().splitlines()
for flag in ['CONFIG_ANDROID_BINDER_IPC=y','CONFIG_SECURITY_SELINUX=y','CONFIG_DEFAULT_SECURITY="selinux"']:
    assert flag in config,flag
assert 'CONFIG_SECURITY_SMACK=y' not in config
serial=z.read(prefix+'serial.log').decode()
for text in ['Linux version 4.9.59','PASS fixture SELinux policy loaded and readable bytes=3452 enforcing=1','DIAG SELinux binary policy is loaded','REGISTRAR SELinux enabled=1 enforcing=1','REGISTRAR service name=watch3.test.echo','NDK REGISTER status=0','PASS Android 11 NDK Binder service registration','REGISTRAR service name=watch3.test.denied','NDK REGISTER status=-1','PASS Android 11 expected service-manager permission denial','PASS SELinux service-manager negative control','Found 2 services:','watch3.test.echo: [watch3.test.echo]','PASS Android 11 test service discovered in registry']:
    assert text in serial,text
assert not any(x in serial for x in ['FAIL ','Kernel panic','RESULT real Android 11 servicemanager signal='])
# PID 1 intentionally remains in pause(); timeout 124 is the designed capture stop.
assert z.read(prefix+'qemu-exit.txt').decode().strip()=='124'
print('PASS ZIP and payload hashes, ARM64 Image, resolved config, policy v30/MLS/deny-unknown, positive registration, expected denial and registry discovery')
