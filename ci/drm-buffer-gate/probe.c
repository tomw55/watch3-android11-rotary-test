#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <drm/drm_fourcc.h>
#include <drm/virtgpu_drm.h>
#include <linux/virtio_gpu.h>

struct buffer_info {
    uint32_t width, height, pitch, reserved;
    uint64_t size;
};

static int send_buffer(int socket, int fd, const struct buffer_info *info)
{
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
    struct iovec iov = { .iov_base = (void *)info, .iov_len = sizeof(*info) };
    struct msghdr message = { .msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(fd));
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(fd));
    return sendmsg(socket, &message, MSG_NOSIGNAL) == (ssize_t)sizeof(*info) ? 0 : -1;
}

/* Reject malformed packets and close all received descriptors on rejection. */
static int receive_buffer(int socket, struct buffer_info *info)
{
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(2 * sizeof(int))]; } control = {0};
    struct iovec iov = { .iov_base = info, .iov_len = sizeof(*info) };
    struct msghdr message = { .msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    int received[2], count = 0, invalid = 0;
    ssize_t length = recvmsg(socket, &message, MSG_CMSG_CLOEXEC);
    if (length < 0)
        return -1;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&message); c; c = CMSG_NXTHDR(&message, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS ||
            c->cmsg_len < CMSG_LEN(0)) {
            invalid = 1;
            continue;
        }
        size_t bytes = c->cmsg_len - CMSG_LEN(0);
        if (bytes % sizeof(int))
            invalid = 1;
        for (size_t i = 0; i < bytes / sizeof(int); i++) {
            int fd;
            memcpy(&fd, (char *)CMSG_DATA(c) + i * sizeof(fd), sizeof(fd));
            if (count < 2)
                received[count++] = fd;
            else {
                close(fd);
                invalid = 1;
            }
        }
    }
    if (invalid || length != sizeof(*info) || count != 1 ||
        (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC))) {
        for (int i = 0; i < count; i++)
            close(received[i]);
        errno = EPROTO;
        return -1;
    }
    return received[0];
}

static int host_self_test(void)
{
    int sockets[2], pipefd[2], fd;
    struct buffer_info sent = {64, 64, 256, 0, 16384}, got = {0};
    struct stat a, b;
    if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sockets) || pipe(pipefd))
        return 1;
    if (send_buffer(sockets[0], pipefd[0], &sent))
        return 1;
    fd = receive_buffer(sockets[1], &got);
    if (fd < 0 || memcmp(&sent, &got, sizeof(sent)) ||
        fstat(fd, &a) || fstat(pipefd[0], &b) || a.st_ino != b.st_ino ||
        !(fcntl(fd, F_GETFD) & FD_CLOEXEC))
        return 1;
    close(fd);
    if (send(sockets[0], "x", 1, 0) != 1 ||
        receive_buffer(sockets[1], &got) != -1 || errno != EPROTO)
        return 1;
    if (send(sockets[0], &sent, sizeof(sent), 0) != sizeof(sent) ||
        receive_buffer(sockets[1], &got) != -1 || errno != EPROTO)
        return 1;
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(pipefd))]; } control = {0};
    struct iovec iov = { .iov_base = &sent, .iov_len = sizeof(sent) };
    struct msghdr message = { .msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(pipefd));
    memcpy(CMSG_DATA(cmsg), pipefd, sizeof(pipefd));
    if (sendmsg(sockets[0], &message, 0) != sizeof(sent) ||
        receive_buffer(sockets[1], &got) != -1 || errno != EPROTO)
        return 1;
    close(pipefd[0]);
    close(pipefd[1]);
    close(sockets[0]);
    close(sockets[1]);
    puts("PASS host SCM_RIGHTS transfer, CLOEXEC, short packet, missing-fd and extra-fd rejection");
    return 0;
}

static int verify_driver(int fd)
{
    char name[64] = {0};
    struct drm_version version = { .name_len = sizeof(name) - 1, .name = name };
    if (ioctl(fd, DRM_IOCTL_VERSION, &version))
        return -1;
    printf("DRM driver=%s version=%d.%d.%d\n", name, version.version_major,
           version.version_minor, version.version_patchlevel);
    if (strcmp(name, "virtio_gpu")) {
        errno = ENODEV;
        return -1;
    }
    return 0;
}

static unsigned char pattern(size_t offset, unsigned char seed)
{
    return (unsigned char)((offset * 17u + offset / 251u) ^ seed);
}

static int verify_bytes(const unsigned char *bytes, size_t size, unsigned char seed)
{
    for (size_t i = 0; i < size; i++)
        if (bytes[i] != pattern(i, seed)) {
            fprintf(stderr, "FAIL data mismatch offset=%zu\n", i);
            return -1;
        }
    return 0;
}

static int child_import(int socket)
{
    struct buffer_info info = {0};
    struct drm_prime_handle imported = {0};
    struct drm_mode_map_dumb map = {0};
    struct drm_mode_fb_cmd2 fb = {0};
    struct drm_gem_close close_handle = {0};
    int shared = -1, card = -1, result = 1;
    void *address = MAP_FAILED;
    shared = receive_buffer(socket, &info);
    if (shared < 0 || info.width != 64 || info.height != 64 ||
        info.pitch < 256 || info.size < (uint64_t)info.pitch * info.height ||
        info.size > 16 * 1024 * 1024 || info.reserved) {
        perror("FAIL receive/validate buffer");
        goto out;
    }
    card = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (card < 0 || verify_driver(card)) {
        perror("FAIL child DRM open");
        goto out;
    }
    imported.fd = shared;
    if (ioctl(card, DRM_IOCTL_PRIME_FD_TO_HANDLE, &imported)) {
        perror("FAIL cross-process PRIME_FD_TO_HANDLE");
        goto out;
    }
    printf("PASS child PRIME import handle=%u\n", imported.handle);
    map.handle = imported.handle;
    if (ioctl(card, DRM_IOCTL_MODE_MAP_DUMB, &map)) {
        perror("FAIL imported MAP_DUMB");
        goto out;
    }
    address = mmap(NULL, info.size, PROT_READ | PROT_WRITE, MAP_SHARED, card, map.offset);
    if (address == MAP_FAILED || verify_bytes(address, info.size, 0x35)) {
        perror("FAIL imported DRM-fd mapping/pattern");
        goto out;
    }
    puts("PASS child imported DRM-fd mmap and parent pattern");
    for (size_t i = 0; i < info.size; i++)
        ((unsigned char *)address)[i] = pattern(i, 0xa7);
    if (msync(address, info.size, MS_SYNC))
        printf("OBSERVED child DRM mapping msync errno=%d (%s)\n", errno, strerror(errno));
    atomic_thread_fence(memory_order_seq_cst);
    fb.width = info.width;
    fb.height = info.height;
    /* Android RGBA_8888 byte order on little-endian ARM64. */
    fb.pixel_format = DRM_FORMAT_ABGR8888;
    fb.handles[0] = imported.handle;
    fb.pitches[0] = info.pitch;
    if (ioctl(card, DRM_IOCTL_MODE_ADDFB2, &fb)) {
        perror("FAIL imported ADDFB2");
        goto out;
    }
    printf("PASS child ADDFB2 framebuffer=%u format=ABGR8888 pitch=%u\n", fb.fb_id, info.pitch);
    result = 0;
out:
    if (fb.fb_id && ioctl(card, DRM_IOCTL_MODE_RMFB, &fb.fb_id)) {
        perror("FAIL RMFB");
        result = 1;
    }
    if (address != MAP_FAILED && munmap(address, info.size))
        result = 1;
    if (imported.handle) {
        close_handle.handle = imported.handle;
        if (ioctl(card, DRM_IOCTL_GEM_CLOSE, &close_handle))
            result = 1;
    }
    if (shared >= 0)
        close(shared);
    if (card >= 0)
        close(card);
    close(socket);
    return result;
}

static int probe(void)
{
    struct drm_mode_create_dumb create = { .height = 64, .width = 64, .bpp = 32 };
    struct drm_mode_map_dumb map = {0};
    struct drm_prime_handle exported = { .flags = DRM_CLOEXEC | DRM_RDWR };
    struct drm_mode_destroy_dumb destroy = {0};
    int card = -1, render = -1, shared = -1, sockets[2] = {-1, -1}, result = 1;
    int status = 0;
    pid_t child = -1;
    void *address = MAP_FAILED, *direct = MAP_FAILED;
    for (int i = 0; i < 100; i++) {
        card = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
        if (card >= 0)
            break;
        usleep(50000);
    }
    if (card < 0 || verify_driver(card)) {
        perror("FAIL primary DRM node/driver");
        goto out;
    }
    render = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (render < 0 || verify_driver(render)) {
        perror("FAIL render DRM node/driver");
        goto out;
    }
    puts("PASS primary and render nodes opened");
    close(render);
    render = -1;
    if (ioctl(card, DRM_IOCTL_MODE_CREATE_DUMB, &create)) {
        perror("FAIL CREATE_DUMB");
        goto out;
    }
    if (!create.handle || create.pitch < 256 ||
        create.size < (uint64_t)create.pitch * create.height || create.size > 16 * 1024 * 1024) {
        fprintf(stderr, "FAIL invalid dumb-buffer geometry\n");
        goto out;
    }
    map.handle = create.handle;
    if (ioctl(card, DRM_IOCTL_MODE_MAP_DUMB, &map)) {
        perror("FAIL MAP_DUMB");
        goto out;
    }
    address = mmap(NULL, create.size, PROT_READ | PROT_WRITE, MAP_SHARED, card, map.offset);
    if (address == MAP_FAILED) {
        perror("FAIL parent DRM-fd mmap");
        goto out;
    }
    for (size_t i = 0; i < create.size; i++)
        ((unsigned char *)address)[i] = pattern(i, 0x35);
    if (msync(address, create.size, MS_SYNC))
        printf("OBSERVED parent DRM mapping msync errno=%d (%s)\n", errno, strerror(errno));
    atomic_thread_fence(memory_order_seq_cst);
    puts("PASS CREATE_DUMB MAP_DUMB parent CPU mapping and write");
    exported.handle = create.handle;
    if (ioctl(card, DRM_IOCTL_PRIME_HANDLE_TO_FD, &exported)) {
        perror("FAIL PRIME_HANDLE_TO_FD");
        goto out;
    }
    shared = exported.fd;
    puts("PASS PRIME fd export");
    errno = 0;
    direct = mmap(NULL, create.size, PROT_READ | PROT_WRITE, MAP_SHARED, shared, 0);
    if (direct == MAP_FAILED)
        printf("OBSERVED dma-buf-fd mmap unavailable errno=%d (%s); independent of DRM-fd gate\n",
               errno, strerror(errno));
    else {
        if (verify_bytes(direct, create.size, 0x35))
            goto out;
        puts("OBSERVED dma-buf-fd mmap supported with correct pattern");
        munmap(direct, create.size);
        direct = MAP_FAILED;
    }
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets)) {
        perror("FAIL socketpair");
        goto out;
    }
    fflush(NULL);
    child = fork();
    if (child < 0) {
        perror("FAIL fork");
        goto out;
    }
    if (!child) {
        close(sockets[0]);
        close(shared);
        close(card);
        munmap(address, create.size);
        _exit(child_import(sockets[1]));
    }
    close(sockets[1]);
    sockets[1] = -1;
    struct buffer_info info = { create.width, create.height, create.pitch, 0, create.size };
    if (send_buffer(sockets[0], shared, &info)) {
        perror("FAIL send buffer");
        goto out;
    }
    if (waitpid(child, &status, 0) != child) {
        perror("FAIL waitpid");
        goto out;
    }
    child = -1;
    if (!WIFEXITED(status) || WEXITSTATUS(status)) {
        fprintf(stderr, "FAIL child status=%d\n", status);
        goto out;
    }
    if (verify_bytes(address, create.size, 0xa7))
        goto out;
    puts("PASS parent sees child CPU writes");
    result = 0;
out:
    if (child > 0) {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
    }
    if (direct != MAP_FAILED)
        munmap(direct, create.size);
    if (address != MAP_FAILED && munmap(address, create.size))
        result = 1;
    for (int i = 0; i < 2; i++)
        if (sockets[i] >= 0)
            close(sockets[i]);
    if (shared >= 0)
        close(shared);
    if (create.handle) {
        destroy.handle = create.handle;
        if (ioctl(card, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy)) {
            perror("FAIL DESTROY_DUMB");
            result = 1;
        }
    }
    if (render >= 0)
        close(render);
    if (card >= 0)
        close(card);
    return result;
}

/* Raw protocol prerequisite for minigbm's render-node selection. */
static int render_child(int socket)
{
    struct buffer_info info = {0};
    struct drm_prime_handle imported = {0}, kms_import = {0};
    struct drm_virtgpu_map map = {0};
    struct drm_gem_close close_handle = {0};
    struct drm_mode_fb_cmd2 fb = {0};
    int shared = -1, render = -1, kms = -1, result = 1;
    void *address = MAP_FAILED;
    shared = receive_buffer(socket, &info);
    if (shared < 0 || info.width != 64 || info.height != 64 ||
        info.pitch != 256 || info.size != 16384 || info.reserved)
        goto out;
    render = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (render < 0 || verify_driver(render))
        goto out;
    imported.fd = shared;
    if (ioctl(render, DRM_IOCTL_PRIME_FD_TO_HANDLE, &imported)) {
        perror("FAIL render child PRIME import");
        goto out;
    }
    map.handle = imported.handle;
    if (ioctl(render, DRM_IOCTL_VIRTGPU_MAP, &map)) {
        perror("FAIL render child VIRTGPU_MAP");
        goto out;
    }
    address = mmap(NULL, info.size, PROT_READ | PROT_WRITE, MAP_SHARED, render, map.offset);
    if (address == MAP_FAILED || verify_bytes(address, info.size, 0x4a)) {
        perror("FAIL render child CPU mapping/pattern");
        goto out;
    }
    for (size_t i = 0; i < info.size; i++)
        ((unsigned char *)address)[i] = pattern(i, 0xd2);
    atomic_thread_fence(memory_order_seq_cst);
    puts("PASS render child import VIRTGPU_MAP CPU read/write");
    kms = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    kms_import.fd = shared;
    if (kms < 0 || ioctl(kms, DRM_IOCTL_PRIME_FD_TO_HANDLE, &kms_import)) {
        perror("FAIL render buffer KMS import");
        goto out;
    }
    fb.width = info.width;
    fb.height = info.height;
    fb.pixel_format = DRM_FORMAT_ABGR8888;
    fb.handles[0] = kms_import.handle;
    fb.pitches[0] = info.pitch;
    if (ioctl(kms, DRM_IOCTL_MODE_ADDFB2, &fb)) {
        perror("FAIL render buffer ADDFB2");
        goto out;
    }
    puts("PASS render-created buffer primary-node ADDFB2");
    result = 0;
out:
    if (fb.fb_id && ioctl(kms, DRM_IOCTL_MODE_RMFB, &fb.fb_id))
        result = 1;
    if (address != MAP_FAILED && munmap(address, info.size))
        result = 1;
    if (kms_import.handle) {
        close_handle.handle = kms_import.handle;
        if (ioctl(kms, DRM_IOCTL_GEM_CLOSE, &close_handle))
            result = 1;
    }
    if (imported.handle) {
        close_handle.handle = imported.handle;
        if (ioctl(render, DRM_IOCTL_GEM_CLOSE, &close_handle))
            result = 1;
    }
    if (shared >= 0) close(shared);
    if (render >= 0) close(render);
    if (kms >= 0) close(kms);
    close(socket);
    return result;
}

static int probe_render_path(void)
{
    struct drm_mode_create_dumb dumb = { .width = 64, .height = 64, .bpp = 32 };
    struct drm_virtgpu_resource_create resource = {
        .target = 2, /* PIPE_TEXTURE_2D, required by the non-3D kernel path */
        .format = VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM,
        .width = 64, .height = 64, .depth = 1, .array_size = 1,
        .size = 16384, .stride = 256
    };
    struct drm_virtgpu_map map = {0};
    struct drm_prime_handle exported = { .flags = DRM_CLOEXEC | DRM_RDWR };
    struct drm_gem_close close_handle = {0};
    struct buffer_info info = {64, 64, 256, 0, 16384};
    int render = -1, shared = -1, result = 1, sockets[2] = {-1, -1}, status = 0;
    pid_t child = -1;
    void *address = MAP_FAILED;
    render = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (render < 0 || verify_driver(render))
        goto out;
    if (ioctl(render, DRM_IOCTL_MODE_CREATE_DUMB, &dumb)) {
        printf("OBSERVED render CREATE_DUMB errno=%d (%s)\n", errno, strerror(errno));
    } else {
        puts("OBSERVED render CREATE_DUMB supported");
        close_handle.handle = dumb.handle;
        if (ioctl(render, DRM_IOCTL_GEM_CLOSE, &close_handle))
            goto out;
    }
    if (ioctl(render, DRM_IOCTL_VIRTGPU_RESOURCE_CREATE, &resource)) {
        perror("FAIL render RESOURCE_CREATE");
        goto out;
    }
    map.handle = resource.bo_handle;
    if (ioctl(render, DRM_IOCTL_VIRTGPU_MAP, &map)) {
        perror("FAIL render VIRTGPU_MAP");
        goto out;
    }
    address = mmap(NULL, info.size, PROT_READ | PROT_WRITE, MAP_SHARED, render, map.offset);
    if (address == MAP_FAILED) {
        perror("FAIL render DRM-fd mmap");
        goto out;
    }
    for (size_t i = 0; i < info.size; i++)
        ((unsigned char *)address)[i] = pattern(i, 0x4a);
    atomic_thread_fence(memory_order_seq_cst);
    exported.handle = resource.bo_handle;
    if (ioctl(render, DRM_IOCTL_PRIME_HANDLE_TO_FD, &exported)) {
        perror("FAIL render PRIME export");
        goto out;
    }
    shared = exported.fd;
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets))
        goto out;
    child = fork();
    if (child < 0)
        goto out;
    if (!child) {
        close(sockets[0]);
        close(render);
        close(shared);
        munmap(address, info.size);
        _exit(render_child(sockets[1]));
    }
    close(sockets[1]);
    sockets[1] = -1;
    if (send_buffer(sockets[0], shared, &info) ||
        waitpid(child, &status, 0) != child)
        goto out;
    child = -1;
    if (!WIFEXITED(status) || WEXITSTATUS(status) ||
        verify_bytes(address, info.size, 0xd2))
        goto out;
    puts("PASS render resource lifecycle and bidirectional process visibility");
    result = 0;
out:
    if (child > 0) {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
    }
    if (address != MAP_FAILED && munmap(address, info.size))
        result = 1;
    for (int i = 0; i < 2; i++)
        if (sockets[i] >= 0) close(sockets[i]);
    if (shared >= 0) close(shared);
    if (resource.bo_handle) {
        close_handle.handle = resource.bo_handle;
        if (ioctl(render, DRM_IOCTL_GEM_CLOSE, &close_handle))
            result = 1;
    }
    if (render >= 0) close(render);
    if (result) fputs("FAIL render-node resource lifecycle\n", stderr);
    return result;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 2 && !strcmp(argv[1], "--host-self-test"))
        return host_self_test();
    /* Refuse normal execution on a workstation or Android device. */
    if (getpid() != 1) {
        fputs("NOT RUN: requires /init in the disposable QEMU initramfs\n", stderr);
        return 77;
    }
    mkdir("/proc", 0755);
    mkdir("/sys", 0755);
    mkdir("/dev", 0755);
    int result = 1;
    if (mount("proc", "/proc", "proc", 0, NULL) ||
        mount("sysfs", "/sys", "sysfs", 0, NULL) ||
        mount("devtmpfs", "/dev", "devtmpfs", 0, NULL))
        perror("FAIL mount guest filesystems");
    else {
        char compatible[128] = {0};
        int fd = open("/proc/device-tree/compatible", O_RDONLY);
        ssize_t n = fd >= 0 ? read(fd, compatible, sizeof(compatible) - 1) : -1;
        if (fd >= 0)
            close(fd);
        if (n > 0 && !strcmp(compatible, "linux,dummy-virt"))
            result = probe() || probe_render_path();
        else
            fputs("FAIL unexpected guest machine identity\n", stderr);
    }
    printf("%s DRM_RAW_BUFFER_GATE\n", result ? "FAIL" : "PASS");
    puts("NOT RUN: gralloc/minigbm, HIDL/Binder, SwiftShader, scanout, fence semantics, Android policy");
    sync();
    reboot(RB_POWER_OFF);
    for (;;)
        pause();
}
