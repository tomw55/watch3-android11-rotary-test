# Registered Android 11 NDK Binder request/reply gate — PASS

Tested commit: `755f6516752bdaa6db96b8be1c9cab7f20320ebc` on
`test/binder-android11-adaptation`.
[CI run 44355227059](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44355227059).
[Evidence artifact 14453870969](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/44355227059/artifacts/14453870969).
Date: 2026-11-18. Artifact retention: seven days.

## Actual execution

The kernel is the experimental **Samsung Linux 4.9.59 ARM64 QEMU virt kernel**,
not Ranchu or the physical Watch3 configuration. Its resolved configuration and
System.map hashes match the prior passing registration reference. No Binder
backport, accepted/held driver patch, production kernel or device foundation
was changed for this gate.

The actual Android 11 servicemanager and libbinder_ndk were used. A separate
NDK client looked up watch3.test.echo through servicemanager, required
AIBinder_isRemote=true, associated the matching Binder class, and submitted
synchronous AParcel transactions. This was not a direct callback invocation.

| Check | Actual outcome |
|---|---|
| Loaded policy, kernel enforcement and userspace SELinux | PASS, retained from registration gate |
| Positive registration / denied-service control | PASS, status 0 / expected -1 |
| Separate client/server | PASS, client PID 30, registered server PID 26 |
| 32 sequential requests and replies | PASS, sequences 0–31 exactly once |
| Payload integrity | PASS, 64-bit request `(0x0123456700000000 + sequence)`, response XOR `0x1122334455667788` |
| Reply identity | PASS, reply sequence matches and returned server PID matches the registrar PID recorded by guest init |
| Server receipt | PASS, 32 server-side records, caller PID 30 / server PID 26 throughout |
| Unknown transaction code | PASS, STATUS_UNKNOWN_TRANSACTION = -74 |
| Truncated request | PASS, STATUS_BAD_VALUE = -22 |
| Service survives invalid requests | PASS, final genuine service CLI still discovers watch3.test.echo |
| Existing host loader regression | PASS, strict C11 + ASan/UBSan |
| Full Android boot, HIDL HALs, physical hardware | NOT RUN |

## Exact changed implementation files

* `ci/binder-adaptation/register-test-service-ndk.cpp`: typed server callback
  and `--client` mode in the existing Bionic executable. The server rejects
  invalid transaction codes, missing fields and out-of-range sequence IDs.
  It responds with the sequence, transformed payload and its real PID. The
  client verifies all responses and both malformed-input controls.
* `ci/binder-adaptation/servicemanager-guest-init.c`: execute the client in a
  separate process, pass the actual registrar PID as the expected identity,
  capture bounded output, enforce a timeout, and require successful completion.
  Drain the server's diagnostic pipe after the exchanges.
* `ci/samsung-virt/run.sh`: require the new request/reply PASS marker in addition
  to loaded-policy, enabled/enforcing, positive registration, denial-control
  and registry-discovery assertions. Existing protections were not relaxed.

Parcel ownership was checked against AOSP android-11.0.0_r48
`frameworks/native/libs/binder/ndk/ibinder.cpp`: AIBinder_transact consumes the
input parcel and DestroyParcel clears its pointer. Reply parcels remain the
caller's responsibility. The client follows this contract, including error cases.

## Independent artifact examination

The downloaded ZIP hash and all entries in its kernel/config/initramfs/policy
manifest were independently verified. A separate verifier recomputed each of
the 32 expected response values from its sequence, checked client/server PIDs
and all 32 server receipt records, and required the malformed, policy and
registry markers. No guest binaries were executed during that examination.

| Evidence | SHA-256 |
|---|---|
| Artifact ZIP | `216ac21a1bd43ac379ea6439ab5f6c1d8fbfeeb530ce5426c8bc1c69b9b36076` |
| Image | `d1b5ec8bebcb6a7ab85237a314c6113151a0696b8e2ba73274728477406d8994` |
| config.final | `9a4ae4d511b248c5bd0d354652e0d081cd56599ef72403c9b000c69270610348` |
| initramfs.cpio | `00d9f220981c6709d8bed8fcc626433e462b4fa5f4b3f8920981b5e49782cd7e` |
| test.policy | `5a963009bf232ea7ca328e7366d2a9a2fd719f0e4c6c0f53a66f349be3091b5a` |

```
python3 tools/verify-ndk-rpc-evidence.py /path/to/artifact.zip
```

Reproduce through `.github/workflows/android11-servicemanager-qemu.yml` on this
branch. The prior registration/policy reference remains at commit 91e1169,
with its report and verifier retained. SDK userspace acquisition still resolves
the published API-30 ARM64 package; this is not a fully pinned AOSP product build.

## Limits and next gate

This is a small sequential typed-payload test, not Binder fuzzing, a concurrency
stress test, large-payload validation, caller-domain separation or production
Android SELinux policy verification. The isolated fixture retains one test
domain and its explicit allow/deny service labels. The fixed QEMU capture timeout
ends a paused PID 1, not an Android framework boot or clean shutdown test.

The next integration gate is the separate hwservicemanager/HIDL path needed
for graphics allocator/mapper integration. That requires its own transport,
policy, service-registration and functional-call evidence.

Nothing merged to main. No Watch3 communication, flashing or hardware changes.
Physical SM-R840 remains strictly **NO-GO**.
