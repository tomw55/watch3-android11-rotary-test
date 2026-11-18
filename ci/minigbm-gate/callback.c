#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <hardware/gralloc.h>
#include <cutils/native_handle.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <dirent.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
/* Compile this C fixture without the C++-only cros header; the handle fields
 * used below are copied by memcpy from the separately pinned layout. */
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL %s:%d: %s errno=%d (%s)\n",__FILE__,__LINE__,#x,errno,strerror(errno)); return 1; } } while(0)
#define SW (GRALLOC_USAGE_SW_READ_OFTEN | GRALLOC_USAGE_SW_WRITE_OFTEN)
struct wire { int nf,ni,w,h,stride; int ints[256]; };
static const unsigned char first[4]={0x24,0x69,0xb2,0xff};
static const unsigned char second[4]={0xa3,0x36,0x71,0xff};
static const unsigned char third[4]={0x57,0xc4,0x2a,0xff};
static int pixels(void *p,int w,int h,int stride,const unsigned char color[4],int write) {
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
        unsigned char *v=(unsigned char*)p+((size_t)y*stride+x)*4;
        if(write)memcpy(v,color,4);else if(memcmp(v,color,4))return -1;
    }
    return 0;
}
static int module_open(const gralloc_module_t **m,alloc_device_t **d,int allocator) {
    const hw_module_t *hw=NULL;
    int rc=hw_get_module(GRALLOC_HARDWARE_MODULE_ID,&hw);
    if(rc || !hw || strcmp(hw->id,GRALLOC_HARDWARE_MODULE_ID))return -1;
    *m=(const gralloc_module_t*)hw;
    printf("MODULE name=%s id=%s pid=%d\n",hw->name,hw->id,getpid());
    return allocator?gralloc_open(hw,d):0;
}
static int transmit(int fd,buffer_handle_t h,int w,int height,int stride) {
    if(h->numFds!=1 || h->numInts<1 || h->numInts>256)return -1;
    struct wire wire={.nf=h->numFds,.ni=h->numInts,.w=w,.h=height,.stride=stride};
    memcpy(wire.ints,h->data+h->numFds,(size_t)h->numInts*sizeof(int));
    struct iovec io={&wire,sizeof wire};
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control={0};
    struct msghdr msg={.msg_iov=&io,.msg_iovlen=1,.msg_control=control.bytes,.msg_controllen=sizeof control};
    struct cmsghdr *c=CMSG_FIRSTHDR(&msg);c->cmsg_level=SOL_SOCKET;c->cmsg_type=SCM_RIGHTS;c->cmsg_len=CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c),h->data,sizeof(int));
    return sendmsg(fd,&msg,MSG_NOSIGNAL)==sizeof wire?0:-1;
}
static native_handle_t *receive_handle(int fd,struct wire *wire) {
    struct iovec io={wire,sizeof *wire};
    union { struct cmsghdr align; char bytes[CMSG_SPACE(16*sizeof(int))]; } control={0};
    struct msghdr msg={.msg_iov=&io,.msg_iovlen=1,.msg_control=control.bytes,.msg_controllen=sizeof control};
    ssize_t n=recvmsg(fd,&msg,MSG_CMSG_CLOEXEC);
    int descriptors[16],count=0;
    for(struct cmsghdr*c=CMSG_FIRSTHDR(&msg);c;c=CMSG_NXTHDR(&msg,c)) {
        if(c->cmsg_level!=SOL_SOCKET || c->cmsg_type!=SCM_RIGHTS || c->cmsg_len<CMSG_LEN(0))continue;
        size_t bytes=c->cmsg_len-CMSG_LEN(0);
        for(size_t i=0;i+sizeof(int)<=bytes;i+=sizeof(int)) {
            int x;memcpy(&x,(char*)CMSG_DATA(c)+i,sizeof x);
            if(count<16)descriptors[count++]=x;else close(x);
        }
    }
    native_handle_t *h=NULL;
    if(n==sizeof *wire && !(msg.msg_flags&(MSG_TRUNC|MSG_CTRUNC)) && count==1 &&
       wire->nf==1 && wire->ni>0 && wire->ni<=256 && wire->w>0 && wire->h>0 &&
       wire->w<=8192 && wire->h<=8192 && wire->stride>=wire->w && wire->stride<=16384) {
        h=native_handle_create(1,wire->ni);
        if(h) { h->data[0]=descriptors[0];memcpy(h->data+1,wire->ints,(size_t)wire->ni*sizeof(int));count=0; }
    }
    for(int i=0;i<count;i++)close(descriptors[i]);
    return h;
}
struct display { uint32_t connector,crtc; drmModeModeInfo mode; };
static int get_display(int fd,struct display *out) {
    drmModeRes *r=drmModeGetResources(fd);if(!r)return -1;
    int found=0;
    for(int i=0;i<r->count_connectors&&!found;i++) {
        drmModeConnector*c=drmModeGetConnector(fd,r->connectors[i]);if(!c)continue;
        if(c->connection==DRM_MODE_CONNECTED && c->count_modes) {
            for(int e=0;e<c->count_encoders&&!found;e++) {
                drmModeEncoder*enc=drmModeGetEncoder(fd,c->encoders[e]);if(!enc)continue;
                for(int j=0;j<r->count_crtcs && j<32;j++)if(enc->possible_crtcs&(1u<<j)) {
                    out->connector=c->connector_id;out->crtc=r->crtcs[j];out->mode=c->modes[0];found=1;break;
                }
                drmModeFreeEncoder(enc);
            }
        }
        drmModeFreeConnector(c);
    }
    drmModeFreeResources(r);return found?0:-1;
}
static int client(int fd) {
    struct wire w;native_handle_t*h=receive_handle(fd,&w);CHECK(h);close(fd);
    const gralloc_module_t*m=NULL;alloc_device_t*unused=NULL;
    CHECK(module_open(&m,&unused,0)==0);
    CHECK(m->registerBuffer(m,h)==0);
    void*p=NULL;CHECK(m->lock(m,h,SW,0,0,w.w,w.h,&p)==0);
    CHECK(pixels(p,w.w,w.h,w.stride,first,0)==0);
    CHECK(pixels(p,w.w,w.h,w.stride,second,1)==0);
    CHECK(m->unlock(m,h)==0);
    puts("PASS exec client registerBuffer lock verify write unlock");
    int card=open("/dev/dri/card0",O_RDWR|O_CLOEXEC);CHECK(card>=0);
    drmVersionPtr version=drmGetVersion(card);CHECK(version && !strcmp(version->name,"virtio_gpu"));drmFreeVersion(version);
    struct display d;CHECK(get_display(card,&d)==0);
    CHECK(w.w==d.mode.hdisplay && w.h==d.mode.vdisplay);
    uint32_t gem=0,fb=0;CHECK(drmPrimeFDToHandle(card,h->data[0],&gem)==0);
    uint32_t handles[4]={gem},pitches[4]={(uint32_t)w.stride*4},offsets[4]={0};
    /* HAL RGBA_8888 on little endian is DRM ABGR8888. No private-handle cast. */
    CHECK(drmModeAddFB2(card,w.w,w.h,DRM_FORMAT_ABGR8888,handles,pitches,offsets,&fb,0)==0);
    CHECK(drmModeSetCrtc(card,d.crtc,fb,0,0,&d.connector,1,&d.mode)==0);
    drmModeCrtc*c=drmModeGetCrtc(card,d.crtc);CHECK(c && c->buffer_id==fb && c->mode_valid);drmModeFreeCrtc(c);
    puts("PASS imported ADDFB2 legacy modeset and GETCRTC");
    puts("SCANOUT_READY first a33671");fflush(NULL);sleep(12);
    CHECK(m->lock(m,h,SW,0,0,w.w,w.h,&p)==0);
    CHECK(pixels(p,w.w,w.h,w.stride,third,1)==0);
    CHECK(m->unlock(m,h)==0);
    CHECK(drmModeDirtyFB(card,fb,NULL,0)==0);
    puts("SCANOUT_READY second 57c42a");fflush(NULL);sleep(12);
    CHECK(drmModeSetCrtc(card,d.crtc,0,0,0,NULL,0,NULL)==0);
    CHECK(drmModeRmFB(card,fb)==0);
    struct drm_gem_close close_gem={.handle=gem};CHECK(drmIoctl(card,DRM_IOCTL_GEM_CLOSE,&close_gem)==0);close(card);
    CHECK(m->unregisterBuffer(m,h)==0);
    CHECK(native_handle_close(h)==0);CHECK(native_handle_delete(h)==0);
    puts("PASS exec client unregisterBuffer and DRM teardown");return 0;
}
static void close_except(int keep) {
    DIR*d=opendir("/proc/self/fd");if(!d)_exit(120);int directory=dirfd(d);
    struct dirent*e;while((e=readdir(d))) { char*end;long n=strtol(e->d_name,&end,10);if(!*end&&n>=3&&n!=keep&&n!=directory)close((int)n); }
    closedir(d);
}
int main(int argc,char**argv) {
    setvbuf(stdout,NULL,_IOLBF,0);
    if(argc==3&&!strcmp(argv[1],"--client"))return client(atoi(argv[2]));
    CHECK(argc==1);
    int card=open("/dev/dri/card0",O_RDWR|O_CLOEXEC);CHECK(card>=0);
    struct display d;CHECK(get_display(card,&d)==0);close(card);
    printf("DISPLAY connector=%u crtc=%u mode=%ux%u\n",d.connector,d.crtc,d.mode.hdisplay,d.mode.vdisplay);
    const gralloc_module_t*m=NULL;alloc_device_t*a=NULL;CHECK(module_open(&m,&a,1)==0);
    buffer_handle_t h=NULL;int stride=0;
    int gpu=a->alloc(a,64,64,HAL_PIXEL_FORMAT_RGBA_8888,GRALLOC_USAGE_HW_TEXTURE|GRALLOC_USAGE_HW_RENDER,&h,&stride);
    printf("OBSERVED texture/render allocation result=%d (unsupported in CPU-only profile)\n",gpu);CHECK(gpu!=0 && !h);
    CHECK(a->alloc(a,d.mode.hdisplay,d.mode.vdisplay,HAL_PIXEL_FORMAT_RGBA_8888,GRALLOC_USAGE_HW_COMPOSER|SW,&h,&stride)==0);
    CHECK(h && h->numFds==1 && stride>=d.mode.hdisplay);
    void*p=NULL;CHECK(m->lock(m,h,SW,0,0,d.mode.hdisplay,d.mode.vdisplay,&p)==0);
    CHECK(pixels(p,d.mode.hdisplay,d.mode.vdisplay,stride,first,1)==0);
    CHECK(m->unlock(m,h)==0);puts("PASS allocator alloc lock write unlock");
    int sockets[2];CHECK(socketpair(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0,sockets)==0);
    fflush(NULL);pid_t child=fork();CHECK(child>=0);
    if(!child) {
        close(sockets[0]);close_except(sockets[1]);
        if(fcntl(sockets[1],F_SETFD,0))_exit(121);
        char n[24];snprintf(n,sizeof n,"%d",sockets[1]);
        char*args[]={"/system/bin/gralloc-gate","--client",n,NULL};execv(args[0],args);_exit(122);
    }
    close(sockets[1]);CHECK(transmit(sockets[0],h,d.mode.hdisplay,d.mode.vdisplay,stride)==0);close(sockets[0]);
    int status;CHECK(waitpid(child,&status,0)==child);CHECK(WIFEXITED(status)&&!WEXITSTATUS(status));
    CHECK(m->lock(m,h,GRALLOC_USAGE_SW_READ_OFTEN,0,0,d.mode.hdisplay,d.mode.vdisplay,&p)==0);
    CHECK(pixels(p,d.mode.hdisplay,d.mode.vdisplay,stride,third,0)==0);CHECK(m->unlock(m,h)==0);
    CHECK(a->free(a,h)==0);CHECK(gralloc_close(a)==0);
    puts("PASS GRALLOC_CALLBACK_GATE CPU-only RGBA and clean-process lifecycle");return 0;
}
