#!/usr/bin/env bash
set -euo pipefail
export ANDROID_HOME="$PWD/.android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
bash ci/hidl-baseline/build-client.sh
GRAPHICS_HIDL_BUILD=1 bash ci/minigbm-gate/build.sh "$PWD/minigbm-build"
out="$PWD/servicemanager-binary"
mg="$PWD/minigbm-build"
vndk="$PWD/hidl-vndk"
interfaces="$PWD/graphics-interfaces"
git init "$interfaces"
git -C "$interfaces" remote add origin https://android.googlesource.com/platform/hardware/interfaces
timeout 180 git -C "$interfaces" fetch --depth=1 --filter=blob:none origin e7cb492bb835010b3d35496676200250b3b4697e
git -C "$interfaces" sparse-checkout init --cone
git -C "$interfaces" sparse-checkout set graphics/allocator/2.0 graphics/mapper/2.0
 timeout 180 git -C "$interfaces" checkout --detach FETCH_HEAD
# Keep one coherent SDK core runtime; add only missing minigbm dependencies,
# explicitly retaining the libdrm/libsync just built for this module.
python3 - "$mg/guest" "$out/guest" <<'PY'
import pathlib, shutil,sys
src,dst=map(pathlib.Path,sys.argv[1:])
for p in src.rglob('*'):
 if p.is_dir():continue
 target=dst/p.relative_to(src);target.parent.mkdir(parents=True,exist_ok=True)
 if not target.exists() or p.name in ('libdrm.so','libsync.so'):
  shutil.copy2(p.resolve(),target)
PY
# These are real generated ABI libraries from the pinned published VNDK30
# snapshot, not locally substituted interface implementations.
for name in android.hardware.graphics.allocator@2.0.so android.hardware.graphics.mapper@2.0.so android.hardware.graphics.common@1.0.so; do
 if [[ ! -s "$out/guest/system/lib64/$name" ]]; then
  found=0
  for kind in vndk-sp vndk-core; do
   if git -C "$vndk" show "95168a4aced97deb4966ef6f10c8fd6dee9f1582:arm64/arch-arm64-armv8-a/shared/$kind/$name" > "$out/guest/system/lib64/$name.tmp" 2>/dev/null; then
    mv "$out/guest/system/lib64/$name.tmp" "$out/guest/system/lib64/$name"; found=1;break
   fi
  done
  test "$found" = 1 || { echo "Missing genuine graphics interface DSO $name" >&2;exit 1; }
 fi
done
incs=(-isystem "$mg/src/core/libsync/include")
while IFS= read -r p; do incs+=(-isystem "$p"); done < <(find "$vndk/arm64/include" -type d \( -name include -o -name include_vndk -o -name gen \) | grep -v external/libcxx/ | sort)
while IFS= read -r p; do incs+=(-isystem "$p"); done < <(find "$interfaces/graphics" -type d -name include | sort)
cc="$ANDROID_HOME/ndk/21.4.7075529/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang++"
flags=(-std=c++17 -nostdinc++ -isystem "$vndk/arm64/include/external/libcxx/include" -fno-rtti -Wall -Wextra -Werror -O2 "${incs[@]}")
links=(-nostdlib++ -fuse-ld=lld -L"$out/guest/system/lib64" -Wl,-rpath-link,"$out/guest/system/lib64" -lhidlbase -lutils -lcutils -llog -lc++ -lselinux -lhardware -lbase -lsync -l:android.hardware.graphics.allocator@2.0.so -l:android.hardware.graphics.mapper@2.0.so -l:android.hardware.graphics.common@1.0.so)
for api in allocator mapper; do
 "$cc" "${flags[@]}" -fPIC -shared -DLOG_TAG=\"GraphicsFixture\" "$interfaces/graphics/$api/2.0/default/passthrough.cpp" "${links[@]}" -Wl,--no-undefined -o "$out/guest/vendor/lib64/hw/android.hardware.graphics.$api@2.0-impl.so"
done
"$cc" "${flags[@]}" ci/graphics-hidl/fixture.cpp "${links[@]}" -Wl,--dynamic-linker=/system/bin/linker64 -o "$out/guest/system/bin/graphics-fixture"
# Require every direct dependency to be present before boot.
python3 - "$out/guest" <<'PY'
import pathlib,re,subprocess,sys
root=pathlib.Path(sys.argv[1]);libs=root/'system/lib64'
for p in root.rglob('*'):
 if p.is_file() and p.read_bytes()[:4]==b'\x7fELF':
  for dep in re.findall(r'Shared library: \[([^]]+)\]',subprocess.check_output(['readelf','-d',str(p)],text=True)):
   if not (libs/dep).is_file():raise SystemExit(f'Missing runtime {dep} required by {p}')
PY
printf '%s\n' 'hardware/interfaces e7cb492bb835010b3d35496676200250b3b4697e r48; real allocator/mapper 2.0 adapters' > "$out/graphics-sources.txt"
(cd "$out/guest" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$out/hidl-guest-SHA256SUMS"
tar -C "$out/guest" -czf "$out/android11-servicemanager-guest.tar.gz" system vendor
sha256sum "$out/android11-servicemanager-guest.tar.gz" > "$out/guest-archive.sha256"
