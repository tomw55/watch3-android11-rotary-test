#!/usr/bin/env python3
"""Verify the exact passing API-30 callback artifact without booting anything."""
import hashlib, io, json, pathlib, stat, sys, zipfile
from PIL import Image
archive=pathlib.Path(sys.argv[1])
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='e5d82a9381fbc6b17e497daa17e3b770e9663c2392a853cc04474c80838d4d47'
z=zipfile.ZipFile(archive)
for line in z.read('SHA256SUMS').decode().splitlines():
    expected,name=line.split(maxsplit=1)
    assert hashlib.sha256(z.read(name.removeprefix('./'))).hexdigest()==expected,name
b=z.read('initramfs.cpio');position=0;members={};inodes={}
while position+110<=len(b):
    header=b[position:position+110];assert header[:6]==b'070701'
    values=[int(header[i:i+8],16)for i in range(6,110,8)]
    ino,mode,uid,gid,nlink,mtime,size,major,minor,rmajor,rminor,namesize,check=values
    assert namesize>=1 and position+110+namesize<=len(b)
    name=b[position+110:position+110+namesize-1].decode().removeprefix('./')
    position=(position+110+namesize+3)&~3
    assert position+size<=len(b)
    data=b[position:position+size];position=(position+size+3)&~3
    if name=='TRAILER!!!':break
    key=(major,minor,ino);members[name]=(key,mode,data)
    if data:inodes[key]=data
for line in z.read('guest-SHA256SUMS').decode().splitlines():
    expected,name=line.split(maxsplit=1)
    key,mode,data=members[name.removeprefix('./')];data=data or inodes.get(key,b'')
    assert stat.S_ISREG(mode) and hashlib.sha256(data).hexdigest()==expected,name
    assert data[:4]==b'\x7fELF' and int.from_bytes(data[18:20],'little')==183,name
assert members['vendor/lib64/hw/gralloc.default.so'][2]==b'gralloc.minigbm.so'
for filename,rgb in [('first.ppm',(163,54,113)),('second.ppm',(87,196,42))]:
    im=Image.open(io.BytesIO(z.read(filename))).convert('RGB')
    assert im.size==(1024,768)
    assert im.getcolors(im.width*im.height)==[(1024*768,rgb)],filename
serial=z.read('serial.log').decode()
for marker in ['PASS allocator alloc lock write unlock','PASS exec client registerBuffer lock verify write unlock','PASS imported ADDFB2 legacy modeset and GETCRTC','PASS exec client unregisterBuffer and DRM teardown','PASS GRALLOC_CALLBACK_GATE','PASS GRALLOC_GUEST','reboot: Power down']:
    assert marker in serial,marker
assert not any(t in serial for t in ['FAIL ','Kernel panic','Call trace:','Oops:','BUG:'])
assert 'pid=60' in serial and 'pid=61' in serial
print('PASS artifact ZIP, internal manifests, actual ARM64 cpio payloads, alias, callback markers and every scanout pixel')
