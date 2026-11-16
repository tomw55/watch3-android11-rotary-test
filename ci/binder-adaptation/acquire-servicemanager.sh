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
set +o pipefail
yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses > "$out/licenses.log" 2>&1
license_rc=${PIPESTATUS[1]}
set -o pipefail
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
# Inspect ext4 without mounting or privileged loop devices.
debugfs -R 'dump /system/bin/servicemanager servicemanager-binary/servicemanager' \
  "$out/system.raw.img" > "$out/debugfs.log" 2>&1 || \
debugfs -R 'dump /bin/servicemanager servicemanager-binary/servicemanager' \
  "$out/system.raw.img" >> "$out/debugfs.log" 2>&1
test -s "$out/servicemanager"
file "$out/servicemanager" | tee "$out/binary-format.txt"
readelf -h "$out/servicemanager" > "$out/elf-header.txt"
readelf -d "$out/servicemanager" > "$out/dynamic-dependencies.txt"
grep -q 'AArch64' "$out/elf-header.txt"
grep -q 'NEEDED' "$out/dynamic-dependencies.txt"
sha256sum "$out/servicemanager" > "$out/servicemanager.sha256"
cat "$out/dynamic-dependencies.txt"
echo 'PASS Android 11 ARM64 servicemanager ELF extracted; execution NOT yet tested'
