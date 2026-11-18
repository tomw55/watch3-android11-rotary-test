#!/usr/bin/env python3
"""Observe real guest callback/scanout results; QMP does not supply guest pixels."""
import json, pathlib, socket, subprocess, sys, time
from PIL import Image
kernel,ramdisk,out=map(pathlib.Path,sys.argv[1:]);out=out.resolve();sockpath=out/'qmp.sock'
cmd=['qemu-system-aarch64','-machine','virt,gic-version=2','-cpu','cortex-a57','-accel','tcg','-smp','2','-m','1024','-nodefaults','-display','none','-monitor','none','-serial','stdio','-no-reboot','-device','virtio-gpu-pci','-kernel',str(kernel),'-initrd',str(ramdisk),'-append','console=ttyAMA0 earlycon=pl011,mmio32,0x09000000 rdinit=/init panic=1','-qmp',f'unix:{sockpath},server=on,wait=off']
(out/'qemu-command.json').write_text(json.dumps(cmd,indent=2))
with (out/'serial.log').open('w') as log:
    p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT)
    try:
        deadline=time.monotonic()+180
        while not sockpath.exists():
            if p.poll() is not None or time.monotonic()>deadline:raise RuntimeError('QMP unavailable')
            time.sleep(.1)
        s=socket.socket(socket.AF_UNIX);s.connect(str(sockpath));stream=s.makefile('rwb',buffering=0)
        s.settimeout(10);hello=json.loads(stream.readline());assert 'QMP'in hello
        def qmp(command,args=None):
            stream.write((json.dumps({'execute':command,**({'arguments':args} if args else {})})+'\n').encode())
            while True:
                r=json.loads(stream.readline())
                if 'error'in r:raise RuntimeError(r)
                if 'return'in r:return r
        qmp('qmp_capabilities')
        observed=[]
        for label,color in [('first',(0xa3,0x36,0x71)),('second',(0x57,0xc4,0x2a))]:
            marker='SCANOUT_READY '+label
            while marker not in (out/'serial.log').read_text(errors='replace'):
                if p.poll() is not None or time.monotonic()>deadline:raise RuntimeError('Missing '+marker)
                time.sleep(.1)
            time.sleep(.5) # Allow asynchronous device commands to execute before QMP capture.
            filename=out/(label+'.ppm');qmp('screendump',{'filename':str(filename)})
            im=Image.open(filename).convert('RGB');counts=im.getcolors(im.width*im.height)
            matching=sum(n for n,c in counts if c==color)
            ratio=matching/(im.width*im.height)
            observed.append({'case':label,'expected_rgb':color,'size':im.size,'matching_fraction':ratio})
            (out/'scanout-results.json').write_text(json.dumps(observed,indent=2))
            assert ratio>.99, f'{label}: scanout pixel mismatch {observed[-1]}'
            print('PASS host-observed scanout',label,observed[-1],flush=True)
        p.wait(timeout=max(1,deadline-time.monotonic()))
        serial=(out/'serial.log').read_text(errors='replace')
        for marker in ['PASS allocator alloc lock write unlock','PASS exec client registerBuffer lock verify write unlock','PASS imported ADDFB2 legacy modeset and GETCRTC','PASS exec client unregisterBuffer and DRM teardown','PASS GRALLOC_CALLBACK_GATE','PASS GRALLOC_GUEST']:
            assert marker in serial,marker
        assert not any(x in serial for x in ['FAIL ','Kernel panic','Call trace:'])
        print('PASS actual Bionic gralloc callbacks, exec-isolated import and two scanout patterns')
    finally:
        if p.poll() is None:p.kill();p.wait()
        sockpath.unlink(missing_ok=True)
