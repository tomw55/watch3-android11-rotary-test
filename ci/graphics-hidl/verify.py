#!/usr/bin/env python3
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
for marker in ['PASS fixture SELinux policy loaded and readable','enforcing=1','PASS HIDL transport baseline','PASS graphics allocator registered','PASS GRAPHICS exec importer','PASS GRAPHICS allocator mapper buffer lifecycle','PASS graphics integration gate','PASS GRAPHICS real mapper 2.1 interface']:
 if marker not in s:raise SystemExit('Missing '+marker)
if re.search(r'FAIL |Kernel panic|Call trace:',s):raise SystemExit('Guest failure')
ids=re.findall(r'GRAPHICS CLIENT pid=(\d+) server=(\d+) manager=(\d+) remote_allocator=1 local_mapper=1',s)
assert len(ids)==1 and len(set(ids[0]))==3
cases=re.findall(r'PASS GRAPHICS allocation case=(\d+) width=(\d+) height=(\d+) stride=(\d+)',s)
assert len(cases)==3 and [(int(c),int(w),int(h)) for c,w,h,_ in cases]==[(0,16,16),(1,63,3),(2,65,7)]
assert all(int(stride)>=int(w) for _,w,_,stride in cases)
print('PASS actual allocator/mapper lifecycle and exec-isolated pixels; client/server/manager='+str(ids[0]))

assert re.findall(r'PASS GRAPHICS mapper21 transport fds=1 ints=35 case=(\d+)',s)==['0','1','2']
