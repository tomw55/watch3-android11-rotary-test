#!/usr/bin/env python3
"""Compile actual patched handle-construction statements with host-only BO stubs."""
import os,pathlib,subprocess,sys,tempfile
src=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
s=(src/'cros_gralloc/cros_gralloc_driver.cc').read_text()
start=s.index('/* Bound the trailing name and the native_handle integer count. */')
end=s.index('hnd->num_planes = num_planes;',start)+len('hnd->num_planes = num_planes;')
fragment=s[start:end]
require='num_ints = (num_bytes - sizeof(native_handle_t)) / sizeof(int) - num_fds;'
assert fragment.count(require)==1 and 'calloc(1, num_bytes)' in fragment
with tempfile.TemporaryDirectory(dir=out) as tmp:
 root=pathlib.Path(tmp);(root/'cutils').mkdir();(root/'cutils/native_handle.h').write_text('typedef struct {int version;int numFds;int numInts;} native_handle_t;\n')
 header=(src/'cros_gralloc/cros_gralloc_handle.h').read_text();(root/'cros_gralloc_handle.h').write_text(header)
 before=r'''
#include <cassert>
#include <climits>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include "cros_gralloc_handle.h"
#define ALIGN(x,a) (((x)+(a)-1)&~((a)-1))
static int destroyed,closed;
static bool no_memory;
static void drv_bo_destroy(void*){destroyed++;}
static int close_stub(int){closed++;return 0;}
static void* calloc_stub(size_t n,size_t size){return no_memory?nullptr:std::calloc(n,size);}
struct Name {size_t n;size_t size()const{return n;}};
struct Descriptor {Name name;};
#define calloc calloc_stub
#define close close_stub
static int construct(size_t name_length,size_t fds,cros_gralloc_handle** output,size_t* length){
 Descriptor d{{name_length}};auto descriptor=&d;size_t num_fds=fds,num_planes=(fds>1?fds-1:1),num_bytes=0,num_ints=0;
 int reserved_region_fd=(fds>1?7:-1);void* bo=nullptr;cros_gralloc_handle* hnd=nullptr;
'''
 after=r'''
 *output=hnd;*length=num_bytes;return 0;
}
#undef calloc
#undef close
int main(){
 for(size_t fds:{size_t(1),size_t(2),size_t(5)})for(size_t n:{size_t(0),size_t(1),size_t(3),size_t(4),size_t(15),size_t(63),size_t(255)}){
  cros_gralloc_handle* h=nullptr;size_t bytes=0;assert(construct(n,fds,&h,&bytes)==0&&h);
  size_t declared=sizeof(native_handle_t)+sizeof(int)*(size_t(h->base.numFds)+size_t(h->base.numInts));
  assert(declared==bytes);assert(h->strides[0]==0&&h->offsets[3]==0);
  void* clone=std::malloc(declared);assert(clone);std::memcpy(clone,h,declared);std::free(clone);std::free(h);
 }
 for(size_t n:{SIZE_MAX,size_t(INT_MAX+uint64_t(100))*sizeof(int)}){
  cros_gralloc_handle* h=nullptr;size_t bytes=0;destroyed=closed=0;
  assert(construct(n,2,&h,&bytes)==-EOVERFLOW);assert(!h&&destroyed==1&&closed==1);
 }
 no_memory=true;destroyed=closed=0;cros_gralloc_handle* h=nullptr;size_t bytes=0;
 assert(construct(0,2,&h,&bytes)==-ENOMEM&&!h&&destroyed==1&&closed==1);
 puts("PASS actual handle construction: 21 layouts, exact clone bounds, zero initialization, overflow and OOM cleanup");
}
'''
 before=before.replace('#include <cassert>','#include <cassert>\n#include <cerrno>\n#include <initializer_list>')
 code=before+fragment+after
 p=root/'probe.cpp';p.write_text(code)
 def compile_and_run(source,binary,env=None):
  subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-fno-omit-frame-pointer','-no-pie','-I'+str(root),str(source),'-o',str(binary)],check=True)
  return subprocess.run([str(binary)],capture_output=True,text=True,env=env)
 env=os.environ.copy();env.setdefault('ASAN_OPTIONS','detect_leaks=1:halt_on_error=1');env['UBSAN_OPTIONS']='halt_on_error=1'
 result=compile_and_run(p,root/'probe',env);print(result.stdout,end='');print(result.stderr,end='',file=sys.stderr)
 if result.returncode:raise SystemExit(result.returncode)
 mutant=root/'mutant.cpp';mutant.write_text(code.replace(require,'num_ints = num_bytes - sizeof(native_handle_t) - num_fds;'))
 result=compile_and_run(mutant,root/'mutant',env)
 if result.returncode==0:raise SystemExit('Unsafe original byte-count mutant was accepted')
 print('PASS mutation: original byte-count expression rejected before cloning')
 (out/'handle-accounting-host.txt').write_text('PASS actual-source construction, ASan/UBSan, overflow/OOM cleanup; original byte-count mutant rejected\n')
