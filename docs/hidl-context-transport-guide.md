# Android 11 HIDL context-object transport fixture

This separate QEMU-only gate uses the experimental Samsung Linux 4.9.59
ARM64 `virt` kernel, not the Watch3 board kernel or Ranchu kernel. It loads
real API30 ARM64 hwservicemanager and libhidlbase from the published SDK image.
No Samsung binary is redistributed in this source directory.

## Acceptance

1. PID 1 loads the whole MLS version-30 fixture policy, reads selinuxfs policy
   back and requires enforcing=1.
2. Real hwservicemanager survives five seconds. This alone is insufficient.
3. A separately executed Android/Bionic C++ client obtains hwbinder context
   handle zero and constructs the generated IServiceManager 1.0 remote proxy.
4. Real HIDL list returns the registered manager; get returns its remote object;
   ping and interfaceChain complete over Binder IPC.
5. Every expected marker is required; FAIL, panic and call trace reject the run.

The fixture labels the three self-registered framework interfaces explicitly.
The policy has one fixture process domain, not production domain separation or
an Android production SELinux policy. No custom HAL registration is tested.

## Reproduce

Run `.github/workflows/android11-hidl-baseline.yml` by changing its covered
paths on branch `test/android11-hidl-baseline`. It installs cross-compilers and
QEMU on Ubuntu 22.04, extracts API30 userspace and dependencies, builds the HIDL
client and invokes the existing Samsung QEMU build with HIDL_GUEST=1.

The kernel archive SHA-256 remains
`1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f`.
HIDL_GUEST=1 additionally requests and asserts CONFIG_UNIX=y, needed by the
fixture logging socket. Other QEMU configurations are unchanged.
The existing Binder backports are reused without modification. The kernel
build still uses the existing verified GCC 7.5/binutils 2.32 toolchain.

Client headers come from the public VNDK30 platform snapshot
`95168a4aced97deb4966ef6f10c8fd6dee9f1582`. This supplementary generated-header
snapshot is not represented as an exact r48 source checkout. Its libc++
headers use the platform `std::__1` ABI. The client uses NDK r21e
`21.4.7075529`, C++17, and links the actual image's libc++.so and libhidlbase.so;
it does not link NDK libc++_shared or substitute HIDL implementations. The
existing NDK27 registrar build is unchanged. SDK image revisions are resolved
by sdkmanager; record the actual image hash, not a presumed fixed revision.

## Scope boundary

AOSP `android-11.0.0_r48` system/hwservicemanager/service.cpp lines 149-173
registers the manager and token manager, establishes the Binder context object,
and attempts to set hwservicemanager.ready. Failure to set that property logs
an error but does not exit. The minimal initramfs has no Android property
service. The client deliberately uses the real context-object transport,
not normal `defaultServiceManager()` ready-property discovery. That discovery,
production VINTF matching, init-managed HAL startup, custom HAL registration,
allocator/mapper operations and full Android boot remain NOT RUN.

AccessControl.cpp lines 40-52 loads the SELinux hwservice label handle;
lines 56-77 strip the version from FQName for add/find lookups; lines 94-127
check the hwservice_manager permissions against the supplied label map.

Source references:
- https://android.googlesource.com/platform/system/hwservicemanager/+/android-11.0.0_r48/service.cpp
- https://android.googlesource.com/platform/system/hwservicemanager/+/android-11.0.0_r48/AccessControl.cpp
- https://android.googlesource.com/platform/prebuilts/vndk/v30/+/95168a4aced97deb4966ef6f10c8fd6dee9f1582/

Physical SM-R840: NO-GO. No hardware enablement or device communication.
