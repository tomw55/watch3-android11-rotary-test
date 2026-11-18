# Android 11 servicemanager under Samsung Linux 4.9.59: PASS

Date: 2026-11-18. Branch: `test/binder-android11-adaptation`.
Tested commit: `91e1169c9d2c98101199a61622a7ba4624080a90`.
[Passing Actions run 44352298678](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44352298678).
[Evidence artifact 14449606597](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44352298678/artifacts/14449606597).
Artifact retention is seven days; regenerate through the dedicated workflow if expired.

This is the Samsung Linux 4.9.59 **QEMU virt experiment**, not stock Ranchu
and not the Watch3 hardware kernel configuration. Android 11 ARM64 servicemanager,
libbinder, libselinux and the genuine service CLI run as Bionic processes under a
small native Linux PID 1. No full Android init/framework boot is claimed.

## Observed runtime evidence

| Criterion | Actual result |
|---|---|
| Load binary policy before Android process launch | PASS: single full write; 3,452-byte policy readable afterward |
| Version/MLS/unknown-permission handling | PASS: compiled policy v30, MLS enabled, unknown permissions denied |
| Kernel enforcement | PASS: `DIAG SELinux enforcing=1` |
| Userspace libselinux | PASS: `enabled=1 enforcing=1` in both registration clients |
| Genuine Android servicemanager | PASS: alive after five seconds |
| Positive registration | PASS: `watch3.test.echo`, `NDK REGISTER status=0` |
| Negative registration | PASS: `watch3.test.denied`, `NDK REGISTER status=-1`, expected permission denial |
| Separate genuine Android service CLI | PASS: `Found 2 services`, including `watch3.test.echo: [watch3.test.echo]` |
| Host loader fault injection | PASS: 16 cases under strict C11 and again with ASan/UBSan in CI |
| Full Android framework / production policy / Watch3 hardware | NOT RUN |

All seven workflows associated with tested commit 91e1169 completed successfully:
source baseline, Binder context-manager stage 1, sender-security-context stage 2,
Binder security-context QEMU runtime, Android binary acquisition, this registration
fixture, and the offline boot-readiness inventory. Inventory success is not a
hardware-readiness approval.

## Actual fixes

* `ci/binder-adaptation/servicemanager-guest-init.c`: load `/test.policy` before
  launching Android. A short write is terminal; only EINTR without transferred
  bytes retries. Verify policy readback and enforcement, fail closed on error.
* `ci/binder-adaptation/servicemanager-test.conf`: separate, narrowly scoped
  fixture policy. The existing native `ci/samsung-virt/test.conf` is unchanged.
  Define the service_manager class and the test labels, with MLS s0 contexts.
* Samsung `security/selinux/ss/policydb.c` requires at least one defined process
  transition permission. Declare transition/dyntransition without granting them.
* Actual AVCs identified diagnostic-pipe I/O, proc symlink access, task-labelled
  proc directory/file access, and filesystem metadata operations needed by the
  Android linker and libselinux. Grant those specific fixture accesses.
* AOSP r48 libselinux `src/avc.c:233` and `src/avc_internal.c:59-90` establish
  the AVC notification socket dependency. Allow its read-side create/bind/read/
  getattr operations. Samsung `security/selinux/netlink.c` enables non-root
  reception; no network administrative capability is needed.
* `register-test-service-ndk.cpp`: directly verify libselinux enabled/enforcing
  and add an expected-permission-denial mode. Link the actual extracted libselinux.
* Keep servicemanager's diagnostic-pipe reader open through the tests. The
  negative child runs separately, and the positive registrar remains alive for
  the registry query. Existing registration/discovery assertions remain strict.
* The workflow includes the host loader tests and preserves kernel, configuration,
  policy, initramfs, compiler versions, hashes and complete serial evidence.

The initial diagnostic was correct: an enforcing flag alone did not establish
that a policy was loaded. Loading a policy then exposed additional fixture
permission requirements. No further Binder driver workaround was needed here.
One retry was caused solely by a TLS reset downloading the pinned toolchain.

## Security scope and limitations

This policy deliberately uses **one fixture domain**, `u:r:kernel_t:s0`, for
native PID 1, servicemanager and clients. It is not a production Android policy,
app sandbox or domain-transition validation. Service labels are distinct and
only manager/echo labels have add/find grants; the denied label has none.
No permissive mode, allow-unknown fallback or blanket class allow was introduced.
The policy and temporary service-context map apply only inside this disposable
initramfs. They must not be installed on the Watch3.

The serial log still contains denied wake_alarm capability probes; the normal
monotonic timer and service tests succeed without granting that capability.
It also contains the known unsupported syscall-293 diagnostic from the modern
static-glibc PID 1. These are retained in the evidence, not hidden.

The fixture intentionally ends with PID 1 paused. QEMU exit 124 is its fixed
100-second capture timeout, not proof of a hang or a clean shutdown test.
No daemon endurance, full Android boot, hwservicemanager, HAL registration or
custom service payload round trip is established by this gate. Registry lookup
and descriptor discovery are distinct from a custom request/response test.

Kernel source/toolchain inputs remain pinned. The acquisition script selects
the published API-30 ARM64 SDK system image through sdkmanager and records its
image/binary hashes; this is not a fully pinned, bit-reproducible AOSP product
build. Accepted/held safety patches, production kernel tag, rotary workflows,
Android device foundation and main branch were not modified.

## Independent evidence verification

The downloaded artifact ZIP and every entry in its kernel/policy SHA-256
manifest were independently rehashed. Binary policy header, resolved kernel
configuration and positive/negative/discovery serial markers were checked.

| File | SHA-256 |
|---|---|
| Artifact ZIP | `27341ce69f75953960c0fc9935163c2b119aca97aae27a38372fe72185672d9b` |
| Experimental Image | `53242621b35a2377727af5ad9abd948686a922e18976f0672f4daa607372d785` |
| config.final | `9a4ae4d511b248c5bd0d354652e0d081cd56599ef72403c9b000c69270610348` |
| initramfs.cpio | `4dbe65498f6999e483d7c4e2240497130c7ad7898aba2caa9fe5c58a2dc4896b` |
| test.policy | `5a963009bf232ea7ca328e7366d2a9a2fd719f0e4c6c0f53a66f349be3091b5a` |

Recheck this exact ZIP without executing its contents:

```
python3 tools/verify-servicemanager-policy-evidence.py /path/to/artifact.zip
```

Host regression reproduction (host file operations are intercepted):

```
python3 tools/test-servicemanager-policy-loader.py /path/to/host-test-output
```

The next smallest integration gate is a custom NDK Binder payload round trip
through the registered service, retaining positive/negative authorization checks.
Physical SM-R840 remains strictly **NO-GO**. No hardware communication, flashing,
unlocking, bootloader changes or merges to main occurred.
