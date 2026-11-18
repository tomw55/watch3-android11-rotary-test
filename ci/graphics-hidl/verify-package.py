#!/usr/bin/env python3
import hashlib,pathlib,struct,sys
root=pathlib.Path(sys.argv[1]);manifest=root/'servicemanager-binary/composer-package-SHA256SUMS';pkg=root/'servicemanager-binary/composer-package'
if hashlib.sha256(manifest.read_bytes()).hexdigest()!='deb83ec7be5e3ebd4c6a1fcc2d3f1bb274966cc5f1ddc6b69ab41ae81bea242e':raise SystemExit('Unexpected component manifest')
expected=set()
for line in manifest.read_text().splitlines():
 digest,name=line.split(maxsplit=1);p=pathlib.PurePosixPath(name)
 if p.is_absolute() or '..' in p.parts or p.parts[0]!='vendor':raise SystemExit('Unsafe component path')
 f=pkg/pathlib.Path(*p.parts);expected.add(f)
 if f.is_symlink() or hashlib.sha256(f.read_bytes()).hexdigest()!=digest:raise SystemExit('Component digest mismatch '+name)
 if f.read_bytes()[:4]==b'\x7fELF' and struct.unpack_from('<H',f.read_bytes(),18)[0]!=183:raise SystemExit('Non-ARM64 payload')
actual={p for p in pkg.rglob('*') if p.is_file()}
if actual!=expected or len(expected)!=10:raise SystemExit('Unexpected package members')
print('PASS exact 10-file public graphics package from run 44379899922 / 7441a1eb')
