#!/usr/bin/env python3
"""Compile the actual patched allocation/map functions with ioctl/mmap interception."""
import pathlib, subprocess, sys
mg, drm, fixture, out = map(pathlib.Path, sys.argv[1:])
def function(text, name):
    import re
    m=re.search(r'static [^;{}]*\b'+name+r'\([^;{}]*\)\s*\{',text)
    if not m:raise RuntimeError(name)
    begin=m.start();depth=1;i=m.end()
    while depth:
        if text[i]=='{':depth+=1
        if text[i]=='}':depth-=1
        i+=1
    return text[begin:i]
src=(mg/'virtio_gpu.c').read_text()
body='\n'.join(function(src,n) for n in ['translate_format','qemu49_rgb_create','virtio_virgl_bo_map'])
preamble=r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include "drv_priv.h"
#include "helpers.h"
#include "virgl_hw.h"
#include "virtgpu_drm.h"
#include "qemu49_layout.h"
#define PIPE_TEXTURE_2D 2
static int fail_ioctl, calls;
static struct drm_virtgpu_resource_create recorded;
static int mapped_fd; static uint64_t mapped_offset; static size_t mapped_length;
static unsigned char memory[8];
int drmIoctl(int fd, unsigned long request, void *data) {
    assert(fd==71); calls++;
    if(fail_ioctl){errno=EIO;return -1;}
    if(request==DRM_IOCTL_VIRTGPU_RESOURCE_CREATE){
        struct drm_virtgpu_resource_create*r=data;recorded=*r;r->bo_handle=123;return 0;
    }
    assert(request==DRM_IOCTL_VIRTGPU_MAP);
    struct drm_virtgpu_map*m=data;assert(m->handle==123);m->offset=0x9000;return 0;
}
static void *intercept_mmap(void *addr,size_t length,int prot,int flags,int fd,off_t offset) {
    assert(!addr && prot==(PROT_READ|PROT_WRITE) && flags==MAP_SHARED);
    mapped_fd=fd;mapped_offset=offset;mapped_length=length;return memory;
}
int drv_get_prot(uint32_t flags){assert(flags==(BO_MAP_READ|BO_MAP_WRITE));return PROT_READ|PROT_WRITE;}
void drv_log_prefix(const char*p,const char*f,int l,const char*fmt,...){(void)p;(void)f;(void)l;(void)fmt;}
#define mmap intercept_mmap
'''
main=r'''
int main(void) {
 struct driver d={.fd=71};struct bo b={.drv=&d};
 b.meta.width=64;b.meta.height=65;
 assert(qemu49_rgb_create(&b,64,65,DRM_FORMAT_ABGR8888)==0);
 assert(calls==1 && recorded.target==2 && recorded.width==64 && recorded.height==128);
 assert(recorded.stride==256 && recorded.size==32768 && recorded.depth==1 && recorded.array_size==1);
 assert(recorded.format==VIRGL_FORMAT_R8G8B8A8_UNORM);
 assert(b.handles[0].u32==123 && b.meta.num_planes==1 && b.meta.strides[0]==256);
 assert(b.meta.width==64 && b.meta.height==65 && b.meta.total_size==32768);
 struct vma v={0};assert(virtio_virgl_bo_map(&b,&v,0,BO_MAP_READ|BO_MAP_WRITE)==memory);
 assert(mapped_fd==71 && mapped_offset==0x9000 && mapped_length==32768 && v.length==32768);
 assert(qemu49_rgb_create(&b,65,65,DRM_FORMAT_ABGR8888)==0);
 assert(recorded.width==128 && recorded.height==128 && recorded.stride==512 && recorded.size==65536);
 fail_ioctl=1;struct bo original=b;
 assert(qemu49_rgb_create(&b,64,65,DRM_FORMAT_ABGR8888)==-EIO);
 assert(!memcmp(&b,&original,sizeof b));
 v.length=0;assert(virtio_virgl_bo_map(&b,&v,0,BO_MAP_READ|BO_MAP_WRITE)==MAP_FAILED);
 int previous=calls;
 assert(qemu49_rgb_create(&b,64,65,DRM_FORMAT_NV12)==-EINVAL && calls==previous);
 assert(qemu49_rgb_create(&b,UINT32_MAX,65,DRM_FORMAT_ABGR8888)==-EOVERFLOW && calls==previous);
 puts("PASS actual patched create/map: resource geometry, DRM fd, error propagation and rejected formats");
}
'''
p=out/'backend-test.c';p.write_text(preamble+body+main)
flags=['-std=c11','-D_GNU_SOURCE=1','-Wall','-Wextra','-Werror','-Wno-unused-parameter',f'-I{mg}',f'-I{drm}',f'-I{drm}/include/drm',f'-I{fixture}']
for suffix,extra in [('',[]),('-sanitized',['-fsanitize=address,undefined'])]:
    binary=out/('backend-test'+suffix)
    subprocess.run(['gcc',*flags,*extra,str(p),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)

# Compilable negative controls must be detected by the same executable tests.
for label,bad in [
    ('wrong-resource-width',body.replace('rc.width = stride / 4;', 'rc.width = width;')),
    ('ignored-create-error',body.replace('return -errno;', 'return 0;',1)),
    ('wrong-mmap-fd',body.replace('MAP_SHARED, bo->drv->fd,', 'MAP_SHARED, 0,')),
]:
    assert bad!=body,label
    source=out/(label+'.c');source.write_text(preamble+bad+main)
    binary=out/label
    subprocess.run(['gcc',*flags,str(source),'-o',str(binary)],check=True)
    result=subprocess.run([str(binary)],capture_output=True,text=True)
    (out/(label+'.log')).write_text(result.stdout+result.stderr)
    assert result.returncode!=0,label
    print('PASS mutation detected:',label,flush=True)
