# Raw DRM buffer gate

This isolated experiment boots the pinned Samsung 4.9.59 source on upstream
QEMU virt with VirtIO-GPU PCI. The Android-userspace reference branch is separate.

The probe runs as /init in a disposable Linux initramfs with 1024 MiB RAM.
It validates primary and render-node identity, dumb allocation and DRM-fd mmap,
PRIME fd export, SCM_RIGHTS transport to a separate process, import through a
new DRM file, imported DRM-fd mmap and bidirectional CPU patterns, ADDFB2/RMFB,
and handle cleanup. ADDFB2 creates a framebuffer; scanout is not attempted.

DMA-BUF-fd mmap is an independent observation. Its failure does not invalidate
the required DRM-fd mapping path. Same-device PRIME import is distinct from
cross-device attachment and scatter-gather import.

This does NOT load gralloc.minigbm, run HIDL or Binder transport, render EGL,
test cache maintenance for scanout, validate fences, boot Android or load
Android SELinux policy. A passing result only qualifies the raw kernel
contract for later allocator testing. The 1024 MiB initramfs is not the planned
Android memory-pressure baseline.

The guest refuses normal non-PID1 execution before accessing devices, and
checks the QEMU virt compatible string. The host self-test exercises only
Unix sockets, pipes and synthetic metadata.

UAPI headers are copied from the SHA-256-verified kernel archive during CI.
Empty __user removes annotations normally stripped by headers_install.
The kernel uses the established GCC 7.5 toolchain; the static Linux probe uses
the runner ARM64 cross compiler, with versions captured. It is not a Bionic
Android executable.

Local strict C11 and ASan/UBSan host checks passed with leak detection disabled.
LeakSanitizer cannot run under this workspace's tracing environment. CI runs
the sanitizer test normally and preserves its output.

No Samsung hardware nodes are activated by this configuration. Physical
SM-R840 remains NO-GO.
