#include <android/binder_ibinder.h>
#include <android/binder_status.h>
#include <android/binder_parcel.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/types.h>
#include <unistd.h>

/* The Android 11 platform exports this symbol from libbinder_ndk, but the
 * standalone NDK omits the platform-only binder_manager.h declaration.
 * Keep the exact C ABI declaration here rather than depending on that header. */
extern "C" binder_status_t AServiceManager_addService(AIBinder *binder, const char *instance);
extern "C" void ABinderProcess_startThreadPool(void);
extern "C" AIBinder *AServiceManager_checkService(const char *instance);
extern "C" int is_selinux_enabled(void);
extern "C" int security_getenforce(void);

/* Native Binder service registration against Android 11 libbinder_ndk. */
static void *on_create(void *args) { return args; }
static void on_destroy(void *args) { (void)args; }
static binder_status_t on_transact(AIBinder *binder, transaction_code_t code,
                                   const AParcel *in, AParcel *out) {
    (void)binder;
    if(code!=FIRST_CALL_TRANSACTION)return STATUS_UNKNOWN_TRANSACTION;
    int32_t sequence=0;int64_t payload=0;
    if(AParcel_readInt32(in,&sequence)!=STATUS_OK ||
       AParcel_readInt64(in,&payload)!=STATUS_OK)return STATUS_BAD_VALUE;
    if(sequence<0 || sequence>=32 || AIBinder_getCallingPid()==getpid())return STATUS_BAD_VALUE;
    int64_t response=payload ^ INT64_C(0x1122334455667788);
    binder_status_t rc=AParcel_writeInt32(out,sequence);
    if(rc==STATUS_OK)rc=AParcel_writeInt64(out,response);
    if(rc==STATUS_OK)rc=AParcel_writeInt32(out,getpid());
    if(rc==STATUS_OK)printf("RPC SERVER sequence=%d caller=%d server=%d\n",sequence,AIBinder_getCallingPid(),getpid());
    return rc;
}
static void show_context() {
    printf("REGISTRAR ID uid=%ld euid=%ld gid=%ld\n", (long)getuid(), (long)geteuid(), (long)getgid());
    int fd = open("/proc/self/attr/current", O_RDONLY);
    if (fd < 0) { perror("REGISTRAR open current SID"); return; }
    char sid[256]; ssize_t n = read(fd, sid, sizeof(sid)-1); close(fd);
    if (n > 0) { sid[n] = 0; printf("REGISTRAR SID=%s\n", sid); }
    else perror("REGISTRAR read current SID");
}
static int client_test() {
    const char *expected=getenv("WATCH3_EXPECT_SERVER_PID");
    long server=expected?strtol(expected,nullptr,10):0;
    if(server<=0 || server==getpid()) { puts("FAIL RPC expected server identity");return 10; }
    AIBinder *remote=AServiceManager_checkService("watch3.test.echo");
    if(!remote || !AIBinder_isRemote(remote)) { puts("FAIL RPC remote registry lookup");return 11; }
    const AIBinder_Class *klass=AIBinder_Class_define("watch3.test.echo",on_create,on_destroy,on_transact);
    if(!klass || !AIBinder_associateClass(remote,klass)) { puts("FAIL RPC class association");return 12; }
    printf("RPC CLIENT pid=%d expected_server=%ld remote=1\n",getpid(),server);
    for(int32_t sequence=0;sequence<32;sequence++) {
        AParcel *request=nullptr,*reply=nullptr;
        int64_t payload=INT64_C(0x0123456700000000)+sequence;
        binder_status_t rc=AIBinder_prepareTransaction(remote,&request);
        if(rc==STATUS_OK)rc=AParcel_writeInt32(request,sequence);
        if(rc==STATUS_OK)rc=AParcel_writeInt64(request,payload);
        if(rc==STATUS_OK)rc=AIBinder_transact(remote,FIRST_CALL_TRANSACTION,&request,&reply,0);
        int32_t returned=-1,pid=-1;int64_t value=0;
        if(rc==STATUS_OK)rc=AParcel_readInt32(reply,&returned);
        if(rc==STATUS_OK)rc=AParcel_readInt64(reply,&value);
        if(rc==STATUS_OK)rc=AParcel_readInt32(reply,&pid);
        AParcel_delete(request);AParcel_delete(reply);
        if(rc!=STATUS_OK || returned!=sequence || value!=(payload ^ INT64_C(0x1122334455667788)) || pid!=server) {
            printf("FAIL RPC round trip sequence=%d status=%d returned=%d server=%d\n",sequence,rc,returned,pid);return 13;
        }
        printf("PASS RPC reply sequence=%d value=%lld server=%d\n",sequence,(long long)value,pid);
    }
    for(int malformed=0;malformed<2;malformed++) {
        AParcel *request=nullptr,*reply=nullptr;
        binder_status_t rc=AIBinder_prepareTransaction(remote,&request);
        if(rc!=STATUS_OK){puts("FAIL RPC negative prepare");return 14;}
        rc=AIBinder_transact(remote,malformed?FIRST_CALL_TRANSACTION:FIRST_CALL_TRANSACTION+1,&request,&reply,0);
        AParcel_delete(request);AParcel_delete(reply);
        binder_status_t wanted=malformed?STATUS_BAD_VALUE:STATUS_UNKNOWN_TRANSACTION;
        if(rc!=wanted){printf("FAIL RPC negative control status=%d expected=%d\n",rc,wanted);return 15;}
        printf("PASS RPC negative control kind=%s status=%d\n",malformed?"truncated":"unknown-code",rc);
    }
    AIBinder_decStrong(remote);
    puts("PASS Android 11 NDK RPC 32 round trips and malformed controls");
    return 0;
}
int main(int argc,char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    show_context();
    int enabled=is_selinux_enabled(), enforcing=security_getenforce();
    printf("REGISTRAR SELinux enabled=%d enforcing=%d\n",enabled,enforcing);
    if(enabled!=1 || enforcing!=1) { puts("FAIL registrar libselinux not enabled and enforcing"); return 6; }
    if(argc==2 && !strcmp(argv[1],"--client"))return client_test();
    if(argc!=1){puts("FAIL unexpected RPC fixture arguments");return 16;}
    const char *name = getenv("WATCH3_TEST_SERVICE_NAME");
    if (!name || !*name) name = "watch3.test.echo";
    printf("REGISTRAR service name=%s\n", name);
    const AIBinder_Class *klass = AIBinder_Class_define(
        "watch3.test.echo", on_create, on_destroy, on_transact);
    if (!klass) { puts("FAIL NDK Binder class creation"); return 2; }
    AIBinder *service = AIBinder_new(klass, nullptr);
    if (!service) { puts("FAIL NDK Binder instance creation"); return 3; }
    binder_status_t rc = AServiceManager_addService(service, name);
    printf("NDK REGISTER status=%d\n", static_cast<int>(rc));
    const char *expect_denied=getenv("WATCH3_EXPECT_DENIED");
    if(expect_denied && !strcmp(expect_denied,"1")) {
        if(rc!=STATUS_PERMISSION_DENIED) { puts("FAIL expected service-manager permission denial"); return 7; }
        puts("PASS Android 11 expected service-manager permission denial");
        return 0;
    }
    if (rc != STATUS_OK) { puts("FAIL NDK Binder service registration"); return 4; }
    puts("PASS Android 11 NDK Binder service registration");
    ABinderProcess_startThreadPool();
    for (;;) pause();
}
