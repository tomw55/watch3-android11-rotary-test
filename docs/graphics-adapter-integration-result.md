# API30 allocator / mapper integration and composer build — PASS

Tested commit: 6d292f86d4570d854e455ff67b625d703751f45e.
Branch: test/android11-graphics-integration. Date: 2026-11-18.
Run: https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44375076616
Artifact: https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44375076616/artifacts/14460329130
ZIP SHA-256: f44d3b19253c93edd0f24ff74bb4e8ab5cf4b0aff4afeeafabe865b69fba95d2

## Actual outcomes

The kernel is Samsung Linux 4.9.59 ARM64 for QEMU virt, with VirtIO DRM,
PCI, Unix sockets, futex and advise syscalls enabled. Exynos/Noblesse hardware
is disabled. The kernel archive remains SHA-256
1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f.
No Watch3 production configuration or safety-audit patch changed.

| Check | Result |
|---|---|
| Real Android 11 hwservicemanager and prior HIDL baseline | PASS |
| Actual r48 allocator/mapper 2.0 adapters built | PASS |
| Remote allocator, actual local/passthrough mapper | PASS; client 31, allocator server 28, manager 26 |
| CPU RGBA allocate/import/lock/unlock/free | PASS; 16x16 stride 64, 63x3 stride 64, 65x7 stride 128 |
| HIDL native-handle transport ownership | PASS; import clones borrowed handle during allocate callback |
| Clean exec importer | PASS; PID 32, closes inherited nonstandard FDs, independently loads mapper |
| Cross-process pixels | PASS; importer checks client pattern, writes replacement; client checks replacement |
| Invalid descriptor, null free, second free | PASS; real adapters reject them |
| Fixture policy loaded/readable and enforcing | PASS; unchanged narrow policy binary |
| Fixed native-handle construction, ASan/UBSan | PASS; 21 layouts, overflow/OOM cleanup, original-expression mutant rejected |
| Real DRM composer module and standard HIDL composer/allocator service compile/link | PASS |
| SwiftShader native-window rendering, HWC runtime/atomic/fence semantics | NOT RUN |
| Normal vendor namespaces, VINTF, production policy compatibility | NOT RUN in this fixture |
| Full framework boot, real Watch3 hardware | NOT RUN in this fixture |

The mapper is deliberately local: Android's mapper 2.0 is a passthrough
interface. Its locality is not a missing Binder test. The allocator is remote
and transports real native_handle file descriptors via HIDL. The additional
exec importer uses SCM_RIGHTS after that allocation to verify shared backing.
Empty release fences are required by this narrow profile; no general fence
conformance follows. Neither general GPU rendering nor all buffer formats are
established. The module still uses the explicit CPU-only QEMU profile.

## Security-relevant discovery

The pinned upstream minigbm driver at a3120e47088d7b898acca9ee55825ccbc03f427c
contains this native-handle count expression in cros_gralloc_driver::allocate:

```
num_ints = num_bytes - sizeof(native_handle_t) - num_fds;
```

numInts counts int slots, not bytes. This overstates the allocation's payload
and can cause cloning/transport to read past it. The new fixture's 64-int bound
rejected the overreported handle; the first two import/mapping cases had
already completed. Run 44370351676 therefore FAILED at the exec-sharing gate.
Increasing the bound would hide the defect. The original standalone pixel
PASS did not establish safe native-handle serialization and is superseded for
that purpose by this corrected package.

The isolated native-handle-accounting.patch converts bytes to int slots,
checks name-size arithmetic and INT_MAX capacity, zeros the allocation to
avoid exporting unused fields/padding, and handles calloc failure with BO and
reserved-FD cleanup. Source-construction statements and the actual packed
handle header are compiled into the host regression with explicit BO/FD stubs.
The corrected runtime reports one FD and 35 integer slots. The test does not
audit every gralloc failure path, malformed imported handle or production
security property; the opaque handle parser still deserves separate hardening.

Source:
https://android.googlesource.com/platform/external/minigbm/+/a3120e47088d7b898acca9ee55825ccbc03f427c/cros_gralloc/cros_gralloc_driver.cc

## Build fixes and reproducibility

The adapter build needed the real libsync include directory. The composer
build additionally needed libdrm/android for gralloc_handle.h. Both are source
build dependencies, not substitute implementations. The last compiler audit
attempts all independent HWC/helper sources and fails if any source or link
fails. No new broad warning suppression was introduced.

Pinned sources: hardware/interfaces e7cb492bb835010b3d35496676200250b3b4697e;
minigbm a3120e47088d7b898acca9ee55825ccbc03f427c; drm_hwcomposer
e6aedbde1d66fb03c078726fcb8eda55983bdb75; libdrm
9d5089ee87931edcf5ba01949e0a11cf1a52b471; public supporting VNDK30 snapshot
95168a4aced97deb4966ef6f10c8fd6dee9f1582. This is a leaf-component build,
not a full r48 Soong/AOSP product build. Client/adapters use NDK r21e; the
preserved minigbm build uses its existing NDK27 compiler and platform C++ ABI.
The real API30 runtime is from the recorded SDK image; image selection alone
is not proof of exact source-to-binary identity with r48.

The artifact includes the full build logs, final config, kernel manifest,
initramfs, real guest-file hashes and a ten-file public composer package.
Its package manifest SHA-256 is
a729bded4a4f78116c0f3fc6c135e33c3443a02b43039d296542fd58e024671e.
The later normal-system experiment consumes this immutable package and must
verify it before use. The existing gralloc alias applies only to the native
fixture; normal Android requires real early properties and VINTF declarations.

Kernel Image SHA-256: 8b05a1a8f06c2f5fe78616c2b11813535f3a14f07db475c233e828196e2101db
config.final: a62a5df2c38efb3766bd55f3578223fd293fc45ada4acbc4d312adb38d8bb403
initramfs: da1a01f44eab7c9df16896cb2524983fe872e60e61e95337dd0974675b522225

Physical SM-R840 remains NO-GO. No physical device communication, firmware
upload or flashable Watch3 image was performed. Nothing merged to main.
