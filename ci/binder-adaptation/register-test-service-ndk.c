#include <android/binder_ibinder.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <android/binder_status.h>
#include <stdio.h>
#include <unistd.h>

/* Genuine Android 11 libbinder_ndk service registration. */
static void *on_create(void *args) { return args; }
static void on_destroy(void *args) { (void)args; }
static binder_status_t on_transact(AIBinder *binder, transaction_code_t code,
                                   const AParcel *in, AParcel *out) {
    (void)binder; (void)code; (void)in; (void)out;
    return STATUS_UNKNOWN_TRANSACTION;
}
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const AIBinder_Class *klass = AIBinder_Class_define(
        "watch3.test.echo", on_create, on_destroy, on_transact);
    if (!klass) { puts("FAIL NDK Binder class creation"); return 2; }
    AIBinder *service = AIBinder_new(klass, NULL);
    if (!service) { puts("FAIL NDK Binder instance creation"); return 3; }
    binder_exception_t rc = AServiceManager_addService(service, "watch3.test.echo");
    printf("NDK REGISTER status=%d\\n", (int)rc);
    if (rc != EX_NONE) { puts("FAIL NDK Binder service registration"); return 4; }
    puts("PASS Android 11 NDK Binder service registration");
    ABinderProcess_startThreadPool();
    for (;;) pause();
}
