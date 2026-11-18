#!/usr/bin/env python3
"""Host ext4 regression fixture only; not Android or SELinux runtime proof."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

if not all(shutil.which(x) for x in ['debugfs','mke2fs']):raise SystemExit('NOT RUN: debugfs/mke2fs required')
pkg=pathlib.Path(sys.argv[1]).resolve();here=pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(dir=pathlib.Path.cwd()) as directory:
 root=pathlib.Path(directory);image=root/'vendor-diagnostic.ext4'
 with image.open('wb') as stream:stream.truncate(64*1024*1024)
 subprocess.run(['mke2fs','-q','-F','-t','ext4',str(image)],check=True)
 def debug(command):
  result=subprocess.run(['debugfs','-w','-R',command,str(image)],check=True,capture_output=True,text=True)
  return result.stdout+result.stderr
 for name in ['/bin','/bin/hw','/lib64','/lib64/hw','/etc','/etc/init','/etc/init/hw','/etc/vintf']:debug('mkdir '+name)
 def write(name,data,label):
  p=root/'payload';p.write_text(data);debug(f'write {p} {name}');debug(f'ea_set {name} security.selinux {label}')
 allocator='u:object_r:hal_graphics_allocator_default_exec:s0'
 files={
 '/bin/hw/android.hardware.graphics.allocator@3.0-service':allocator,
 '/bin/hw/android.hardware.graphics.composer@2.3-service':'u:object_r:hal_graphics_composer_default_exec:s0',
 '/lib64/hw/gralloc.default.so':'u:object_r:vendor_file:s0',
 '/lib64/hw/android.hardware.graphics.mapper@3.0-impl-ranchu.so':'u:object_r:same_process_hal_file:s0',
 '/lib64/hw/hwcomposer.ranchu.so':'u:object_r:vendor_file:s0',
 }
 for name,label in files.items():write(name,'fixture placeholder\n',label)
 # Exact long-label failure: ea_list reports the name/size but omits value.
 old=debug('ea_list /bin/hw/android.hardware.graphics.allocator@3.0-service')
 assert 'security.selinux' in old and allocator not in old
 rc='on early-init\n    setprop ro.hardware.egl emulation\n    setprop ro.hardware.vulkan ranchu\n\non boot\n    setprop ro.hardware.egl emulation\n'
 write('/etc/init/hw/init.ranchu.rc',rc,'u:object_r:vendor_configs_file:s0')
 manifest='<manifest version="1.0" type="device" target-level="5">'
 for kind,version in [('allocator','3.0'),('mapper','3.0'),('composer','2.3')]:manifest+='<hal format="hidl"><name>android.hardware.graphics.'+kind+'</name><transport>hwbinder</transport><version>'+version+'</version></hal>'
 write('/etc/vintf/manifest.xml',manifest+'</manifest>','u:object_r:vendor_configs_file:s0')
 subprocess.run([sys.executable,str(here/'apply-vendor-overlay.py'),str(image),str(pkg),str(root/'evidence')],check=True)
 labels=(root/'evidence/derived-labels.txt').read_text();assert allocator in labels
 updated=(root/'evidence/ranchu.after.rc').read_text();assert updated.count('setprop ro.hardware.egl swiftshader')==2
 assert 'ro.hardware.egl emulation' not in updated
 print('PASS actual ext4 overlay, >=40-byte label regression, exact read-backs and two EGL selections; host fixture only')
