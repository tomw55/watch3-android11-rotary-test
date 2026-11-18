#!/usr/bin/env python3
"""Strict host-only tests. All uinput system calls are intercepted in C."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser=argparse.ArgumentParser()
parser.add_argument('--out',type=Path,required=True)
parser.add_argument('--samsung-archive',type=Path)
args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
here=Path(__file__).resolve().parent;android=here.parent.parent
os.environ.setdefault('ASAN_OPTIONS','detect_leaks=1:halt_on_error=1')
os.environ.setdefault('UBSAN_OPTIONS','halt_on_error=1:print_stacktrace=1')
compiler=os.environ.get('CC','cc');flags=['-std=c11','-Wall','-Wextra','-Werror','-pedantic','-O1','-g']

def run(command,label,*,cwd=android,expected_failure=False):
    result=subprocess.run([str(x) for x in command],cwd=cwd,capture_output=True,text=True)
    (out/(label+'.log')).write_text('COMMAND '+json.dumps([str(x) for x in command])+'\nRETURN_CODE '+str(result.returncode)+'\n'+result.stdout+result.stderr)
    if expected_failure:
        if result.returncode==0:raise RuntimeError('Undetected mutation: '+label)
    elif result.returncode:raise RuntimeError(label+' failed; inspect '+str(out/(label+'.log')))
    return result

profile=json.loads((android/'physical/watch3-r08-observation.json').read_text())
assert profile['identity']=={'name':'tizen_detent','bus':6,'vendor':1,'product':1,'version':256}
assert int(profile['capabilities']['event_mask_hex'],16)==(1<<0)|(1<<1)|(1<<2)
assert int(profile['capabilities']['relative_mask_hex'],16)==(1<<0)|(1<<1)|(1<<8)
assert profile['capabilities']['key_codes']==[0x110]
assert profile['capabilities']['modalias']=='input:b0006v0001p0001e0100-e0,1,2,k110,r0,1,8,amlsfw'
assert profile['tizen_compositor_direction']=={'clockwise':1,'anticlockwise':-1}
assert profile['source_contract']['clockwise_active_hall_cycle']==[1,2,4,1]
assert profile['source_contract']['anticlockwise_active_hall_cycle']==[1,4,2,1]
for name in ['check-discovery.py','test-delivery.py']:
    assert '/dev/input/event18' not in (android/name).read_text()
assert hashlib.sha256((android/'fixture/tizen_detent.idc').read_bytes()).hexdigest()=='ae2f9cdd2750a277fea33b2f82185b0bbe7113ad5efa44cb1fde272e8e99cf95'
for manifest in ['fixture.sha256','rotary-sources.sha256','physical/SHA256SUMS']:
    run(['sha256sum','-c',manifest],manifest.replace('.','-').replace('/','-'))
run(['python3','test-discovery.py'],'discovery')
run(['python3','test-delivery-host.py'],'delivery-parser')
fixture=here/'ioctl-physical.c'
for label,extra in [('strict',[]),('sanitized',['-fsanitize=address,undefined','-fno-omit-frame-pointer'])]:
    binary=out/('ioctl-'+label)
    run([compiler,*flags,*extra,fixture,'-o',binary],label+'-compile')
    for case,options in [('default',[]),('reverse',['--reverse']),('wrong-name',['--wrong-name'])]:
        run([binary,*options],label+'-'+case)
    run([compiler,*flags,*extra,'-DTEST_PROBE',fixture,'-o',binary],label+'-probe-compile')
    run([binary],label+'-probe')

source=(here.parent/'rotary-uinput.c').read_text()
header=(android/'fixture/tizen-detent-profile.h').read_text()
mutations=[
 ('vendor','header','#define TIZEN_DETENT_VENDOR 0x0001','#define TIZEN_DETENT_VENDOR 0x0000'),
 ('version','header','#define TIZEN_DETENT_VERSION 0x0100','#define TIZEN_DETENT_VERSION 0x0001'),
 ('wheel','source','            ioctl(fd, UI_SET_RELBIT, REL_WHEEL) < 0 ||\n',''),
 ('rel-y','source','            ioctl(fd, UI_SET_RELBIT, REL_Y) < 0 ||\n',''),
 ('button','source','            ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0 ||\n',''),
 ('direction','source','? sign : -sign','? -sign : sign'),
 ('hall-mask','source','(~hall_state) & 0x07','hall_state & 0x07'),
]
for label,target,before,after in mutations:
    root=out/('mutant-'+label);(root/'rotary').mkdir(parents=True,exist_ok=True);(root/'fixture').mkdir(exist_ok=True)
    changed=header if target=='header' else source
    assert changed.count(before)==1,(label,'stale mutation')
    changed=changed.replace(before,after)
    unit=root/'rotary/rotary-uinput.c'
    unit.write_text(changed if target=='source' else source)
    (root/'fixture/tizen-detent-profile.h').write_text(changed if target=='header' else header)
    for mode,extra in [('strict',[]),('sanitized',['-fsanitize=address,undefined','-fno-omit-frame-pointer'])]:
        binary=root/('test-'+mode)
        run([compiler,*flags,*extra,'-DROTARY_GENERATOR_SOURCE="'+str(unit)+'"',fixture,'-o',binary],label+'-'+mode+'-compile')
        run([binary],label+'-'+mode+'-detected',expected_failure=True)
print('PASS actual generator and probe: ordered ioctl arguments, full identity, repeated/reversed frames, REL_X-only control; strict C11 + ASan/UBSan')
print('PASS seven mutations detected in both strict and sanitized builds; every mutant compiled first')
print('PASS dynamic event-number, capability/identity parser, CW log-isolation and byte-identical IDC checks')
if args.samsung_archive:
    result=run(['python3',here/'test-samsung-source.py',args.samsung_archive.resolve()],'samsung-source')
    print(result.stdout.strip())
else:print('NOT RUN hash-pinned Samsung source extraction: pass --samsung-archive to exercise the actual decoder/work functions')
result={'host_fixture':'PASS','mutations':14,'android_guest_updated_identity':'NOT RUN','watch_raw_evdev':'NOT RUN','watch_android':'NOT RUN','hardware_bringup':'NO-GO','compiler':subprocess.check_output([compiler,'--version'],text=True).splitlines()[0],'asan_options':os.environ['ASAN_OPTIONS'],'samsung_source':'PASS' if args.samsung_archive else 'NOT RUN'}
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
for path in out.glob('mutant-*'):shutil.rmtree(path)
with (out/'SHA256SUMS').open('w') as manifest:
    for path in sorted(out.iterdir()):
        if path.is_file() and path.name!='SHA256SUMS':manifest.write(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name+'\n')
