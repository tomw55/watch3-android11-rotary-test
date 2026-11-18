#!/usr/bin/env python3
"""Extract a minimal genuine API-30 Bionic dependency closure, never run it here."""
import hashlib, pathlib, re, shutil, struct, subprocess, sys, urllib.request, zipfile
out, repo = map(pathlib.Path, sys.argv[1:])
archive = out/'api30.zip'
urllib.request.urlretrieve('https://dl.google.com/android/repository/sys-img/google_apis/arm64-v8a-30_r16.zip', archive)
with archive.open('rb') as f:
    digest=hashlib.sha256()
    for chunk in iter(lambda:f.read(4*1024*1024),b''):digest.update(chunk)
    assert digest.hexdigest() == '097c2808a738ba4c19038b75a085750dd61a7178c0234b14ac5f8270dd8cff54'
with zipfile.ZipFile(archive) as z:
    names=[n for n in z.namelist() if n.endswith('/system.img')]
    assert len(names)==1
    with z.open(names[0]) as src, (out/'system.disk').open('wb') as dst: shutil.copyfileobj(src,dst)
raw=out/'system.disk'
with raw.open('rb') as f: magic=f.read(4)
if magic==bytes.fromhex('3aff26ed'):
    subprocess.run(['simg2img',str(raw),str(out/'system.raw')],check=True);raw=out/'system.raw'
with raw.open('rb') as f:
    f.seek(512);hdr=f.read(92);assert hdr[:8]==b'EFI PART'
    lba=struct.unpack_from('<Q',hdr,72)[0]; count,esize=struct.unpack_from('<II',hdr,80)
    assert count<=256 and 128<=esize<=1024
    f.seek(lba*512); entries=f.read(count*esize)
    matches=[]
    for i in range(count):
        e=entries[i*esize:(i+1)*esize]
        if e[56:128].decode('utf-16-le').rstrip('\0')=='super':matches.append(struct.unpack_from('<QQ',e,32))
    assert len(matches)==1
    start,last=matches[0];assert last>=start and (last+1)*512<=raw.stat().st_size
    f.seek(start*512)
    with (out/'super.raw').open('wb') as dst:
        remaining=(last-start+1)*512
        while remaining:
            chunk=f.read(min(4*1024*1024,remaining));assert chunk;dst.write(chunk);remaining-=len(chunk)
subprocess.run([sys.executable,str(repo/'ci/arm64-reference/extract-logical.py'),str(out/'super.raw'),'system',str(out/'system.ext4')],check=True)
guest=out/'guest'; lib=guest/'system/lib64'; vndk=out/'src/vndk'
pending=['linker64']+[p.name for p in lib.glob('*.so')]+['gralloc-gate','gralloc.minigbm.so']; seen=set()
files={'linker64':guest/'system/bin/linker64','gralloc-gate':guest/'system/bin/gralloc-gate','gralloc.minigbm.so':guest/'vendor/lib64/hw/gralloc.minigbm.so'}
for name in pending:
    if name in seen:continue
    seen.add(name);dst=files.get(name,lib/name)
    if not dst.exists():
        paths=['/system/bin/bootstrap/linker64','/bin/bootstrap/linker64'] if name=='linker64' else [f'/system/lib64/{name}',f'/lib64/{name}',f'/system/lib64/bootstrap/{name}',f'/lib64/bootstrap/{name}']
        for path in paths:
            subprocess.run(['debugfs','-R',f'dump {path} {dst}',str(out/'system.ext4')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if dst.exists() and dst.read_bytes()[:4]==b'\x7fELF':break
            dst.unlink(missing_ok=True)
        if not dst.exists():
            for kind in ['vndk-sp','vndk-core']:
                p=subprocess.run(['git','-C',str(vndk),'show',f'95168a4aced97deb4966ef6f10c8fd6dee9f1582:arm64/arch-arm64-armv8-a/shared/{kind}/{name}'],capture_output=True)
                if p.returncode==0 and p.stdout[:4]==b'\x7fELF':dst.write_bytes(p.stdout);break
    if not dst.exists():raise RuntimeError(f'Missing real Android dependency: {name}')
    hdr=subprocess.check_output(['readelf','-h',str(dst)],text=True);assert 'AArch64' in hdr
    deps=subprocess.check_output(['readelf','-d',str(dst)],text=True)
    pending.extend(re.findall(r'Shared library: \[([^]]+)\]',deps))
    print('RUNTIME',name,hashlib.sha256(dst.read_bytes()).hexdigest(),flush=True)
