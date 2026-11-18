#!/usr/bin/env bash
# Build real API-30 gralloc0 callbacks; no vendor image or full AOSP build.
set -euo pipefail
out=$(realpath -m "${1:?output}")
repo=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$out"/{src,obj,guest/system/bin,guest/system/lib64,guest/vendor/lib64/hw}
stage=source_preparation
trap 'rc=$?; printf "stage=%s exit=%s\n" "$stage" "$rc" > "$out/build-result.txt"' EXIT
clone() {
 local name=$1 url=$2 pin=$3
 shift 3
 git init "$out/src/$name"
 git -C "$out/src/$name" remote add origin "$url"
 timeout 180 git -C "$out/src/$name" fetch --depth=1 --filter=blob:none origin "$pin"
 test "$(git -C "$out/src/$name" rev-parse FETCH_HEAD)" = "$pin"
 if (( $# )); then
  git -C "$out/src/$name" sparse-checkout init --cone
  git -C "$out/src/$name" sparse-checkout set "$@"
  timeout 180 git -C "$out/src/$name" checkout --detach "$pin"
 else
  timeout 180 git -C "$out/src/$name" checkout --detach "$pin"
 fi
 printf '%s %s %s\n' "$name" "$pin" "$url" >> "$out/sources.txt"
}
clone minigbm https://android.googlesource.com/platform/external/minigbm a3120e47088d7b898acca9ee55825ccbc03f427c
clone libdrm https://android.googlesource.com/platform/external/libdrm 9d5089ee87931edcf5ba01949e0a11cf1a52b471
# API 30 platform headers and ABI libraries, published in the VNDK-v30 snapshot.
# This supporting snapshot is pinned separately and is NOT an r48 source tree.
clone vndk https://android.googlesource.com/platform/prebuilts/vndk/v30 95168a4aced97deb4966ef6f10c8fd6dee9f1582 arm64/include
clone core https://android.googlesource.com/platform/system/core 348efca472d810d3152568913da41a081893a4e3 libsync
mg="$out/src/minigbm"; drm="$out/src/libdrm"; vndk="$out/src/vndk"
git -C "$mg" apply --check "$repo/ci/minigbm-gate/qemu49-render-2d.patch"
git -C "$mg" apply "$repo/ci/minigbm-gate/qemu49-render-2d.patch"
if [[ ${GRAPHICS_HIDL_BUILD:-0} == 1 ]]; then
 git -C "$mg" apply --check "$repo/ci/graphics-hidl/native-handle-accounting.patch"
 git -C "$mg" apply "$repo/ci/graphics-hidl/native-handle-accounting.patch"
 python3 "$repo/ci/graphics-hidl/test-handle-accounting.py" "$mg" "$out"
fi
cp "$repo/ci/minigbm-gate/qemu49_layout.h" "$mg/"
python3 "$repo/ci/minigbm-gate/test-backend.py" "$mg" "$drm" "$repo/ci/minigbm-gate" "$out"
stage=toolchain
ndk="${ANDROID_HOME:?}/ndk/27.2.12479018/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [[ ! -x "$ndk/aarch64-linux-android30-clang" ]]; then
 "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" 'ndk;27.2.12479018'
fi
cc="$ndk/aarch64-linux-android30-clang"; cxx="$ndk/aarch64-linux-android30-clang++"
"$cc" --version > "$out/compiler.txt"
incs=(-I"$mg" -I"$drm" -I"$drm/include/drm" -I"$drm/android" -I"$out/src/core/libsync/include")
while IFS= read -r p; do incs+=(-I"$p"); done < <(find "$vndk/arm64/include" -type d \( -name include -o -name include_vndk \) | grep -v 'external/libcxx/' | sort)
incs+=(-I"$vndk/arm64/include/system/core/libcutils/include_vndk")
base=(-O2 -g -fPIC -D_GNU_SOURCE=1 -D_FILE_OFFSET_BITS=64 -DANDROID_VERSION=0x0b00 -Wall -Wextra -Wno-unused-parameter "${incs[@]}")
lib="$out/guest/system/lib64"
# Use the platform __1 C++ ABI, not the NDK __ndk1 ABI.
cpp=(-nostdinc++ -isystem "$vndk/arm64/include/external/libcxx/include" -std=c++14)
for n in libc++.so libcutils.so libhardware.so; do
 git -C "$vndk" show "95168a4aced97deb4966ef6f10c8fd6dee9f1582:arm64/arch-arm64-armv8-a/shared/vndk-sp/$n" > "$lib/$n"
done
stage=libdrm_compile
for f in xf86drm xf86drmHash xf86drmRandom xf86drmSL xf86drmMode; do
 "$cc" "${base[@]}" -DMAJOR_IN_SYSMACROS=1 -DHAVE_VISIBILITY=1 -DHAVE_LIBDRM_ATOMIC_PRIMITIVES=1 -c "$drm/$f.c" -o "$out/obj/$f.o"
done
"$cc" -shared -Wl,-soname,libdrm.so -Wl,--no-undefined "$out"/obj/xf86*.o -lm -o "$lib/libdrm.so"
"$cc" "${base[@]}" -shared -Wl,-soname,libsync.so -Wl,--no-undefined "$out/src/core/libsync/sync.c" -o "$lib/libsync.so"
stage=minigbm_compile
cs=(amdgpu drv evdi exynos helpers_array helpers i915 marvell mediatek meson msm nouveau radeon rockchip tegra udl vc4 vgem virtio_gpu)
"$cc" "${base[@]}" -c "$mg/virtio_gpu.c" -o "$out/obj/virtio-profile-disabled.o"
for f in "${cs[@]}"; do
 "$cc" "${base[@]}" -DMINIGBM_QEMU49_RENDER_2D -c "$mg/$f.c" -o "$out/obj/mg-$f.o"
done
for f in cros_gralloc_buffer cros_gralloc_helpers cros_gralloc_driver; do
 "$cxx" "${base[@]}" "${cpp[@]}" -c "$mg/cros_gralloc/$f.cc" -o "$out/obj/$f.o"
done
"$cxx" "${base[@]}" "${cpp[@]}" -c "$mg/cros_gralloc/gralloc0/gralloc0.cc" -o "$out/obj/gralloc0.o"
"$cxx" -nostdlib++ -shared -Wl,-soname,gralloc.minigbm.so -Wl,--no-undefined \
 "$out"/obj/mg-*.o "$out"/obj/cros_gralloc*.o "$out/obj/gralloc0.o" \
 -L"$lib" -lc++ -lcutils -ldrm -lsync -llog -o "$out/guest/vendor/lib64/hw/gralloc.minigbm.so"
# Default alias is confined to this disposable fixture: exercise hw_get_module
# without pretending ro.hardware.gralloc/property-service integration was tested.
ln -s gralloc.minigbm.so "$out/guest/vendor/lib64/hw/gralloc.default.so"
"$cc" "${base[@]}" -std=c11 -Werror "$repo/ci/minigbm-gate/callback.c" \
 -L"$lib" -lhardware -lcutils -ldrm -ldl -o "$out/guest/system/bin/gralloc-gate"
stage=bionic_runtime
python3 "$repo/ci/minigbm-gate/runtime.py" "$out" "$repo"
readelf -d "$out/guest/vendor/lib64/hw/gralloc.minigbm.so" > "$out/module-elf.txt"
readelf -d "$out/guest/system/bin/gralloc-gate" > "$out/probe-elf.txt"
(cd "$out/guest" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$out/guest-SHA256SUMS"
