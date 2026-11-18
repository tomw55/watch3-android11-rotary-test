# Separate registered HIDL service gate

Branch: `test/android11-hidl-service`. This extends the passing context-object
transport fixture without changing its branch, kernel Binder patches or policy.
The kernel remains the experimental Samsung Linux 4.9.59 ARM64 QEMU `virt`
configuration; it is not the Watch3 board build and is not the Ranchu kernel.

## Protocol and process boundaries

Use the existing public `android.hidl.token@1.0::ITokenManager` ABI with the
unique instance `watch3.fixture`. The service uses real generated HIDL server
bindings from API30 android.hidl.token@1.0.so and libhidlbase, not a hand-coded
Binder wire protocol. The
client discovers the instance through real Android 11 hwservicemanager, casts
the returned remote object to ITokenManager and uses its generated proxy.

AOSP interface contract:
https://android.googlesource.com/platform/system/libhidl/+/android-11.0.0_r48/transport/token/1.0/ITokenManager.hal

`createToken(interface)` must retain a strong reference; `get(vec<uint8_t>)`
returns that interface; `unregister(vec<uint8_t>)` releases the reference. The
fixture uses deterministic eight-byte little-endian counters as opaque tokens.
This is test code, not Android's production token implementation or a security
mechanism. Tokens are not secrets. Capacity is 32 live entries; IDs are never
reused, including after clear; counter exhaustion rejects allocation.

PID 1 starts the real manager and reruns the passing transport client. It then
executes the fixture server in a fresh process. The server starts its HIDL
threadpool and registers via IServiceManager::add. It signals a private pipe
only after registration returns success. PID 1 then executes a separate client,
passing the actual server and manager PIDs. No polling-only startup success is
accepted.

The client requires:

- Three distinct process IDs and a remote typed service whose getDebugInfo
  returns the expected server PID.
- Exact discovery of ITokenManager/watch3.fixture, separate from the manager's
  own default token service.
- 32 sequential create/get/revoke cycles, with exact token IDs 1..32.
- Returned Binder identity equals the real manager object originally stored;
  the returned remote object also responds to ping.
- Revocation makes subsequent get return null and a second unregister false.
- Unknown eight-byte token and lengths zero, seven and nine are rejected.
- Null interface returns an empty token; the service remains responsive.
- Server-side create receipts have the client's actual PID and exact IDs.

Unknown-token lengths are malformed *application tokens in valid HIDL calls*;
this is not malformed Binder-message fuzzing or HIDL deserializer coverage.

## Reproduction

`.github/workflows/android11-hidl-service.yml` runs host tests, extracts the
public API30 ARM64 SDK userspace, builds the preserved baseline client plus the
new fixture with NDK r21e and pinned VNDK30 headers, then compiles the same
hash-verified Samsung kernel and boots QEMU. Its HIDL_SERVICE_GUEST=1 switch
selects only the new guest init and extra assertions. HIDL_GUEST=1 retains the
already tested Unix-socket configuration. Kernel source SHA-256 remains
1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f.

Local lightweight checks:

```
bash ci/hidl-service/run-host-tests.sh
python3 ci/hidl-service/test-verify.py
gcc -std=c11 -Wall -Wextra -Werror -c ci/hidl-service/guest-init.c -o /tmp/hidl-init.o
```

The host token store test compiles the same template used by the Android
service. It covers strong-reference lifetime, invalid lengths, null pointers,
revocation, capacity, reset, ID exhaustion and eight worker threads. ASan/UBSan
and leak checks run on the GitHub runner. A local ptrace sandbox may prevent
LeakSanitizer; explicitly record that limit if disabling leak checks locally.
The threading test is not a ThreadSanitizer result or concurrency proof.
The synthetic log verifier has six independent negative controls; passing
synthetic tests is not Android runtime validation.

## Preserved limits

The fixture still uses direct context-object access because the minimal guest
has no Android property service. The real ready-property failure, trace-file
warnings and any AVC records remain in logs. SELinux is enforcing with a small
single-domain test policy, not a production Android policy. No VINTF-managed
HAL startup, production caller isolation, allocator/mapper service, graphics,
full Android boot, physical Watch3 communication or hardware enablement is
established here. Physical SM-R840: NO-GO.
