#!/usr/bin/env python3
"""Overlay verified public graphics components on an explicitly disposable ext4 copy."""
import hashlib,importlib.util,pathlib,re,subprocess,sys,tempfile
image,pkg,out=map(pathlib.Path,sys.argv[1:]);image=image.resolve();pkg=pkg.resolve();out=out.resolve();out.mkdir(parents=True,exist_ok=True)
if not image.is_file() or image.name!='vendor-diagnostic.ext4':raise SystemExit('Refusing image outside the disposable vendor-diagnostic.ext4 path')
spec=importlib.util.spec_from_file_location('config',pathlib.Path(__file__).with_name('vendor-config.py'));config=importlib.util.module_from_spec(spec);spec.loader.exec_module(config)
log=[]
def debug(command):
 p=subprocess.run(['debugfs','-w','-R',command,str(image)],capture_output=True,text=True);log.append(command+'\n'+p.stdout+p.stderr)
 (out/'vendor-overlay.log').write_text('\n'.join(log))
 return p.stdout+p.stderr
with tempfile.TemporaryDirectory(dir=out) as tmp:
 root=pathlib.Path(tmp)
 def dump(path,label):
  p=root/label;debug(f'dump {path} {p}')
  if not p.is_file() or p.stat().st_size==0:raise RuntimeError('Missing existing image file '+path)
  return p.read_bytes()
 def context(path):
  # e2fsprogs 1.46.5 ea_list suppresses values >=40 bytes. Most HAL
  # executable labels exceed this. Read the actual xattr, not pretty output.
  debug('ea_list '+path)
  value=root/('label-'+hashlib.sha256(path.encode()).hexdigest()[:16])
  debug(f'ea_get -f {value} {path} security.selinux')
  if not value.is_file() or not value.stat().st_size:raise RuntimeError('Cannot read existing SELinux label: '+path)
  return config.selinux_label(value.read_bytes())
 # Derive domain entrypoint/file labels from the actual old package, not guesses.
 labels={
  'allocator':context('/bin/hw/android.hardware.graphics.allocator@3.0-service'),
  'composer':context('/bin/hw/android.hardware.graphics.composer@2.3-service'),
  'library':context('/lib64/hw/gralloc.default.so'),
  'config':context('/etc/init/hw/init.ranchu.rc'),
  'manifest':context('/etc/vintf/manifest.xml'),
  'mapper':context('/lib64/hw/android.hardware.graphics.mapper@3.0-impl-ranchu.so'),
  'composer-library':context('/lib64/hw/hwcomposer.ranchu.so'),
 }
 def write(path,data,mode,label):
  source=root/'payload';source.write_bytes(data)
  debug('rm '+path);debug(f'write {source} {path}')
  debug(f'set_inode_field {path} uid 0');debug(f'set_inode_field {path} gid 0');debug(f'set_inode_field {path} mode {mode}')
  debug(f'ea_set {path} security.selinux {label}')
  got=dump(path,'readback');
  if got!=data:raise RuntimeError('Read-back mismatch '+path)
  if context(path)!=label:raise RuntimeError('Label mismatch '+path)
 # All package members have already been hash-checked by the workflow.
 for file in sorted((pkg/'vendor').rglob('*')):
  if not file.is_file():continue
  relative=file.relative_to(pkg/'vendor');path='/'+str(relative)
  if relative.parts[:2]==('bin','hw'):
   key='allocator' if 'allocator' in file.name else 'composer';mode='0100755'
  elif relative.parts[:2]==('etc','init'):key='config';mode='0100644'
  elif relative.parts[0]=='lib64':
   key='mapper' if 'mapper@' in file.name else ('composer-library' if file.name.startswith('hwcomposer.') else 'library');mode='0100644'
  else:raise RuntimeError('Unexpected package path '+str(relative))
  write(path,file.read_bytes(),mode,labels[key])
 original=dump('/etc/vintf/manifest.xml','manifest.xml').decode()
 updated=config.manifest(original);(out/'manifest.before.xml').write_text(original);(out/'manifest.after.xml').write_text(updated)
 write('/etc/vintf/manifest.xml',updated.encode(),'0100644',labels['manifest'])
 original=dump('/etc/init/hw/init.ranchu.rc','ranchu.rc').decode()
 updated=config.ranchu_rc(original);(out/'ranchu.before.rc').write_text(original);(out/'ranchu.after.rc').write_text(updated)
 write('/etc/init/hw/init.ranchu.rc',updated.encode(),'0100644',labels['config'])
 # Replace only conflicting old graphics service definitions in this copy.
 for path in ['/etc/init/android.hardware.graphics.allocator@3.0-service.rc','/etc/init/android.hardware.graphics.composer@2.3-service.rc']:
  debug('rm '+path)
 (out/'derived-labels.txt').write_text('\n'.join(k+' '+v for k,v in labels.items())+'\n')
(out/'vendor-overlay.log').write_text('\n'.join(log))
print('PASS disposable vendor graphics overlay read-backs and inherited labels; runtime NOT RUN')
