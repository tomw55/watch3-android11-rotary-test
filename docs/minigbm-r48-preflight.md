# API 30 minigbm preflight: render-node contract

## Evidence and scope

2026-11-18. Experimental branch: `test/samsung49-drm-buffer-gate`.
Commit tested: `a3bc6339d72936133626e5879f372a884ca0b396`.
[Actions run 44299096977](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44299096977): PASS.

This is Samsung Linux 4.9.59 under upstream QEMU `virt`, with VirtIO-GPU,
1024 MiB RAM and a disposable static-Linux initramfs. It is not an Android
userspace boot, gralloc test, or Watch3 hardware test.

Authoritative Samsung source archive SHA-256:
`1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f`.
Minigbm source: AOSP `android-11.0.0_r48`, resolved commit
[`a3120e47088d7b898acca9ee55825ccbc03f427c`](https://android.googlesource.com/platform/external/minigbm/+/a3120e47088d7b898acca9ee55825ccbc03f427c/).

Artifact: `samsung49-drm-buffer-44299096977`, artifact ID `14424498980`.
The downloaded ZIP SHA-256 and every entry in its three internal SHA-256
manifests were independently checked against the actual archive contents.

| Evidence | SHA-256 |
|---|---|
| Artifact ZIP | `f50ed724aa2be8557e2381f1f5d641d0e37675bc89a76997f98ff15ac49ec016` |
| Samsung experimental Image | `6ed2c548d50a2e2a741b48b3522ec00673fa55ad4859fe4a2511bd800ce51e37` |
| Resolved config.final | `0eb98a2ffafe8e1cc8e98c6b8930fb6f4493e8d4727fd82170dd1c0c9ed197c6` |
| Serial log | `5b8698bb7e7fa94c0fe60993b9b626a8a146c8e3dfdc1c46000f55d755251454` |

## Actual results

| Test | Result |
|---|---|
| Primary-node CREATE_DUMB and MAP_DUMB + DRM-fd mmap | PASS |
| PRIME export and same-device import through a fresh DRM file in a child | PASS |
| Imported DRM-fd mmap and bidirectional CPU patterns | PASS |
| Direct dma-buf-fd mmap | Observed `ENODEV` (19); unsupported path |
| Render-node CREATE_DUMB | Observed `EACCES` (13); unsupported path |
| Render-node VIRTGPU_RESOURCE_CREATE + VIRTGPU_MAP and DRM-fd mmap | PASS |
| Render-created resource export and fresh render-file import in child | PASS |
| Render-imported VIRTGPU_MAP and bidirectional CPU patterns | PASS |
| Import render-created buffer through primary file and ADDFB2/RMFB | PASS |
| Actual gralloc.minigbm alloc/registerBuffer/lock/unlock callbacks | NOT RUN |
| HIDL allocation/mapper transport, SwiftShader execution | NOT RUN |
| Legacy modeset, atomic commit, visible scanout, fences, graphics coherency | NOT RUN |

Both mappings returned `EINVAL` for msync. This is recorded separately;
CPU pattern visibility passed. It does not demonstrate display-cache maintenance.
The raw test uses one QEMU GPU; no cross-device PRIME compatibility is claimed.

## Exact minigbm source contract

Line references below refer to the pinned upstream source, not a modified tree.

* [`cros_gralloc/cros_gralloc_driver.cc`](https://android.googlesource.com/platform/external/minigbm/+/a3120e47088d7b898acca9ee55825ccbc03f427c/cros_gralloc/cros_gralloc_driver.cc),
  `cros_gralloc_driver::init()`, lines 35-85: searches `renderD128` through
  `renderD190`. There is no primary-card fallback. Allocator and independently
  initialized importer both use this selection logic.
* [`virtio_gpu.c`](https://android.googlesource.com/platform/external/minigbm/+/a3120e47088d7b898acca9ee55825ccbc03f427c/virtio_gpu.c),
  `virtio_gpu_bo_create()`, lines 651-658, and `virtio_gpu_bo_map()`, lines
  668-675: without the 3D feature, call the dumb allocation/mapping helpers.
* `virtio_gpu.c`, `virtio_dumb_bo_create()`, lines 391-400: aligns dimensions
  to the llvmpipe tile size and calls `drv_dumb_bo_create_ex()`.
* [`helpers.c`](https://android.googlesource.com/platform/external/minigbm/+/a3120e47088d7b898acca9ee55825ccbc03f427c/helpers.c),
  `drv_dumb_bo_create_ex()`, lines 310-370: CREATE_DUMB on `bo->drv->fd`.
  `drv_dumb_bo_map()`, lines 458-479: MAP_DUMB, then mmap on that same DRM fd
  at `map_dumb.offset`. It does NOT mmap the exported dma-buf fd on this path.
* `cros_gralloc_driver.cc`, `retain()`, lines 239 onward: imports PRIME handles
  through the newly initialized driver's fd; there is no special primary-fd
  mapping path for imported handles.

Samsung archive source:

* `drivers/gpu/drm/drm_ioctl.c`, `drm_ioctl_permit()`, lines 503-506, rejects
  render clients when the ioctl lacks DRM_RENDER_ALLOW, even for root.
* The same file, lines 623-624, does not give CREATE_DUMB or MAP_DUMB that
  flag. PRIME export/import, lines 599-600, do have it.
* `drivers/gpu/drm/virtio/virtgpu_ioctl.c`, resource creation from line 215
  onward, accepts constrained 2D resources without virgl 3D. VIRTGPU_MAP and
  RESOURCE_CREATE registrations at lines 529 and 538 allow render clients.

**Conclusion:** stock r48 non-3D minigbm uses the right kind of DRM-fd mapping,
but selects a node on which its dumb ioctls are prohibited. The observed
render-node EACCES is the immediate compatibility obstacle. The successful raw
primary-node lifecycle does not establish that unmodified gralloc will work.
No dma-buf mmap kernel backport is justified by this result alone.

## Smallest next integration change

Prepare an isolated QEMU-only minigbm adaptation using the demonstrated
render-node RESOURCE_CREATE/MAP contract for a narrowly defined linear RGB
buffer profile. Keep existing virgl/3D behavior unchanged. Explicitly check
format/stride/size arithmetic, imported metadata, handle cleanup and unsupported
formats. Do not simply route all existing multiplanar formats through the 3D
helper, change global DRM render permissions, or claim all minigbm usage
combinations work from one 64x64 RGBA raw test.

A primary-node-only test override is an alternative diagnostic, but changes
master/authentication and access-policy assumptions. It would not qualify the
normal render-node allocator path.

Before modifying vendor images, build the actual pinned Android module and a
Bionic callback executable with recorded platform headers/libraries and linker
dependencies. No module or callback binary has been built in this preflight.
Do not substitute a host shim or a newer VNDK snapshot without identifying it.

The callback gate must preserve these independent outcomes:

1. Original module result versus explicitly adapted module result.
2. RGBA CPU+composer usage versus texture+render usage; log support/fallback
   decisions. `gralloc0_alloc()` lines 127-130 can drop BO_USE_SCANOUT when
   composer allocation is initially unsupported. Allocation alone therefore
   cannot prove scanout eligibility.
3. Parent lock/unlock integrity and importing client lock/unlock integrity.
   The client must `exec` a fresh process, not just dlopen after fork: fork can
   inherit an already initialized module singleton and GEM state.
4. Transfer native_handle counts and integer payload plus SCM_RIGHTS fds, with
   strict count, truncation and cleanup checks; no raw pointer transfer.
5. Imported framebuffer creation versus actual mode-setting/atomic commit.
   Query connector, CRTC, dimensions, format and pitch instead of assuming a
   64x64 test framebuffer can drive the selected display mode.
6. CPU buffer visibility versus cache/fence correctness and real EGL rendering.

No vendor image, VINTF, Android userspace reference configuration or Watch3
production kernel was changed. Physical SM-R840 remains NO-GO.
