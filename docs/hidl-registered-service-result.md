# Registered HIDL service gate — PASS

Tested commit: `5b66be4491c735e0b982d2ca284a7370f2fd5f35`.
Branch: `test/android11-hidl-service`. Date: 2026-11-18.
[CI run 44364717698](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44364717698).
[Evidence artifact 14455714363](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44364717698/artifacts/14455714363).

The kernel is the **experimental Samsung Linux 4.9.59 ARM64 QEMU virt kernel**.
This is not Ranchu and not the physical Watch3 board kernel. Its resolved
configuration, System.map and fixture policy are byte-for-byte identical to
the preceding passing HIDL transport artifact. No new kernel feature, Binder
backport, SELinux rule, accepted/held safety patch or hardware enablement was
needed. Only the selected guest fixture and its userspace test changed.

## Observed results

| Check | Actual result |
|---|---|
| Preceding manager list / lookup / ping / interfaceChain gate | PASS again |
| Real Android 11 hwservicemanager | PASS, PID 24 |
| Separate registered ITokenManager/watch3.fixture | PASS, PID 27 |
| Separate generated-proxy client | PASS, PID 30; service reports PID 27 |
| Exact instance discovery through real manager | PASS |
| 32 typed create/get/revoke lifecycles | PASS; sequences 0..31, tokens 1..32 exactly once |
| Returned remote Binder object | PASS; equals stored real-manager Binder identity and responds to ping |
| Server-side request correlation | PASS; all 32 create receipts have caller PID 30 / server PID 27 |
| Revoked-token get and second unregister | PASS, null and false after every cycle |
| Invalid token lengths 0, 7, 9; unknown length-8 token | PASS, get null and unregister false |
| Null interface input and final service ping | PASS, empty token and responsive service |
| Whole fixture policy load / enforcing | PASS, readable 3631-byte policy, enforcing=1 |
| Host core tests, strict C++17 + ASan/UBSan + leak checks | PASS on actual GitHub runner |
| Synthetic verifier positive + six negative controls | PASS; not a runtime result |
| Independent downloaded artifact verification | PASS, all manifests, embedded policy, ARM64 ELFs and runtime records |
| Normal property-ready discovery, init-managed production HAL startup | NOT RUN |
| Allocator/mapper/HWComposer, full Android framework boot | NOT RUN |
| Physical Watch3 | NOT RUN, NO-GO |

The HIDL service implements the existing public token interface with its real
API30 generated bindings. Its deterministic opaque counters are a test-only
algorithm, not Android's production TokenManager or a secure token design.
The test does not build a new .hal ABI or validate a hardware sensor/graphics HAL.
See [the execution guide](hidl-registered-service-guide.md) for precise scope.

## Initial failure and evidence-based correction

[Run 44364048085](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44364048085),
commit adae968, passed the host tests but failed Android linking. Unresolved
ITokenManager descriptor, castFrom, virtual functions and RTTI referenced a
separate DSO, not missing kernel functionality. Static readelf examination of
the real preceding artifact confirmed the descriptor and cast exports in
android.hidl.token@1.0.so and absence of the requested exported ITokenManager typeinfo.
The fix explicitly links that genuine extracted DSO and uses -fno-rtti, matching
these Android platform bindings. No replacement symbols or permissive linker
workaround was introduced. The corrected targeted run passed.

Local host limitations were also recorded: the first mktemp invocation failed
because /tmp is unavailable in this sandbox; using a workspace TMPDIR resolved
that. Local LeakSanitizer could not run under ptrace. Local ASan/UBSan then
passed with leak detection explicitly disabled; CI independently passed with
leak detection enabled. These were test-environment limits, not service defects.

## Independent artifact verification

The ZIP digest matched GitHub's artifact digest. Every entry in the kernel
manifest was checked; each guest-file hash was compared with its actual
initramfs member, including the new fixture executable. The embedded policy
matches the preserved policy output. ARM64 ELF headers were checked for the
fixture, token DSO, baseline client, real manager and HIDL runtime. The serial
verifier independently requires all 32 request/reply lifecycle records and
matching three-process identities; it rejects missing, duplicate or reordered
records and wrong IDs. The old passing transport artifact was separately
rejected as insufficient for this new gate.

| Evidence | SHA-256 |
|---|---|
| Artifact ZIP | `3a185ee4b6c28cc5c945514a1a5fd2b12c004fd399888145868c1fb5deb9aba3` |
| Image | `18121dc31ad1a0f35838dad904d631c5b951273052e5c03d0102d297027125d1` |
| config.final | `012a01f3728cb1f99877ae1c1c086994492dd89d3d04dd047bc11320cacc5de2` |
| System.map | `b990ec8e57e974d29b611247b2f62ed604071672e7ff0d5a30381a595649c66f` |
| initramfs.cpio | `71189da371fb9089b963cc9eb657593b67004dd3d5745ad98df80b05541c5a7e` |
| test.policy | `fbec7014cc18d89c2c17f6521cd2d8f7d16e683186c3912598192dd286096b3d` |

```
python3 tools/verify-hidl-service-evidence.py artifact.zip 3a185ee4b6c28cc5c945514a1a5fd2b12c004fd399888145868c1fb5deb9aba3
```

Full logs and dependencies are in the artifact. The SDK acquisition still
resolves the published API30 ARM64 package and records its image hash; this is
not represented as a fully pinned custom AOSP product build. Platform headers
remain pinned to VNDK30 commit 95168a4aced97deb4966ef6f10c8fd6dee9f1582.

## Limits and next useful gate

The minimal guest has no Android property service. The real ready-property
failure and AVC/trace messages are preserved. Direct context-object access is
still used; normal property-ready bootstrap is untested. The fixture policy
has one process domain, so this is not production SELinux isolation or a caller
authorization test. No Binder fuzzing, large payload, process-death lifecycle,
endurance or HAL conformance claim follows. PID 1 pauses after the bounded test;
QEMU's deliberate capture timeout is not a clean Android shutdown or full boot.

The next useful gate is a real allocator/mapper integration test against the
previously inspected gralloc stack: matching API/handle contracts, remote
allocation, client import/lock and cross-process data visibility. Re-inventory
the available binaries/source before selecting that implementation. Do not
infer graphics compatibility from this token-service result.

Nothing merged into main; prior passing branches and all hardware baselines
remain preserved. No Watch3 communication or physical changes occurred.
