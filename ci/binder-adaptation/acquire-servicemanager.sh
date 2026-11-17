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
  'system-images;android-30;google_apis;arm64-v8a' 'ndk;27.2.12479018' > "$out/sdk-install.log" 2>&1
image="$ANDROID_HOME/system-images/android-30/google_apis/arm64-v8a/system.img"
test -s "$image"
sha256sum "$image" > "$out/system-image.sha256"
file "$image" | tee "$out/image-format.txt"
if file "$image" | grep -q 'Android sparse image'; then
  simg2img "$image" "$out/system.raw.img"
else
  cp "$image" "$out/system.raw.img"
fi
# Extract GPT 'super' partition; then unpack Android logical partitions with AOSP lpunpack.
python3 - "$out/system.raw.img" "$out" <<'PY'
import os, struct, sys
src, out = sys.argv[1:]
with open(src, 'rb') as f:
    f.seek(512)
    hdr = f.read(92)
    if hdr[:8] != b'EFI PART':
        print('No GPT; input may be a standalone ext4 filesystem', flush=True)
        os.link(src, os.path.join(out, 'system.ext4.img'))
        sys.exit(0)
    entry_lba = struct.unpack_from('<Q', hdr, 72)[0]
    count, size = struct.unpack_from('<II', hdr, 80)
    if count > 256 or size < 128 or size > 1024:
        raise RuntimeError('Unexpected GPT entry geometry')
    f.seek(entry_lba * 512)
    entries = f.read(count * size)
    partitions = []
    for i in range(count):
        e = entries[i*size:(i+1)*size]
        if not any(e[:16]): continue
        first, last = struct.unpack_from('<QQ', e, 32)
        name = e[56:128].decode('utf-16-le', 'ignore').rstrip(chr(0))
        print(f'GPT partition {i+1}: {name} sectors {first}-{last}', flush=True)
        partitions.append((name, first, last))
    for target in ('super', 'system', 'system_a'):
        match = next((p for p in partitions if p[0] == target), None)
        if match is None: continue
        name, first, last = match
        dst = os.path.join(out, 'super.img' if target == 'super' else 'system.ext4.img')
        f.seek(first * 512)
        with open(dst, 'wb') as o:
            remaining = (last-first+1)*512
            while remaining:
                chunk = f.read(min(4*1024*1024, remaining))
                if not chunk: raise RuntimeError('Truncated GPT partition')
                o.write(chunk)
                remaining -= len(chunk)
        print('Extracted GPT partition:', name, flush=True)
        break
    else:
        raise RuntimeError('No super/system partition in GPT')
PY
if test -s "$out/super.img"; then
  mkdir -p "$out/logical"
  # Pinned, inspectable Python implementation; Ubuntu 22.04 lacks lpunpack.
  curl -fsSL --retry 4 \
    https://raw.githubusercontent.com/unix3dgforce/lpunpack/c59b8f3b069c5a8aa438a049fa4a091177172434/lpunpack.py \
    -o "$out/lpunpack.py"
  sha256sum "$out/lpunpack.py" > "$out/lpunpack-source.sha256"
  python3 "$out/lpunpack.py" "$out/super.img" "$out/logical" | tee "$out/lpunpack.log"
  find "$out/logical" -maxdepth 1 -type f -printf '%f %s bytes\\n' | tee "$out/logical-partitions.txt"
  for name in system_a system; do
    if test -s "$out/logical/$name.img"; then
      mv "$out/logical/$name.img" "$out/system.ext4.img"
      break
    fi
  done
fi
test -s "$out/system.ext4.img" || { echo "No logical system partition found" >&2; exit 1; }
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

# Export the Android dynamic linker and recursive ELF dependencies for a QEMU guest.
# This uses the same extracted Android 11 system image as the executable.
mkdir -p "$out/guest/system/bin" "$out/guest/system/lib64"
cp "$out/servicemanager" "$out/guest/system/bin/servicemanager"
python3 - "$out/system.ext4.img" "$out/guest" <<'PY'
import os, pathlib, re, subprocess, sys
image, root = sys.argv[1:]
root = pathlib.Path(root)
pending = ["/system/bin/linker64", "/system/bin/servicemanager", "/system/bin/service", "/system/lib64/libbinder_ndk.so"]
seen = set()
missing = []
while pending:
    path = pending.pop(0)
    if path in seen: continue
    seen.add(path)
    relative = path.removeprefix("/system/")
    dest = root / "system" / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(["debugfs", "-R", f"dump {path} {dest}", image],
                          capture_output=True, text=True)
    if proc.returncode or not dest.is_file() or not dest.stat().st_size:
        # ext4 root may itself be the system partition.
        proc = subprocess.run(["debugfs", "-R", f"dump /{relative} {dest}", image],
                              capture_output=True, text=True)
    if proc.returncode or not dest.is_file() or not dest.stat().st_size:
        # Android 11 uses symlinks from /system/bin/linker64 and
        # /system/lib64/{libc,libm,libdl}.so to runtime APEX files.
        # The early-boot bootstrap copies are real ELF files on /system.
        fallback = []
        if path == "/system/bin/linker64":
            fallback = ["/bin/bootstrap/linker64", "/system/bin/bootstrap/linker64"]
        elif path.startswith("/system/lib64/"):
            lib = path.rsplit("/", 1)[-1]
            fallback = ["/lib64/bootstrap/" + lib, "/system/lib64/bootstrap/" + lib]
        for source in fallback:
            proc = subprocess.run(["debugfs", "-R", f"dump {source} {dest}", image],
                                  capture_output=True, text=True)
            if proc.returncode == 0 and dest.is_file() and dest.stat().st_size:
                print(f"BOOTSTRAP {source} -> {path}", flush=True)
                break
        else:
            missing.append(path)
            continue
    hdr = subprocess.run(["readelf", "-h", str(dest)], capture_output=True, text=True)
    if "AArch64" not in hdr.stdout:
        raise RuntimeError(f"Not AArch64: {path}")
    dyn = subprocess.run(["readelf", "-d", str(dest)], capture_output=True, text=True)
    for lib in re.findall(r"Shared library: \[([^]]+)\]", dyn.stdout):
        dep = "/system/lib64/" + lib
        if dep not in seen and dep not in pending:
            pending.append(dep)
    print(f"EXTRACTED {path}", flush=True)
if missing:
    raise RuntimeError("Missing Android shared libraries: " + ", ".join(missing))
(root.parent / "guest-manifest.txt").write_text("\\n".join(sorted(seen)) + "\\n")
print("PASS Android 11 servicemanager and service client ELF dependencies packaged", flush=True)
PY
# Android's servicemanager requires the platform SELinux service label map.
# Copy it from the same Android 11 image instead of silently omitting it.
mkdir -p "$out/guest/system/etc/selinux"
contexts="$out/guest/system/etc/selinux/plat_service_contexts"
for source in /system/etc/selinux/plat_service_contexts /etc/selinux/plat_service_contexts; do
  rm -f "$contexts"
  debugfs -R "dump $source $contexts" "$out/system.ext4.img" >/dev/null 2>&1 || true
  if test -s "$contexts"; then
    echo "EXTRACTED Android 11 SELinux service contexts: $source"
    break
  fi
done
if ! test -s "$contexts"; then
  echo "WARN Android 11 platform service contexts absent from image" >&2
  rm -f "$contexts"
fi
# Compile against the Android NDK Binder API, but link to the genuine
# Android 11 runtime extracted from the emulator system partition.
ndk="$ANDROID_HOME/ndk/27.2.12479018/toolchains/llvm/prebuilt/linux-x86_64/bin"
"$ndk/aarch64-linux-android30-clang++" -std=c++17 -Wall -Wextra -Werror -O2 \
  "$PWD/ci/binder-adaptation/register-test-service-ndk.cpp" \
  -L "$out/guest/system/lib64" -lbinder_ndk \
  -Wl,--dynamic-linker=/system/bin/linker64 \
  -o "$out/guest/system/bin/register-test-service-ndk"
readelf -d "$out/guest/system/bin/register-test-service-ndk" | tee "$out/ndk-registrar-dependencies.txt"
# Ensure the runtime has every shared library the new executable requires.
for lib in $(readelf -d "$out/guest/system/bin/register-test-service-ndk" | sed -n 's/.*Shared library: \\[\\([^]]*\\)\\].*/\\1/p'); do
  test -s "$out/guest/system/lib64/$lib" || { echo "Missing NDK registrar library: $lib" >&2; exit 1; }
done
tar -C "$out/guest" -czf "$out/android11-servicemanager-guest.tar.gz" system
sha256sum "$out/android11-servicemanager-guest.tar.gz" > "$out/guest-archive.sha256"
