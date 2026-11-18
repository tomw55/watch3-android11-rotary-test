#include <android/binder_ibinder.h>
#include <android/binder_status.h>
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
extern "C" int is_selinux_enabled(void);
extern "C" int security_getenforce(void);

/* Native Binder service registration against Android 11 libbinder_ndk. */
static void *on_create(void *args) { return args; }
static void on_destroy(void *args) { (void)args; }
static binder_status_t on_transact(AIBinder *binder, transaction_code_t code,
                                   const AParcel *in, AParcel *out) {
    (void)binder; (void)code; (void)in; (void)out;
    return STATUS_UNKNOWN_TRANSACTION;
}
static void show_context() {
    printf("REGISTRAR ID uid=%ld euid=%ld gid=%ld\n", (long)getuid(), (long)geteuid(), (long)getgid());
    int fd = open("/proc/self/attr/current", O_RDONLY);
    if (fd < 0) { perror("REGISTRAR open current SID"); return; }
    char sid[256]; ssize_t n = read(fd, sid, sizeof(sid)-1); close(fd);
    if (n > 0) { sid[n] = 0; printf("REGISTRAR SID=%s\n", sid); }
    else perror("REGISTRAR read current SID");
}
int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    show_context();
    int enabled=is_selinux_enabled(), enforcing=security_getenforce();
    printf("REGISTRAR SELinux enabled=%d enforcing=%d\n",enabled,enforcing);
    if(enabled!=1 || enforcing!=1) { puts("FAIL registrar libselinux not enabled and enforcing"); return 6; }
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
