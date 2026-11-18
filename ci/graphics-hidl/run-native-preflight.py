#!/usr/bin/env python3
import hashlib,pathlib,subprocess,sys
kernel,evidence,out=map(pathlib.Path,sys.argv[1:]);out.mkdir(parents=True,exist_ok=True)
ramdisk=evidence/'samsung-virt-evidence/initramfs.cpio'
# Exact producer artifact verified again against its recorded kernel manifest.
for line in (evidence/'samsung-virt-evidence/SHA256SUMS').read_text().splitlines():
 h,n=line.split(maxsplit=1)
 if hashlib.sha256((evidence/'samsung-virt-evidence'/n).read_bytes()).hexdigest()!=h:raise SystemExit('Native reference digest mismatch '+n)
cmd=['timeout','100','qemu-system-aarch64','-machine','virt,gic-version=2','-cpu','cortex-a57','-accel','tcg','-smp','2','-m','1024','-nodefaults','-display','none','-monitor','none','-serial','stdio','-no-reboot','-device','virtio-gpu-pci','-kernel',str(kernel),'-initrd',str(ramdisk),'-append','console=ttyAMA0 rdinit=/init rootfstype=ramfs ignore_loglevel audit=1 panic=1']
with (out/'serial.log').open('w') as log:result=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
(out/'qemu-exit.txt').write_text(str(result.returncode)+'\n')
if result.returncode!=124:raise SystemExit('Unexpected native capture exit '+str(result.returncode))
(out/'kernel.sha256').write_text(hashlib.sha256(kernel.read_bytes()).hexdigest()+'  Image\n')
subprocess.run([sys.executable,str(pathlib.Path(__file__).with_name('verify.py')),str(out/'serial.log')],check=True)
