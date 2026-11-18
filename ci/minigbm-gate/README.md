# QEMU-only API 30 minigbm callback and scanout fixture

This experiment does not modify vendor.img, VINTF, the Android userspace
reference branch or Watch3 drivers. No physical device access is permitted.

`qemu49-render-2d.patch` applies only to upstream minigbm commit
`a3120e47088d7b898acca9ee55825ccbc03f427c` (android-11.0.0_r48). Its functional
changes require the explicit `MINIGBM_QEMU49_RENDER_2D` compile definition.
The ordinary build keeps the original allocation, mapping and flush paths.
The virgl/3D paths retain their original behavior. The opt-in non-3D profile
advertises only four 32-bit linear RGB formats, CPU access, texture consumption
and scanout; protected, multiplanar and GPU-rendering allocations are excluded.

## Important pinned-kernel details

The Samsung archive SHA-256 is
`1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f`.
The experimental Image is reused from Actions run 44299096977 and verified
against SHA-256 `6ed2c548d50a2e2a741b48b3522ec00673fa55ad4859fe4a2511bd800ce51e37`.
Its resolved configuration is copied into the new evidence.

* `drivers/gpu/drm/drm_ioctl.c:623-624`: dumb ioctls lack DRM_RENDER_ALLOW,
  so render nodes are rejected. These entries do not themselves carry
  DRM_MASTER or DRM_AUTH; do not attribute this exact failure to missing
  DRM master privileges on a primary node.
* `drivers/gpu/drm/virtio/virtgpu_ioctl.c:224-259`: non-3D RESOURCE_CREATE
  validates a limited 2D request. This implementation passes width/height/format
  to the host and does not use `rc->stride` to define host row pitch. The
  adaptation pads RESOURCE width as well as guest stride. It preserves r48's
  existing 64-pixel tile alignment, giving 256-byte rows for 32-bit RGB, and
  checks all arithmetic before narrowing to the 32-bit resource size field.
* `drivers/gpu/drm/virtio/virtgpu_plane.c:86-93`: automatic transfer on a plane
  update is conditional on bo->dumb. RESOURCE_CREATE does not set that flag.
* `drivers/gpu/drm/virtio/virtgpu_ioctl.c:394-438`: TRANSFER_TO_HOST explicitly
  supports the non-3D transfer command. The opt-in unlock flush sends a whole
  logical-buffer transfer. This is not a host-GPU readback path.
* `drivers/gpu/drm/virtio/virtgpu_fb.c:119-164`: DirtyFB on a non-dumb resource
  flushes the host resource. The test issues this after the second CPU update.
  A successful ioctl alone is not pixel correctness: QMP screendumps must show
  the two different requested RGB colours.

## Actual callback test design

`build.sh` builds the real gralloc0 module, minigbm backend code, libdrm and
libsync from pinned public source with the API-30 NDK target. Supplementary
platform headers, libc++, libcutils and libhardware come from the separately
pinned published VNDK-v30 snapshot. This is NOT a full r48 Soong product build.
The module uses platform __1 libc++ ABI, not NDK __ndk1. `runtime.py` packages
real Android 11 Bionic dependencies from the SHA-256-verified SDK revision-16
system image, falling back to the pinned VNDK-v30 snapshot where necessary.
Source revisions, binary hashes, ELF dependencies and compiler version are
recorded. No whole Android SDK image is uploaded as a test artifact.

Inside the disposable initramfs only, gralloc.default.so is a symlink to the
built gralloc.minigbm.so so genuine hw_get_module can find it without a running
Android property service. This does NOT validate ro.hardware.gralloc or real
vendor linker namespaces / SELinux policy integration.

The parent allocates CPU+composer RGBA, locks/writes/unlocks it and transfers
native_handle integer bytes and one SCM_RIGHTS fd. The child closes inherited
non-standard fds except its socket and execs a new Bionic process. It loads the
module independently, registers, locks and verifies the parent pattern,
writes another pattern and unlocks. The child imports through a fresh primary
DRM fd, creates a framebuffer and performs legacy modesetting using an
actually connected connector/mode/compatible CRTC. QMP captures one colour,
then an update of the same framebuffer, testing transfer plus DirtyFB. The
parent subsequently checks the final child-written CPU pixels. Child import
references use unregisterBuffer; the parent allocation uses free; handles and
fds have separate ownership. Ordinary success paths perform explicit cleanup.
Failures terminate the disposable guest and fail the job; teardown on every
injected failure is not yet exhaustively tested.

HW_TEXTURE|HW_RENDER allocation is a deliberate unsupported-usage control in
this CPU-only profile, not a claimed GPU-rendering PASS. The socket fixture is
for trusted same-test-process messages; it checks fd counts, payload bounds
and truncation but is not a hardened untrusted native_handle parser.

## Reproduction and scope

Push this experiment to `test/samsung49-minigbm-callback`; the dedicated
workflow runs its exact source revision. It downloads the already-verified
kernel artifact, runs strict C11 + ASan/UBSan geometry checks, builds the module
and executes a minimal Linux init plus Bionic callback fixture on QEMU virt.
No full AOSP checkout, Android init or framework boot is involved.

A PASS requires both complete callback/teardown markers and host-observed
pixel checks. Compilation, a successful modeset or a lone framebuffer creation
is insufficient. Atomic commits, fence APIs, SwiftShader, HIDL adapters,
SurfaceFlinger, full Android policy and Watch3 hardware remain NOT RUN.

Physical SM-R840 remains strictly NO-GO.
