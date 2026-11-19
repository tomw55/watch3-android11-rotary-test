# Watch3 single-client-target display contract fixture

This is a **host-only C prototype**, not an Android composer HAL, allocator,
display driver, or hardware test program. It constructs a single full-screen
360 x 360 DECON request and exercises ownership/error handling using a synthetic
descriptor registry. It contains **no implementation that opens a device or
issues an ioctl**. Nothing installs into Android or enables hardware.

All development belongs to `test/binder-android11-adaptation`. The kernel,
accepted/held safety patches, device foundation and rotary/Binder workflows
are unchanged. Physical SM-R840 testing remains NO-GO.

## Reproduce

Requirements: LP64 Linux, Python 3.9+, GCC/compatible C11 compiler, binutils
(`nm`), and working AddressSanitizer/UndefinedBehaviorSanitizer runtimes.

```sh
python3 ci/watch3-display/run-tests.py

# Optional: rederive every checked-in declaration/oracle from the authoritative ZIP.
# This verifies the full archive and selected member SHA-256 values first.
python3 ci/watch3-display/run-tests.py --archive /actual/path/kernel_samsung_galileo-master.zip

# Optional: actual ARM64 object compilation (not ARM64 execution).
python3 ci/watch3-display/run-tests.py --cross-cc aarch64-linux-gnu-gcc
```

In a ptrace-based sandbox, LeakSanitizer cannot run. Use `--no-lsan` explicitly
there; the report marks LSan NOT RUN while ASan/UBSan still execute. The GitHub
workflow does not pass that option and requires LSan success. No full AOSP or
kernel compilation, emulator, Samsung firmware or private archive is needed
for the normal fixture test.

The checked-in `SOURCE_SHA256SUMS` covers the implementation, generator,
declarations, test oracles and documentation. `extract-abi.py --check ARCHIVE`
also proves the generated files match the exact pinned source, without writing.
To deliberately regenerate, omit `--check` and separately review/update hashes.

## What was implemented

| Part | Scope |
|---|---|
| `abi/watch3_decon_abi.h` | Source-extracted enums/structures/ioctl; 64-bit DMA type from ARM64 configuration |
| `abi/source_oracle.c` | Verbatim kernel DPP format translation; kernel limitation-check body with only logging and unused device argument removed |
| `model.c`, `model.h` | Construct one linear, unprotected, untransformed RGBA/RGBX/BGRA 32-bit client target; no overlays, scaling, HDR, panel commands or allocation |
| `tests.c` | Fake descriptor backend, failure injection, source-oracle controls, repeated lifecycles, layout assertions |
| `run-tests.py` | Strict C11, ASan/UBSan/LSan, symbol check, executed mutations, ABI-negative compilation, optional actual AArch64 compilation |
| `.github/workflows/watch3-display-host.yml` | Separate host CI; no changes to existing workflows |

The prototype's format enum is deliberately **not an Android numeric HAL enum**.
Mappings mirror `halFormatToS3CFormat()` in the reference
[ExynosDisplay.cpp:88-100](https://github.com/parasetam0l/smdk_hardware_samsung_slsi/blob/main/exynos/libvppdisplay/ExynosDisplay.cpp#L88).
The Watch3 kernel then transforms named formats for DPP itself. We do not
pre-apply that transformation a second time. These are source-level mappings;
physical byte order, displayed colours and GPU interoperability are untested.

## Exact source evidence

Authoritative archive SHA-256:
`1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f`.
Member hashes and extraction line references are in `abi/provenance.json`.
Paths below are relative to that archive's `kernel_samsung_galileo-master/`.

| Contract | Source |
|---|---|
| 64-bit `dma_addr_t` assumption | `arch/arm64/configs/tizen_noblesse_defconfig:29`, `CONFIG_ARCH_DMA_ADDR_T_64BIT=y` |
| Three real windows plus update slot | `drivers/video/fbdev/exynos/dpu_9110/decon.h:78,87,625-628` |
| Request fields and alignment inputs | `decon.h:527-594,625-629` |
| Encoded ioctl | `decon.h:1427-1428`, `S3CFB_WIN_CONFIG` |
| Kernel dma-buf/ION import and kernel-owned IOVMM address | `decon_core.c:1337-1398` |
| Supported IDMA, compression, HDR and geometry checks | `decon_core.c:1404-1497` |
| Acquire fence import only with `CONFIG_SYNC` | `decon_core.c:1520-1532` |
| Buffer-size calculation uses u32 | `decon_core.c:1558-1564` |
| Fence creation and queueing | `decon_core.c:2220-2386` |
| Request copy-in / fence copy-out guards | `decon_core.c:2940-2971` |
| Kernel RGBA-to-DPP translation | `helper.c:69-111` |

With natural LP64 layout the fixture checks a 200-byte window, 808-byte
request and `S3CFB_WIN_CONFIG = 0x432846d1`. The generated declarations are
not the whole kernel header: unrelated internal kernel state is excluded.
Both host and optional ARM64 compilers must satisfy the offset/size assertions.
Host LP64 checks alone are not reported as ARM64 compilation.

### Concrete synchronization blocker

The supplied Noblesse defconfig enables `CONFIG_SYNC_FILE=y` and
`CONFIG_DRM_DMA_SYNC=y`, but does not enable `CONFIG_SYNC`. A scan of every
Kconfig member in the pinned ZIP found definitions for SYNC_FILE and
DRM_DMA_SYNC and **no Kconfig definition named SYNC**. That is evidence about
this source archive, not a fresh resolved Watch3 build configuration or the
running stock binary. Do not equate these three symbols or simply add a
nonexistent CONFIG_SYNC to a fragment.

In this DECON source, `CONFIG_SYNC` guards Android acquire/retire processing
and fence copy-out. Merely enabling SYNC_FILE does not activate that code.
The prototype therefore rejects `W3_SYNC_UNKNOWN` and `W3_SYNC_DISABLED`.
`W3_SYNC_RETIRE_ONLY` is an **explicit synthetic backend contract**, not an
assertion that the stock kernel supplies it. A future integration must review
and test the Tizen-versus-Android synchronization path separately.

### Ownership and failure policy

- Input buffer/acquire descriptors are borrowed; the model duplicates them
  and never closes the originals. Failed duplication unwinds once.
- Only the backend supplies the owned retire descriptor. The model accepts
  FD zero and rejects a returned FD that aliases its owned input descriptors.
- An ioctl-like error may happen after work was queued (for example copy-out
  failure). Such a frame enters UNCERTAIN, is not retried, and retains references.
- A missing retire fence is a protocol failure, not a successful presentation.
- Timeout retains references. A signalled retire fence **does not** authorize
  reusing/releasing the current scanout buffer.
- After any submission, cleanup requires independent backend quiescence.
  Only the test backend implements that signal; no production equivalent is
  guessed. Canceling a never-submitted frame is safe in the model.
- The actual driver's queued-work/copyout error can leave a kernel-installed
  FD whose number userspace never received. This model cannot recover such an
  undisclosed FD. Production error handling remains BLOCKED pending review.

The fake registry tests descriptor bookkeeping, **not** actual dma-buf memory
lifetime, cache maintenance, IOMMU mappings or scanout completion.

## Tests and remaining gates

Host tests cover three format mappings, source-derived DPP translation,
19 malformed/unsupported buffer cases, unknown/disabled synchronization,
duplicate failure at either stage, five submission-error cases, timeout,
retire-versus-release distinction, 15 real kernel limitation-check negative
controls and 1,000 repeated model lifecycles.

Five bad implementations must compile and then fail assertions: premature
release, missing width validation, wrong format, ignored duplication error,
and accepting a missing retire fence. Wrong window count and DMA width must
fail compile-time assertions. The binary's imported symbols must not include
open, ioctl, mmap, socket or connect.

**NOT RUN / not implemented:** Android HWC2/HIDL service, VINTF registration,
allocator/mapper/native-handle bridge, ION allocation, real sync_file fences,
SurfaceFlinger integration, panel/power/suspend, Mali EGL or physical output.

**Next smallest integration task:** trace and reconcile the DECON
CONFIG_SYNC/DRM_DMA_SYNC fence path, preserving Tizen behavior. Establish a
tested Android acquire/retire/release contract before supplying a device
backend. Then implement the matching Android buffer-handle importer and
single-client-target composer adapter. No hardware enablement follows from
this host fixture passing.

## License

Samsung-derived declarations/oracles retain the source GPLv2 notice. The new
model and host tests are GPL-2.0-only; see `COPYING`. No Samsung firmware,
proprietary userspace libraries or device identifiers are included.
