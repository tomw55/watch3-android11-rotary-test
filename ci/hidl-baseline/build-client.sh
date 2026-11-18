#!/usr/bin/env bash
set -euo pipefail
out="$PWD/servicemanager-binary"
vndk="$PWD/hidl-vndk"
git init "$vndk"
git -C "$vndk" remote add origin https://android.googlesource.com/platform/prebuilts/vndk/v30
timeout 180 git -C "$vndk" fetch --depth=1 --filter=blob:none origin 95168a4aced97deb4966ef6f10c8fd6dee9f1582
git -C "$vndk" sparse-checkout init --cone
git -C "$vndk" sparse-checkout set arm64/include
timeout 180 git -C "$vndk" checkout --detach FETCH_HEAD
incs=()
while IFS= read -r path; do incs+=(-isystem "$path"); done < <(find "$vndk/arm64/include" -type d \( -name include -o -name include_vndk -o -name gen \) | grep -v 'external/libcxx/' | sort)
cc="$PWD/.android-sdk/ndk/21.4.7075529/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang++"
"$cc" --version > "$out/hidl-compiler.txt"
"$cc" -std=c++17 -nostdinc++ -isystem "$vndk/arm64/include/external/libcxx/include" \
 -Wall -Wextra -Werror -O2 "${incs[@]}" ci/hidl-baseline/client.cpp \
 -nostdlib++ -L "$out/guest/system/lib64" -lhidlbase -lutils -lcutils -llog -lc++ -lselinux \
 -Wl,--dynamic-linker=/system/bin/linker64 -o "$out/guest/system/bin/hidl-client"
readelf -d "$out/guest/system/bin/hidl-client" > "$out/hidl-client-elf.txt"
for lib in $(readelf -d "$out/guest/system/bin/hidl-client" | awk -F'[][]' '/Shared library:/ {print $2}'); do
 test -s "$out/guest/system/lib64/$lib" || { echo "Missing genuine runtime library $lib" >&2; exit 1; }
done
printf '%s\n' 'Supplementary API30 generated/platform headers: platform/prebuilts/vndk/v30 95168a4aced97deb4966ef6f10c8fd6dee9f1582' > "$out/hidl-source.txt"
(cd "$out/guest" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$out/hidl-guest-SHA256SUMS"
tar -C "$out/guest" -czf "$out/android11-servicemanager-guest.tar.gz" system
