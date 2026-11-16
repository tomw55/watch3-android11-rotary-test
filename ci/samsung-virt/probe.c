#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <linux/android/binder.h>

static void need(int ok, const char *stage)
{
    if (!ok) {
        fprintf(stderr, "FAIL %s (errno=%d)\n", stage, errno);
        _exit(1);
    }
}

static void exchange(int fd, uint32_t send, struct binder_transaction_data *tx,
                     uint32_t wanted, struct binder_transaction_data *result)
{
    unsigned char request[sizeof(send) + sizeof(*tx)], input[4096];
    size_t n = 0;
    if (send) {
        memcpy(request, &send, sizeof(send));
        memcpy(request + sizeof(send), tx, sizeof(*tx));
        n = sizeof(request);
    }
    for (;;) {
        struct binder_write_read io = {
            .write_size = n, .write_buffer = (uintptr_t)request,
            .read_size = sizeof(input), .read_buffer = (uintptr_t)input,
        };
        int rc = ioctl(fd, BINDER_WRITE_READ, &io);
        if (rc < 0 && errno == EINTR)
            continue;
        need(rc == 0 && io.write_consumed == n, "BINDER_WRITE_READ");
        n = 0;
        for (size_t pos = 0; pos < io.read_consumed;) {
            uint32_t cmd;
            need(io.read_consumed - pos >= sizeof(cmd), "short Binder command");
            memcpy(&cmd, input + pos, sizeof(cmd));
            pos += sizeof(cmd);
            need(io.read_consumed - pos >= _IOC_SIZE(cmd), "short Binder payload");
            if (cmd == wanted) {
                if (result)
                    memcpy(result, input + pos, sizeof(*result));
                return;
            }
            need(cmd == BR_NOOP || cmd == BR_TRANSACTION_COMPLETE, "unexpected Binder command");
            pos += _IOC_SIZE(cmd);
        }
    }
}

static int binder_open(void)
{
    int fd = open("/dev/binder", O_RDWR | O_CLOEXEC);
    need(fd >= 0, "open binder");
    need(mmap(NULL, 128 * 1024, PROT_READ, MAP_PRIVATE, fd, 0) != MAP_FAILED, "mmap binder");
    return fd;
}

static void binder_test(void)
{
    int ready[2], done[2], status;
    char byte;
    uint64_t token = 0x1133557799bbddffULL;
    pid_t server, client = getpid();
    need(pipe(ready) == 0 && pipe(done) == 0, "pipe");
    server = fork();
    need(server >= 0, "fork");
    if (server == 0) {
        close(ready[0]);
        close(done[1]);
        int fd = binder_open(), zero = 0;
        struct binder_transaction_data incoming, reply = {0};
        need(ioctl(fd, BINDER_SET_CONTEXT_MGR, &zero) == 0, "set context manager");
        uint32_t enter = BC_ENTER_LOOPER;
        struct binder_write_read registration = {
            .write_size = sizeof(enter), .write_buffer = (uintptr_t)&enter,
        };
        need(ioctl(fd, BINDER_WRITE_READ, &registration) == 0 &&
             registration.write_consumed == sizeof(enter), "BC_ENTER_LOOPER");
        puts("Binder server entered looper");
        need(write(ready[1], "R", 1) == 1, "signal ready");
        exchange(fd, 0, NULL, BR_TRANSACTION, &incoming);
        need(incoming.sender_pid == client && incoming.code == 1 &&
             incoming.data_size == sizeof(token) && incoming.offsets_size == 0 &&
             memcmp((void *)(uintptr_t)incoming.data.ptr.buffer, &token, sizeof(token)) == 0,
             "server request validation");
        puts("Binder server verified request");
        token = ~token;
        reply.data_size = sizeof(token);
        reply.data.ptr.buffer = (uintptr_t)&token;
        exchange(fd, BC_REPLY, &reply, BR_TRANSACTION_COMPLETE, NULL);
        need(read(done[0], &byte, 1) == 1, "client acknowledgement");
        _exit(0);
    }
    close(ready[1]);
    close(done[0]);
    need(read(ready[0], &byte, 1) == 1, "server readiness");
    int fd = binder_open();
    struct binder_transaction_data request = {0}, reply;
    request.code = 1;
    request.data_size = sizeof(token);
    request.data.ptr.buffer = (uintptr_t)&token;
    puts("Binder client sending transaction");
    exchange(fd, BC_TRANSACTION, &request, BR_REPLY, &reply);
    token = ~token;
    need(reply.data_size == sizeof(token) && reply.offsets_size == 0 &&
         memcmp((void *)(uintptr_t)reply.data.ptr.buffer, &token, sizeof(token)) == 0,
         "client reply validation");
    need(write(done[1], "D", 1) == 1, "acknowledge reply");
    need(waitpid(server, &status, 0) == server && WIFEXITED(status) && !WEXITSTATUS(status),
         "server exit");
    close(fd);
    close(ready[0]);
    close(done[1]);
    printf("PASS Binder transaction client=%d server=%d\n", client, server);
}

static int policy_value(const char *path)
{
    char value[32] = {0};
    int fd = open(path, O_RDONLY);
    need(fd >= 0 && read(fd, value, sizeof(value) - 1) > 0, path);
    close(fd);
    return atoi(value);
}

static void policy_test(void)
{
    static char policy[65536];
    int fd, load;
    ssize_t size;
    need(mount("selinuxfs", "/sys/fs/selinux", "selinuxfs", 0, NULL) == 0, "mount selinuxfs");
    printf("SELinux policy maximum=%d\n", policy_value("/sys/fs/selinux/policyvers"));
    need(policy_value("/sys/fs/selinux/enforce") == 1, "enforcing before load");
    fd = open("/allowed", O_RDONLY);
    need(fd >= 0, "prepolicy allowed file");
    close(fd);
    fd = open("/denied", O_RDONLY);
    need(fd >= 0, "prepolicy denied file");
    close(fd);
    fd = open("/test.policy", O_RDONLY);
    need(fd >= 0, "open test policy");
    size = read(fd, policy, sizeof(policy));
    need(size > 0 && size < (ssize_t)sizeof(policy), "read test policy");
    close(fd);
    load = open("/sys/fs/selinux/load", O_WRONLY);
    need(load >= 0 && write(load, policy, size) == size, "load policy v30");
    close(load);
    need(policy_value("/sys/fs/selinux/enforce") == 1, "enforcing after load");
    fd = open("/allowed", O_RDONLY);
    need(fd >= 0, "policy allow");
    close(fd);
    errno = 0;
    fd = open("/denied", O_RDONLY);
    need(fd < 0 && errno == EACCES, "policy denial");
    puts("PASS SELinux v30 load enforcing allow and denial");
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    puts("PASS guest init started");
    need(mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) == 0, "mount devtmpfs");
    need(mount("sysfs", "/sys", "sysfs", 0, NULL) == 0, "mount sysfs");
    const char *nodes[] = {"/dev/binder", "/dev/hwbinder", "/dev/vndbinder"};
    for (size_t i = 0; i < sizeof(nodes) / sizeof(nodes[0]); i++) {
        struct stat st;
        struct binder_version version;
        int fd;
        need(stat(nodes[i], &st) == 0 && S_ISCHR(st.st_mode), nodes[i]);
        fd = open(nodes[i], O_RDWR);
        need(fd >= 0 && ioctl(fd, BINDER_VERSION, &version) == 0 &&
             version.protocol_version == BINDER_CURRENT_PROTOCOL_VERSION, nodes[i]);
        printf("PASS %s protocol=%d\n", nodes[i], version.protocol_version);
        close(fd);
    }
    binder_test();
    policy_test();
    puts("PASS all guest checks");
    for (;;) pause();
}
