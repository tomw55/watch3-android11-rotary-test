#!/usr/bin/env python3
"""Compile actual adapter and dimming sources; only I/O callbacks are mocked."""
import argparse,json,os,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--panel-dir',required=True);p.add_argument('--output',required=True)
a=p.parse_args();panel=pathlib.Path(a.panel_dir).resolve();out=pathlib.Path(a.output).resolve();out.mkdir(parents=True,exist_ok=True)
test=pathlib.Path(__file__).resolve().parent/'test-calibration.c'
flags=['gcc','-std=c11','-Wall','-Wextra','-Werror','-pedantic','-funsigned-char','-I'+str(panel)]
env=dict(os.environ,ASAN_OPTIONS='detect_leaks=0',UBSAN_OPTIONS='halt_on_error=1')
results=[]
def run(name,cmd,negative=False):
    r=subprocess.run(list(map(str,cmd)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (out/(name+'.log')).write_text('$ '+' '.join(map(str,cmd))+'\n'+r.stdout+'\nEXIT '+str(r.returncode)+'\n')
    ok=r.returncode!=0 if negative else r.returncode==0
    results.append(dict(test=name,status='PASS' if ok else 'FAIL',exit=r.returncode))
    if not ok:raise RuntimeError(name+'\n'+r.stdout)
    print('PASS',name)
for label,sanitizers in [('strict',[]),('sanitized',['-g','-fsanitize=address,undefined','-fno-omit-frame-pointer'])]:
    exe=out/label
    run(label+'-compile',flags+sanitizers+[panel/'noblesse-calibration.c',panel/'noblesse-dimming.c',test,'-Wl,--wrap=nd_create','-o',exe])
    run(label+'-run',[exe])

# Actual source mutants, not separate protocol models.
source=(panel/'noblesse-calibration.c').read_text()
mutants=[('short-read','return (size_t)ret == len ? 0 : -EMSGSIZE;','return 0;'),
         ('identity','if (memcmp(local.id, r->expected_id, sizeof(local.id)))','if (0)'),
         ('keyoff','if (!ret && cleanup) { ret = cleanup; stage = NC_KEY_OFF; }','/* mutant ignores key-off failure */'),
         ('offset','local.base_vbias = vbias[7];','local.base_vbias = vbias[6];')]
for name,old,new in mutants:
    assert source.count(old)==1,(name,source.count(old))
    path=out/(name+'.c');path.write_text(source.replace(old,new));exe=out/(name+'-mutant')
    # A missing exact-length check leaves len unused. Retain a use in that mutant.
    if name=='short-read':path.write_text(path.read_text().replace('return 0;\n}', '(void)len; return 0;\n}',1))
    run(name+'-mutant-compile',flags+[path,panel/'noblesse-dimming.c',test,'-Wl,--wrap=nd_create','-o',exe])
    run(name+'-mutant-detected',[exe],negative=True)
(out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS actual-source host fixture; legacy DSIM backend and hardware runtime NOT RUN/BLOCKED')
