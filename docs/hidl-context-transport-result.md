# Android 11 HIDL context-object transport gate

Experimental branch: `test/android11-hidl-baseline`.
Date: 2026-11-18. Kernel: Samsung Linux 4.9.59 ARM64 QEMU `virt`.
This is neither the Ranchu reference kernel nor the Watch3 board configuration.

## Evidence-driven fixes

| Run | Actual result | Fix |
|---|---|---|
| 44358614781 / c73d05a | FAIL: modern NDK Bionic ctype helpers conflict with older platform libc++; C++14 rejects String16 deduction guide | Use Android 11-era NDK r21e for HIDL, C++17, and system-header treatment for external generated headers |
| 44359474471 / 36879b8 | FAIL: GNU linker cannot locate Android DSO transitive dependencies | Select NDK LLD and supply the real extracted library search path |
| 44360221790 / 6c8b773 | FAIL: guest log socket returns EAFNOSUPPORT before policy load | Inspect artifact config: CONFIG_UNIX unset; enable and assert it only with HIDL_GUEST=1 |

The failed guest artifact ZIP SHA-256 is
`1462edcc084d7bfe8e9a1ec5c98ad1ffd857f27617ae5d950d4ed14efefb7336`.
It was downloaded and independently checked, including its resolved config.
The final archive checksum is now regenerated after packaging the HIDL client.

The passing native Binder registration/request-reply branch and its evidence
are preserved. No Binder driver patch was changed for this HIDL experiment.
The shared QEMU configuration adds CONFIG_UNIX only when HIDL_GUEST=1; the
Watch3-specific configuration, accepted/held driver patches and production tag
are untouched. Nothing is merged to main.

## Host checks actually executed

- Strict C11 compilation of the guest init source: PASS.
- Bash syntax checks on changed scripts: PASS.
- Fixture policy compiled with checkpolicy MLS, unknowns denied, version 30: PASS.
- Independent newc reader exercised on the prior real Binder artifact plus
  three truncated inputs: PASS.

See `docs/hidl-context-transport-guide.md` for exact prerequisites, ABI/source provenance,
acceptance criteria and scope. The client uses actual libhidlbase-generated
remote proxies; it does not emulate the service-manager calls locally.

Normal property-ready service discovery, init-managed HAL startup, custom HAL
registration, graphics HAL operation, production Android policy and full Android
framework boot are not established by this fixture. Physical SM-R840: NO-GO.

## Verified CI result: PASS for the bounded transport gate

Tested commit: `0e3c403c97e9ba213af38f7d343524efc49bb704`.
[Run 44361365306](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44361365306).
[Artifact 14454342354](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44361365306/artifacts/14454342354).

| Check | Observed result |
|---|---|
| Hash-verified Samsung source, ARM64 Image compilation | PASS |
| Final config CONFIG_UNIX=y, three legacy Binder devices, SELinux | PASS |
| Whole fixture policy load and readable policy export | PASS, 3631 bytes, enforcing=1 |
| Actual Android 11 hwservicemanager | PASS, alive after five seconds; audit records show PID 24 |
| Separately executed Bionic HIDL client | PASS; generated remote proxy required, no in-process service substitute |
| Registry list | PASS: manager 1.0, 1.1, 1.2, base 1.0 and token 1.0 default instances |
| Remote get, ping, interfaceChain | PASS; chain includes manager 1.2, 1.1, 1.0 and base 1.0 |
| Independent downloaded ZIP and manifest verification | PASS |
| Normal property-ready discovery / init-managed HAL startup | NOT RUN |
| Custom HIDL HAL registration, allocator/mapper calls | NOT RUN |
| Full Android boot / physical hardware | NOT RUN |

Serial output includes the real failure to set hwservicemanager.ready (error
13), with an enforcing unix_stream_socket create denial. The fixture has no
property service and does not grant that class. The daemon continues, as its
source specifies. The direct context-object test avoids the normal ready-property
bootstrap; it does not demonstrate that HAL services can start normally.
Additional wake_alarm denials and absent trace-file messages are preserved;
they did not prevent the tested operations. No rules were added to silence them.
The policy uses one domain, so production SELinux caller isolation is untested.

The QEMU process is intentionally terminated at the 100-second capture deadline
while PID 1 is paused; its timeout is not evidence of clean Android shutdown.

### SHA-256 evidence

| File | SHA-256 |
|---|---|
| Artifact ZIP | `c8d23ee4755c6355a8460d7df01f46e136739d22bcb9008008646d192fc54190` |
| Image | `42fee4c5c6a9ac0576f3fc3896881621a7f9b311f823702b6608e6958bd71203` |
| config.final | `012a01f3728cb1f99877ae1c1c086994492dd89d3d04dd047bc11320cacc5de2` |
| initramfs.cpio | `df3f6d5841c9b413250b74022f980a5bfa166d0455bc72f0884743ee1ea33239` |
| test.policy | `fbec7014cc18d89c2c17f6521cd2d8f7d16e683186c3912598192dd286096b3d` |
| Resolved SDK system.img | `b8a505ecfc13629aee537f7fa9dcafa0d8d66802a06707f40dac69591e46f70f` |

```
python3 tools/verify-hidl-evidence.py artifact.zip c8d23ee4755c6355a8460d7df01f46e136739d22bcb9008008646d192fc54190
python3 tools/test-verify-hidl-evidence.py artifact.zip
```

The verifier checks the ZIP digest, kernel manifest, every guest-file digest
against its actual initramfs member, embedded policy equality, ARM64 ELF headers,
resolved config and runtime evidence. It never executes guest payloads.

The smallest next integration gate is a separate, explicitly registered HIDL
test service with a typed request/reply call through this real manager. Only
after that should allocator/mapper services and production bootstrap dependencies
be combined. The current result establishes the context-manager transport and
self-object calls, not those later gates.
