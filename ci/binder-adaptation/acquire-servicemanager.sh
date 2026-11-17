#!/usr/bin/env bash
set -euo pipefail
out=servicemanager-binary
mkdir -p "$out"
# Android API 30 (Android 11), ARM64 emulator image.
# The SDK manager resolves the current published revision; record it as evidence.
export ANDROID_HOME="$PWD/.android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
mkdir -p "$ANDROID_HOME/cmdline-tools"
curl -fsSL --retry 4 --connect-timeout 20 \
  https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
  -o "$out/commandline-tools.zip"
unzip -q "$out/commandline-tools.zip" -d "$ANDROID_HOME/cmdline-tools"
mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
# sdkmanager closes stdin once licences are accepted; avoid SIGPIPE from yes
# under pipefail, and still require sdkmanager itself to succeed.
set +e
yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses > "$out/licenses.log" 2>&1
license_status=( "${PIPESTATUS[@]}" )
set -e
license_rc=${license_status[1]}
if (( license_rc != 0 )); then
  cat "$out/licenses.log" >&2
  exit "$license_rc"
fi
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --install \
  'system-images;android-30;google_apis;arm64-v8a' > "$out/sdk-install.log" 2>&1
image="$ANDROID_HOME/system-images/android-30/google_apis/arm64-v8a/system.img"
test -s "$image"
sha256sum "$image" > "$out/system-image.sha256"
file "$image" | tee "$out/image-format.txt"
if file "$image" | grep -q 'Android sparse image'; then
  simg2img "$image" "$out/system.raw.img"
else
  cp "$image" "$out/system.raw.img"
fi
# SDK emulator images can be full GPT disk images, not raw ext4.
# Locate the system partition by GPT name and extract its byte range.
python3 - "$out/system.raw.img" "$out/system.ext4.img" <<'PY'
import os, struct, sys
src, dst = sys.argv[1:]
with open(src, 'rb') as f:
    f.seek(512)
    hdr = f.read(92)
    if hdr[:8] != b'EFI PART':
        print('Not GPT: treating input as standalone filesystem')
        os.link(src, dst)
        sys.exit(0)
    entry_lba = struct.unpack_from('<Q', hdr, 72)[0]
    count, size = struct.unpack_from('<II', hdr, 80)
    sector = 512
    if count > 256 or size < 128 or size > 1024:
        raise RuntimeError('Unexpected GPT entry geometry')
    f.seek(entry_lba * sector)
    entries = f.read(count * size)
    candidates = []
    for i in range(count):
        e = entries[i*size:(i+1)*size]
        if not any(e[:16]):
            continue
        first, last = struct.unpack_from('<QQ', e, 32)
        name = e[56:128].decode('utf-16-le', 'ignore').rstrip('\\x00')
        name = name.replace('\\x00', '')
        print(f'GPT partition {i+1}: {name} sectors {first}-{last}')
        if name.lower().replace('\\x00', '') in ('system', 'system_a', 'super'):
            candidates.insert(0, (first, last, name))
        else:
            candidates.append((first, last, name))
    if not candidates:
        raise RuntimeError('No GPT partitions found')
    for first, last, name in candidates:
        f.seek(first * sector)
        magic = f.read(2048)[1080:1082]
        if magic == b'\\x53\\xef':
            print('Found ext4 partition:', name)
            f.seek(first * sector)
            with open(dst, 'wb') as o:
                remaining = (last-first+1)*sector
                while remaining:
                    data = f.read(min(4*1024*1024, remaining))
                    if not data: raise RuntimeError('Truncated partition')
                    o.write(data)
                    remaining -= len(data)
            break
    else:
        raise RuntimeError('No direct ext4 partition found; likely Android dynamic super partition')
PY
file "$out/system.ext4.img" | tee "$out/filesystem-format.txt"
debugfs -R 'dump /system/bin/servicemanager servicemanager-binary/servicemanager' \
  "$out/system.ext4.img" > "$out/debugfs.log" 2>&1 || true
if ! test -s "$out/servicemanager"; then
  debugfs -R 'dump /bin/servicemanager servicemanager-binary/servicemanager' \
    "$out/system.ext4.img" >> "$out/debugfs.log" 2>&1
fi
test -s "$out/servicemanager"
file "$out/servicemanager" | tee "$out/binary-format.txt"
readelf -h "$out/servicemanager" > "$out/elf-header.txt"
readelf -d "$out/servicemanager" > "$out/dynamic-dependencies.txt"
grep -q 'AArch64' "$out/elf-header.txt"
grep -q 'NEEDED' "$out/dynamic-dependencies.txt"
sha256sum "$out/servicemanager" > "$out/servicemanager.sha256"
cat "$out/dynamic-dependencies.txt"
echo 'PASS Android 11 ARM64 servicemanager ELF extracted; execution NOT yet tested'
