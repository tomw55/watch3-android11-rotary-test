# API 30 minigbm callback and scanout result

**PASS**, 2026-11-18, for the isolated CPU-only RGBA QEMU profile.

* Tested source commit: [`f8f56adcc1ab12bc656e51628afeeb4fb625e6fa`](https://github.com/tomw55/watch3-android11-rotary-test/commit/f8f56adcc1ab12bc656e51628afeeb4fb625e6fa).
* [Actions run 44306403379](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44306403379), job `134808991990`, success.
* [Evidence artifact 14428950924](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44306403379/artifacts/14428950924), `samsung49-minigbm-44306403379`.
* Artifact ZIP SHA-256: `e5d82a9381fbc6b17e497daa17e3b770e9663c2392a853cc04474c80838d4d47`.

The kernel is **Samsung Linux 4.9.59**, not stock Ranchu. It is the unchanged
experimental QEMU Image from run 44299096977, SHA-256
`6ed2c548d50a2e2a741b48b3522ec00673fa55ad4859fe4a2511bd800ce51e37`.
Its resolved configuration is in the artifact.
Built module SHA-256: `bece7785942737d1fd66dc71ff530615e8fb6caa4cdda39913c68b9cda1364ef`.
Callback executable SHA-256: `a8c2284b64c13ccb98f3ca66f6b334c0800cbee13d626d427988dd39e2aee9be`. The known-good physical-watch
kernel, accepted/held safety patches and Android userspace reference are unchanged.

## What actually ran

The fixture built and executed the actual r48 gralloc0 module and minigbm
backend with the opt-in `MINIGBM_QEMU49_RENDER_2D` patch. It used real API-30
ARM64 Bionic libraries, with supplementary published VNDK-v30 platform headers
and libraries. This is a manual leaf-module build, not a Soong product build
or a full Android boot. Compiler: NDK 27.2.12479018, Clang 18.0.3, target
`aarch64-unknown-linux-android30`.

| Gate | Observed evidence | Result |
|---|---|---|
| Checked layout | 264,450 small geometry cases, invalid dimensions and overflow tests | PASS host/CI |
| Actual patched allocation/map functions | Strict C11, ASan/UBSan, ioctl and mmap interception | PASS host/CI |
| Mutation controls | Wrong resource width, ignored create failure, wrong mmap fd all detected | PASS host/CI |
| Ordinary backend compilation | `virtio_gpu.c` also compiled without the opt-in macro | PASS compile only |
| Module loading | Real hw_get_module loaded `CrOS Gralloc`, id `gralloc`, allocator PID 60 | PASS guest |
| Parent callbacks | RGBA CPU+composer allocation, direct lock, write, unlock | PASS guest |
| Clean importer | Close inherited fds, exec, independent module load at PID 61, registerBuffer and lock | PASS guest |
| Bidirectional pixels | Importer verified parent pattern, wrote updates; parent verified final child-written pattern | PASS guest |
| PRIME and KMS | Fresh primary fd import, ADDFB2, legacy SetCrtc and GetCrtc verification | PASS guest |
| First displayed pixels | 1024x768 image, RGB `(163,54,113)`, 786,432/786,432 matching pixels | PASS host observation |
| Same-framebuffer update | Unlock transfer plus DirtyFB; RGB `(87,196,42)`, every pixel matching | PASS host observation |
| Explicit teardown | Disable CRTC, RMFB, close primary GEM handle, unregister importer, close/delete transferred native handle, free parent allocation | PASS guest |
| Unsupported GPU usage | HW_TEXTURE + HW_RENDER returned -22 in CPU-only profile | PASS negative control, **not** GPU-rendering support |
| Atomic commits, fence APIs, other formats/usages, failure-path teardown under every error | Not exercised | NOT RUN |
| SwiftShader, HIDL adapters, full vendor namespace/property/policy integration, SurfaceFlinger | Not exercised | NOT RUN |
| Android framework boot or Watch3 hardware | Not exercised | NOT RUN |

The importing process uses the real public native_handle integer payload and
SCM_RIGHTS fd. It is not Binder/HIDL transport. A fixture-only
`gralloc.default.so -> gralloc.minigbm.so` symlink lets hw_get_module resolve
the module without an Android property service. No vendor image is modified.

## Kernel/userspace findings

1. Stock minigbm non-3D render-node discovery plus dumb ioctls is incompatible
   with this kernel's ioctl permissions. Dumb ioctls lack DRM_RENDER_ALLOW;
   their entries do not themselves require DRM_MASTER. Primary master rules
   remain relevant separately for actual modesetting.
2. The opt-in path uses render-node RESOURCE_CREATE/MAP, preserving the normal
   backend and its virgl behavior. In the pinned kernel's 2D creation path,
   resource width determines host row pitch: supplying a padded `stride` field
   alone is insufficient. The patch pads resource dimensions as well as the
   guest layout, with overflow checks.
3. RESOURCE_CREATE buffers are not flagged `bo->dumb`. The plane update's
   automatic 2D transfer therefore cannot be relied on. Explicit non-3D
   TRANSFER_TO_HOST on unlock, followed by modesetting / DirtyFB resource
   flushing, produced the two independently verified host images. Removing
   that transfer would require a negative runtime test before claiming it is
   unnecessary; no broad coherency/fence claim is made.
4. No VIRTGPU ioctl or registerBuffer error occurred in the successful guest
   lifecycle. Tests do not exhaust malformed handles, kernel allocation failures,
   concurrent access, host GPU writes or every backend error path.

The normal minigbm paths remain the default. The experimental profile supports
only a restricted set of linear 32-bit RGB CPU buffers. Runtime pixel/scanout
proof in this run covers RGBA_8888 only. Unsupported GPU rendering is rejected
instead of being silently treated as software support.

## Verification and caveats

Independent examination downloaded the exact ZIP, checked its SHA-256, every
entry of its global manifest, and each actual ARM64 ELF payload inside the
newc initramfs against guest-SHA256SUMS. Both PPM screenshots were independently
re-read and every pixel checked. The alias and serial callback/cleanup markers
were also verified. Reproduce that examination with:

```
python3 tools/verify-minigbm-evidence.py /path/to/samsung49-minigbm-44306403379.zip
```

Requires Python 3 and Pillow. It does not extract or execute the guest files.
The verifier targets this exact artifact. Build/run reproduction is in
`ci/minigbm-gate/README.md` and the dedicated workflow.

The serial log contains an `init[1]: syscall 293` register dump. The pinned
Samsung `arch/arm64/kernel/traps.c:611-619` logs unsupported user syscalls and
returns through sys_ni_syscall/ENOSYS. This is consistent with a modern glibc
optional rseq probe in the minimal Linux init, not evidence of a kernel Oops;
the guest subsequently completes and powers down. The log also records
uninitialized urandom reads in this minimal guest. This fixture does not
establish a securely seeded Android runtime or Android SELinux policy loading.

Earlier attempts exposed a missing libdrm libm dependency, a duplicate feature
macro in the strict test fixture, and a pipeline masking build failures. These
were fixed explicitly. The passing workflow uses bash pipefail, checks all
callback markers and requires both pixel checks. No broad warning suppression
or kernel permission expansion was introduced.

## Next integration gate

Exercise the actual selected API-30 allocator/mapper passthrough adapters over
this same narrow module profile before changing vendor.img or VINTF. Preserve
these callback and host-pixel checks as regressions. Hardware-rendering usage,
real fence semantics, other formats, SwiftShader import and Android policy /
linker namespace compatibility need separate evidence. The successful leaf
test is not a working Android graphics stack.

Physical SM-R840 remains strictly **NO-GO**. Nothing was merged into main.
