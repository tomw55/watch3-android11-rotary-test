#!/usr/bin/env bash
# Raw DRM contract probe in a disposable QEMU virt initramfs.
set -euo pipefail
kernel=$1
headers=$2
out=$3
repo=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$out"
root=$(mktemp -d)
trap 'sudo rm -rf "$root"' EXIT
cc=aarch64-linux-gnu-gcc
{
    "$cc" --version
    qemu-system-aarch64 --version
    uname -a
} > "$out/tool-versions.txt"
# Empty __user matches headers_install's userspace export.
flags=(-std=c11 -Wall -Wextra -Werror -D__user= -I "$headers")
gcc "${flags[@]}" -O2 "$repo/ci/drm-buffer-gate/probe.c" -o "$out/host-probe"
"$out/host-probe" --host-self-test | tee "$out/host-test.log"
gcc "${flags[@]}" -O1 -g -fsanitize=address,undefined     "$repo/ci/drm-buffer-gate/probe.c" -o "$out/host-probe-sanitized"
"$out/host-probe-sanitized" --host-self-test | tee "$out/sanitizer-test.log"
"$cc" "${flags[@]}" -O2 -static "$repo/ci/drm-buffer-gate/probe.c" -o "$root/init"     2>&1 | tee "$out/probe-build.log"
readelf -h -l "$root/init" > "$out/probe-elf.txt"
grep -q AArch64 "$out/probe-elf.txt"
if readelf -l "$root/init" | grep -q INTERP; then
    echo 'FAIL: probe unexpectedly needs a dynamic loader' >&2
    exit 1
fi
cp "$repo/ci/drm-buffer-gate/probe.c" "$out/probe.c"
mkdir -p "$root"/{proc,sys,dev}
sudo mknod "$root/dev/console" c 5 1
(cd "$root" && find . -print0 | cpio --null -o -H newc 2>/dev/null) > "$out/initramfs.cpio"
qemu-system-aarch64 -machine virt -display none -device help > "$out/qemu-devices.txt" 2>&1
args=(-machine virt,gic-version=2 -cpu cortex-a57 -accel tcg -smp 2 -m 1024
    -nodefaults -display none -monitor none -serial stdio -no-reboot
    -device virtio-gpu-pci -kernel "$kernel" -initrd "$out/initramfs.cpio"
    -append 'console=ttyAMA0 earlycon=pl011,mmio32,0x09000000 rdinit=/init panic=1')
printf '%q ' qemu-system-aarch64 "${args[@]}" > "$out/qemu-command.txt"
rc=0
timeout 90 qemu-system-aarch64 "${args[@]}" > "$out/serial.log" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$out/qemu-exit.txt"
cat "$out/serial.log"
grep -Fq 'PASS DRM_RAW_BUFFER_GATE' "$out/serial.log"
for marker in 'PASS primary and render nodes opened' 'PASS PRIME fd export'     'PASS child PRIME import' 'PASS child imported DRM-fd mmap and parent pattern'     'PASS child ADDFB2' 'PASS parent sees child CPU writes' \
    'PASS render resource lifecycle' 'PASS render-created buffer primary-node ADDFB2'; do
    grep -Fq "$marker" "$out/serial.log"
done
if grep -Eq '^FAIL|BUG:|Kernel panic|Call trace:' "$out/serial.log"; then
    echo 'FAIL: raw DRM gate reported an error or kernel fault' >&2
    exit 1
fi
(cd "$out" && sha256sum probe.c initramfs.cpio serial.log > SHA256SUMS)
echo 'PASS raw DRM buffer lifecycle; gralloc/HIDL/EGL/fences/scanout remain NOT RUN'
