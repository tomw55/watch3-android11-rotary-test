#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/android/binder.h>

/* Minimal native Binder service registration probe against Android 11
 * servicemanager. This is intentionally a standalone process: PID1 cannot
 * impersonate the client while holding the same Binder proc state. */
static void fail(const char *what) { perror(what); _exit(1); }
static void put32(unsigned char *p, size_t *n, uint32_t x) {
    memcpy(p+*n,&x,4); *n+=4;
}
static void utf16(unsigned char *p,size_t *n,const char *s) {
    size_t len=strlen(s);
    put32(p,n,(uint32_t)len);
    for(size_t i=0;i<len;i++) { uint16_t c=(unsigned char)s[i]; memcpy(p+*n,&c,2); *n+=2; }
    uint16_t zero=0; memcpy(p+*n,&zero,2); *n+=2;
    *n=(*n+3)&~(size_t)3;
}
int main(void) {
    setvbuf(stdout,NULL,_IONBF,0);
    int fd=open("/dev/binder",O_RDWR|O_CLOEXEC);
    if(fd<0) fail("register: open binder");
    if(mmap(NULL,128*1024,PROT_READ,MAP_PRIVATE,fd,0)==MAP_FAILED) fail("register: mmap");
    /* Android Parcel::writeInterfaceToken: strict mode, worksource uid,
     * and UTF-16 descriptor. Use a local Binder node for the service. */
    unsigned char data[512]={0};
    size_t n=0;
    put32(data,&n,0);
    put32(data,&n,(uint32_t)-1);
    utf16(data,&n,"android.os.IServiceManager");
    utf16(data,&n,"watch3.test.echo");
    size_t object_offset=n;
    struct flat_binder_object obj={0};
    obj.hdr.type=BINDER_TYPE_BINDER;
    obj.flags=FLAT_BINDER_FLAG_ACCEPTS_FDS;
    obj.binder=(binder_uintptr_t)0x574154434833ULL;
    obj.cookie=(binder_uintptr_t)0x4543484fULL;
    memcpy(data+n,&obj,sizeof(obj)); n+=sizeof(obj);
    put32(data,&n,0); /* allowIsolated=false */
    put32(data,&n,8); /* DUMP_FLAG_PRIORITY_DEFAULT */
    binder_size_t offset=object_offset;
    struct binder_transaction_data tx={0};
    tx.target.handle=0;
    tx.code=3; /* IServiceManager.addService */
    tx.flags=0;
    tx.data_size=n;
    tx.offsets_size=sizeof(offset);
    tx.data.ptr.buffer=(binder_uintptr_t)data;
    tx.data.ptr.offsets=(binder_uintptr_t)&offset;
    struct {uint32_t cmd;struct binder_transaction_data tx;} __attribute__((packed)) request={BC_TRANSACTION,tx};
    struct binder_write_read io={0};
    io.write_size=sizeof(request);
    io.write_buffer=(binder_uintptr_t)&request;
    unsigned char response[4096];
    io.read_size=sizeof(response);
    io.read_buffer=(binder_uintptr_t)response;
    int got_reply=0;
    for(int round=0;round<40;round++) {
        if(ioctl(fd,BINDER_WRITE_READ,&io)<0) fail("register: BINDER_WRITE_READ");
        if(io.write_consumed!=io.write_size) { fprintf(stderr,"FAIL registration short write\n");return 1; }
        for(size_t pos=0;pos<io.read_consumed;) {
            uint32_t cmd;
            if(io.read_consumed-pos<4) return 2;
            memcpy(&cmd,response+pos,4);pos+=4;
            size_t sz=_IOC_SIZE(cmd);
            if(sz>io.read_consumed-pos) return 3;
            if(cmd==BR_REPLY) {
                struct binder_transaction_data reply;
                memcpy(&reply,response+pos,sizeof(reply));
                printf("REGISTER reply bytes=%zu\n",(size_t)reply.data_size);
                if(reply.data_size>=4) {
                    uint32_t exception;
                    memcpy(&exception,(void *)(uintptr_t)reply.data.ptr.buffer,4);
                    printf("REGISTER exception=%d (0x%08x)\n",(int32_t)exception,exception);
                    if(exception==0x80000001U) puts("REGISTER STATUS_UNKNOWN_TRANSACTION: check Android 11 IServiceManager transaction code and Parcel header");
                    if(exception==0) got_reply=1;
                }
                uint32_t freecmd=BC_FREE_BUFFER;
                struct {uint32_t cmd;binder_uintptr_t ptr;} __attribute__((packed)) freebuf={freecmd,reply.data.ptr.buffer};
                struct binder_write_read freeio={.write_size=sizeof(freebuf),.write_buffer=(binder_uintptr_t)&freebuf};
                if(ioctl(fd,BINDER_WRITE_READ,&freeio)<0) fail("register: free reply");
            } else if(cmd==BR_FAILED_REPLY || cmd==BR_DEAD_REPLY) {
                fprintf(stderr,"FAIL registration Binder reply code=%u\n",cmd);
                return 4;
            }
            pos+=sz;
        }
        if(got_reply) break;
        io.write_size=0;
        io.write_consumed=0;
        io.read_consumed=0;
    }
    if(!got_reply) {fprintf(stderr,"FAIL Android 11 test service registration\n");return 5;}
    puts("PASS Android 11 test service registration reply");
    /* Keep local node alive for the separate registry discovery client. */
    for(;;) pause();
}
