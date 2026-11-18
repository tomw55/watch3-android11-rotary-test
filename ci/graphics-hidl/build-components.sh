#!/usr/bin/env bash
# Compile the real r48 DRM composer + HIDL service for later image integration.
set -euo pipefail
out="$PWD/servicemanager-binary"; mg="$PWD/minigbm-build"
vndk="$PWD/hidl-vndk"; interfaces="$PWD/graphics-interfaces"
git -C "$interfaces" sparse-checkout add graphics/composer/2.1
hwc="$PWD/drm-hwcomposer"
git init "$hwc"
git -C "$hwc" remote add origin https://android.googlesource.com/platform/external/drm_hwcomposer
timeout 180 git -C "$hwc" fetch --depth=1 --filter=blob:none origin e6aedbde1d66fb03c078726fcb8eda55983bdb75
timeout 180 git -C "$hwc" checkout --detach FETCH_HEAD
lib="$out/guest/system/lib64"
# Public VNDK30 ABI libraries; retain SDK runtime files whenever already present.
for name in libui.so libfmq.so android.hardware.graphics.composer@2.1.so android.hardware.graphics.mapper@3.0.so android.hardware.graphics.mapper@4.0.so; do
 if [[ ! -s "$lib/$name" ]]; then
  found=0
  for kind in vndk-core vndk-sp; do
   if git -C "$vndk" show "95168a4aced97deb4966ef6f10c8fd6dee9f1582:arm64/arch-arm64-armv8-a/shared/$kind/$name" > "$lib/$name.tmp" 2>/dev/null; then mv "$lib/$name.tmp" "$lib/$name";found=1;break;fi
  done
  test "$found" = 1 || { echo "Missing genuine composer dependency $name" >&2;exit 1; }
 fi
done
incs=(-I"$hwc/include" -I"$mg/src/libdrm" -I"$mg/src/libdrm/include/drm" -I"$mg/src/libdrm/android" -I"$mg/src/minigbm/cros_gralloc" -isystem "$mg/src/core/libsync/include")
while IFS= read -r p;do incs+=(-isystem "$p");done < <(find "$vndk/arm64/include" -type d \( -name include -o -name include_vndk -o -name gen \) | grep -v external/libcxx/ | sort)
while IFS= read -r p;do incs+=(-isystem "$p");done < <(find "$interfaces/graphics" -type d -name include | sort)
cc="$PWD/.android-sdk/ndk/21.4.7075529/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang++"
flags=(-std=c++17 -nostdinc++ -isystem "$vndk/arm64/include/external/libcxx/include" -fno-rtti -fPIC -Wall -Werror -O2 "${incs[@]}")
links=(-nostdlib++ -fuse-ld=lld -L"$lib" -Wl,-rpath-link,"$lib" -lc++ -lcutils -ldrm -lhardware -llog -lsync -lui -lutils)
mkdir -p "$out/hwc-objects"
sources=(drmhwctwo.cpp compositor/drmdisplaycomposition.cpp compositor/drmdisplaycompositor.cpp drm/drmconnector.cpp drm/drmcrtc.cpp drm/drmdevice.cpp drm/drmencoder.cpp drm/drmeventlistener.cpp drm/drmmode.cpp drm/drmplane.cpp drm/drmproperty.cpp drm/resourcemanager.cpp drm/vsyncworker.cpp platform/platform.cpp platform/platformdrmgeneric.cpp platform/platformminigbm.cpp utils/autolock.cpp utils/hwcutils.cpp utils/worker.cpp)
objects=()
failed=0; hwc_failed=0
for file in "${sources[@]}";do
 obj="$out/hwc-objects/${file//\//_}.o"
 if "$cc" "${flags[@]}" -DHWC2_USE_CPP11 -DHWC2_INCLUDE_STRINGIFICATION -c "$hwc/$file" -o "$obj"; then objects+=("$obj");else failed=1;hwc_failed=1;fi
done
if (( hwc_failed == 0 ));then
 "$cc" -shared -Wl,--no-undefined -Wl,-soname,hwcomposer.drm_minigbm.so "${objects[@]}" "${links[@]}" -o "$out/guest/vendor/lib64/hw/hwcomposer.drm_minigbm.so" || failed=1
fi
# Build the standard AOSP composer service, including its unmodified adapters.
helpers=(utils/hwc2on1adapter/HWC2On1Adapter.cpp utils/hwc2on1adapter/MiniFence.cpp utils/hwc2onfbadapter/HWC2OnFbAdapter.cpp utils/resources/ComposerResources.cpp)
objects=()
helper_failed=0
for file in "${helpers[@]}";do
 obj="$out/hwc-objects/service_${file//\//_}.o"
 if "$cc" "${flags[@]}" -c "$interfaces/graphics/composer/2.1/$file" -o "$obj";then objects+=("$obj");else failed=1;helper_failed=1;fi
done
if (( helper_failed == 0 ));then
"$cc" "${flags[@]}" "$interfaces/graphics/composer/2.1/default/service.cpp" "${objects[@]}" "${links[@]}" -lhidlbase -lbase -lbinder -lfmq -l:android.hardware.graphics.composer@2.1.so -l:android.hardware.graphics.mapper@2.0.so -l:android.hardware.graphics.mapper@3.0.so -l:android.hardware.graphics.mapper@4.0.so -Wl,--dynamic-linker=/system/bin/linker64 -o "$out/guest/system/bin/graphics-composer-service" || failed=1
else failed=1;fi
(( failed == 0 )) || { echo 'FAIL composer component source/link audit; all independent files attempted' >&2;exit 1; }
printf '%s\n' 'drm_hwcomposer e6aedbde1d66fb03c078726fcb8eda55983bdb75' >> "$out/graphics-sources.txt"
sha256sum "$out/guest/vendor/lib64/hw/hwcomposer.drm_minigbm.so" "$out/guest/system/bin/graphics-composer-service" > "$out/composer-components.sha256"
readelf -d "$out/guest/vendor/lib64/hw/hwcomposer.drm_minigbm.so" > "$out/composer-module-elf.txt"
readelf -d "$out/guest/system/bin/graphics-composer-service" > "$out/composer-service-elf.txt"
echo 'PASS composer components compiled; runtime and vendor-image integration NOT RUN'

"$cc" "${flags[@]}" "$interfaces/graphics/allocator/2.0/default/service.cpp" "${links[@]}" -lhidlbase -l:android.hardware.graphics.allocator@2.0.so -Wl,--dynamic-linker=/system/bin/linker64 -o "$out/guest/system/bin/graphics-allocator-service"
pkg="$out/composer-package/vendor"
mkdir -p "$pkg/lib64/hw" "$pkg/bin/hw" "$pkg/etc/init"
cp "$out/guest/vendor/lib64/hw/"{gralloc.minigbm.so,hwcomposer.drm_minigbm.so,android.hardware.graphics.allocator@2.0-impl.so,android.hardware.graphics.mapper@2.0-impl-2.1.so} "$pkg/lib64/hw/"
cp "$lib/"{libdrm.so,libsync.so} "$pkg/lib64/"
cp "$out/guest/system/bin/graphics-allocator-service" "$pkg/bin/hw/android.hardware.graphics.allocator@2.0-service"
cp "$out/guest/system/bin/graphics-composer-service" "$pkg/bin/hw/android.hardware.graphics.composer@2.1-service"
cp "$interfaces/graphics/allocator/2.0/default/android.hardware.graphics.allocator@2.0-service.rc" "$pkg/etc/init/"
cp "$interfaces/graphics/composer/2.1/default/android.hardware.graphics.composer@2.1-service.rc" "$pkg/etc/init/"
(cd "$out/composer-package" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$out/composer-package-SHA256SUMS"
