#!/usr/bin/env bash
set -euo pipefail
# Preserve and rebuild the preceding transport client before adding this gate.
bash ci/hidl-baseline/build-client.sh
out="$PWD/servicemanager-binary"
vndk="$PWD/hidl-vndk"
incs=()
while IFS= read -r path; do incs+=(-isystem "$path"); done < <(find "$vndk/arm64/include" -type d \( -name include -o -name include_vndk -o -name gen \) | grep -v 'external/libcxx/' | sort)
cc="$PWD/.android-sdk/ndk/21.4.7075529/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang++"
"$cc" --version > "$out/hidl-compiler.txt"
"$cc" -std=c++17 -nostdinc++ -isystem "$vndk/arm64/include/external/libcxx/include" \
 -Wall -Wextra -Werror -fno-rtti -O2 "${incs[@]}" ci/hidl-service/fixture.cpp \
 -nostdlib++ -fuse-ld=lld -L "$out/guest/system/lib64" \
 -Wl,-rpath-link,"$out/guest/system/lib64" -l:android.hidl.token@1.0.so -lhidlbase -lutils -lcutils -llog -lc++ -lselinux \
 -Wl,--dynamic-linker=/system/bin/linker64 -o "$out/guest/system/bin/hidl-fixture"
readelf -d "$out/guest/system/bin/hidl-fixture" > "$out/hidl-fixture-elf.txt"
for lib in $(readelf -d "$out/guest/system/bin/hidl-fixture" | awk -F'[][]' '/Shared library:/ {print $2}'); do
 test -s "$out/guest/system/lib64/$lib" || { echo "Missing genuine runtime library $lib" >&2; exit 1; }
done

(cd "$out/guest" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$out/hidl-guest-SHA256SUMS"
tar -C "$out/guest" -czf "$out/android11-servicemanager-guest.tar.gz" system
sha256sum "$out/android11-servicemanager-guest.tar.gz" > "$out/guest-archive.sha256"
