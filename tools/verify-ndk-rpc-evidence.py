#!/usr/bin/env python3
"""Independently verify the exact passing RPC artifact without executing it."""
import hashlib,pathlib,re,sys,zipfile
p=pathlib.Path(sys.argv[1]);assert hashlib.sha256(p.read_bytes()).hexdigest()=='216ac21a1bd43ac379ea6439ab5f6c1d8fbfeeb530ce5426c8bc1c69b9b36076'
z=zipfile.ZipFile(p);prefix='samsung-virt-evidence/'
for line in z.read(prefix+'SHA256SUMS').decode().splitlines():
    h,n=line.split(maxsplit=1);assert hashlib.sha256(z.read(prefix+n)).hexdigest()==h,n
s=z.read(prefix+'serial.log').decode()
c=re.findall(r'RPC CLIENT pid=(\d+) expected_server=(\d+) remote=1',s);assert len(c)==1
client,server=map(int,c[0]);assert client!=server and client>0 and server>0
responses=re.findall(r'PASS RPC reply sequence=(\d+) value=(\d+) server=(\d+)',s)
assert len(responses)==32 and [int(r[0])for r in responses]==list(range(32))
for sequence,value,pid in responses:
    assert int(pid)==server and int(value)==((0x0123456700000000+int(sequence))^0x1122334455667788)
received=re.findall(r'RPC SERVER sequence=(\d+) caller=(\d+) server=(\d+)',s)
assert len(received)==32 and [int(r[0])for r in received]==list(range(32))
assert all(int(c)==client and int(p)==server for _,c,p in received)
for marker in ['Linux version 4.9.59','REGISTRAR SELinux enabled=1 enforcing=1','PASS SELinux service-manager negative control','PASS RPC negative control kind=unknown-code status=-74','PASS RPC negative control kind=truncated status=-22','PASS registered Android service request reply gate','PASS Android 11 test service discovered in registry']:
    assert marker in s,marker
assert 'FAIL ' not in s and 'Kernel panic' not in s
print(f'PASS exact artifact and manifests; 32 independently calculated replies; client={client} server={server}; server receives; malformed controls; enforcing-policy and discovery checks')
