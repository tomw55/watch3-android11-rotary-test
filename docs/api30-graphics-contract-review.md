# API 30 graphics contracts before a HAL build

This reviews selected repositories at android-11.0.0_r48 and the pinned Samsung
archive. A full AOSP checkout is absent. No graphics compilation or image
modification was performed for this review.

## Pinned source

| Repository | Peeled r48 commit |
| --- | --- |
| platform/hardware/interfaces | e7cb492bb835010b3d35496676200250b3b4697e |
| platform/external/minigbm | a3120e47088d7b898acca9ee55825ccbc03f427c |
| platform/external/drm_hwcomposer | e6aedbde1d66fb03c078726fcb8eda55983bdb75 |
| platform/external/swiftshader | f5c5d50a2e69e7c66715eff7c53c6abb07acc827 |

Samsung ZIP SHA-256 is
1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f.
The SDK image is Google API 30 arm64-v8a revision 16, archive SHA-256
097c2808a738ba4c19038b75a085750dd61a7178c0234b14ac5f8270dd8cff54.
The image's source-to-binary identity is not established by choosing r48.

## 1. Allocator and mapper

The standard legacy route exists in hardware/interfaces/graphics:

* allocator/2.0/default/Android.bp defines allocator 2.0 service and implementation.
* allocator/2.0/utils/passthrough/include/allocator-passthrough/2.0/GrallocLoader.h
  loads GRALLOC_HARDWARE_MODULE_ID with hw_get_module, then selects Gralloc0Hal
  for module major version zero. Its Gralloc0Hal.h opens gralloc0.
* mapper/2.0/utils/passthrough/include/mapper-passthrough/2.0/GrallocLoader.h
  selects the legacy mapper. Gralloc0Hal.h clones native handles and calls
  registerBuffer, unregisterBuffer and lockAsync or synchronous lock.
* mapper/2.1/default/Android.bp defines the additional
  android.hardware.graphics.mapper@2.0-impl-2.1 candidate.

Minigbm contains two implementation families. Root Android.bp builds
gralloc.minigbm using cros_gralloc/gralloc0/gralloc0.cc. The nested
cros_gralloc/gralloc4/Android.bp builds native
android.hardware.graphics.allocator@4.0-service.minigbm and
android.hardware.graphics.mapper@4.0-impl.minigbm.

The earlier review inspected only the root build definition and omitted the
native gralloc4 family. This complete checkout corrects that omission.
No native minigbm 3.0 service family was found in these build definitions.

Both legacy 2.x and native 4.0 require deliberate VINTF changes from the image's
allocator 3.0 / mapper 3.0 declarations and framework compatibility checks.

Drm_hwcomposer defines hwcomposer.drm_minigbm. Its
platform/platformminigbm.cpp::DrmMinigbmImporter::ConvertBoInfo interprets
cros_gralloc_handle and reads its fd, stride and offset. This is the matching
importer candidate. DMA-BUF fd sharing alone does not prove handle compatibility.

The candidate first small build is gralloc0 minigbm plus standard allocator 2.0
and mapper 2.0 adapters and drm_minigbm. Native gralloc4 is another candidate.
Neither has been compiled or approved for image injection.

## 2. SwiftShader buffer import

SwiftShader src/System/GrallocAndroid.cpp and its Common counterpart define
GrallocModule. With HAVE_GRALLOC4 it first attempts mapper 4.0. Otherwise it
loads the legacy gralloc module with hw_get_module. Lock dispatches to mapper
4.0, gralloc0 m_module->lock or gralloc1. Legacy import returns the existing
handle; gralloc4 import calls the mapper. src/Main/FrameBufferAndroid.cpp
calls this import/lock/unlock/release sequence.

This source path does not uniformly use GraphicBufferMapper::lock and does
not itself decode cros_gralloc_handle.

The actual SDK libEGL_swiftshader.so depends on mapper 4.0 and libhardware
and imports hw_get_module. Its captured ELF dependencies do not include libui.
This corroborates the source model without proving exact binary identity.

Minigbm virtio_gpu.c::virtio_gpu_bo_map uses drv_dumb_bo_map when 3D is disabled.
A generic assumption about DMA-BUF mmap would therefore be too broad.

The pinned Samsung drivers/gpu/drm/virtio/virtgpu_drv.c registers dumb_create
and dumb_map_offset. virtgpu_gem.c::virtio_gpu_mode_dumb_mmap returns the
object mmap offset.

However, virtgpu_prime.c contains unimplemented operations.
virtgpu_gem_prime_mmap returns -ENODEV. Pinning, scatter-gather export/import,
and vmap also return errors. Broad PRIME interoperability is unsupported.
Same-device GEM import can use other DRM-core paths, so the stubs alone do
not prove every selected minigbm operation fails.

Before the HAL build, a disposable QEMU probe must create and CPU-map a dumb
buffer, export its fd, import through a second DRM file, map the imported
object, compare bytes and release every handle/fd. Test DMA-BUF mmap separately
from DRM-fd mmap. Required fences also need runtime validation.

## 3. Early property selection

The actual logical vendor contains /etc/init/hw/init.ranchu.rc, mounted at
/vendor/etc/init/hw/init.ranchu.rc. Its early-init action sets
ro.hardware.egl=emulation and ro.hardware.vulkan=ranchu.

Future image preparation should replace the first EGL assignment in this
exact imported file, and add gralloc/composer selection before consumers run:

    setprop ro.hardware.egl swiftshader
    setprop ro.hardware.gralloc minigbm
    setprop ro.hardware.hwcomposer drm_minigbm

The Ranchu Vulkan assignment needs separate client/fallback assessment.
No proposed graphics property has been applied to the passing image.

In system/core/init/property_service.cpp, ProcessKernelCmdline creates ro.boot.*
from androidboot.*. The explicit alias table maps ro.boot.hardware to
ro.hardware but has no aliases for hardware.egl, hardware.gralloc or
hardware.hwcomposer. The dotted androidboot arguments alone are insufficient.
Read-only properties reject writes once initialized.

hardware/libhardware/hardware.c::hw_get_module_by_class checks
ro.hardware.<module> before broader hardware variants.

## Target scope and status

Samsung's Noblesse defconfig enables EXYNOS_DECON_9110 and EXYNOS_DECON_FB,
and disables DRM_EXYNOS. It also enables Samsung TDM/TBM DRM components.
QEMU VirtIO DRM success would not establish Watch3 display compatibility.

| Check | Status |
| --- | --- |
| Source identities, adapters and ownership paths | SOURCE VERIFIED |
| Native minigbm gralloc4 family | SOURCE VERIFIED |
| SwiftShader mapper4/legacy dispatch | SOURCE VERIFIED |
| Samsung dumb-map hooks and PRIME stubs | SOURCE VERIFIED |
| SDK ELF inventory and fusectl mount | CI evidence, run 44289874806 |
| Graphics HAL compilation | NOT RUN |
| VirtIO-GPU buffer/fence operations | NOT RUN |
| SwiftShader rendering with selected allocator | NOT RUN |
| Replacement-stack VINTF validation | NOT RUN |
| Full Android framework boot | NOT DEMONSTRATED |

The smallest next task is the isolated DRM buffer probe before the HAL build.
Physical SM-R840 remains NO-GO.
