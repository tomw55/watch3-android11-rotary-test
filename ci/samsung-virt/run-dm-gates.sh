#!/usr/bin/env bash
# Disposable ARM64 QEMU guest for dm-default-key gates; never boots watch hardware.
set -euo pipefail
kernel=${1:?compiled Samsung ARM64 Image}
out=${2:?evidence directory}
mkdir -p "$out"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root"/{proc,sys,dev,tmp,run,tests,vectors}
# Alpine's host apk installs *aarch64* packages without running guest code.
docker run --rm -v "$root:/guest" alpine:3.20 sh -ec '
  apk --root /guest --keys-dir /etc/apk/keys --arch aarch64 --initdb --no-scripts \
    --repository https://dl-cdn.alpinelinux.org/alpine/v3.20/main \
    add alpine-baselayout busybox device-mapper util-linux coreutils
'
python3 -c 'from cryptography.hazmat.primitives.ciphers import Cipher' 2>&1 | tee "$out/vector-dependency.log"
python3 scripts/dm-default-key-xts-reference.py --output "$root/vectors" | tee "$out/reference-generation.log"
cp scripts/dm-default-key-gates.sh "$root/tests/gates.sh"
cat > "$root/init" <<'INIT'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/mapper /tmp /run
for i in $(seq 0 7); do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
[ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237
[ -e /dev/mapper/control ] || mknod /dev/mapper/control c 10 236
echo '=== DM DEFAULT KEY GATES BEGIN ==='
dmsetup targets
mkdir -p /tmp/dk
export DK_TEST_DIR=/tmp/dk DK_VECTOR_DIR=/vectors
rc=0
sh /tests/gates.sh || rc=$?
echo "=== DM DEFAULT KEY GATES EXIT $rc ==="
dmesg | tail -100
sync
poweroff -f
INIT
chmod 755 "$root/init"
# The rootfs is an initramfs; ensure its test output is captured via serial.
(cd "$root" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -1) > "$out/gates-initramfs.cpio.gz"
rc=0
timeout 150 qemu-system-aarch64 -machine virt,gic-version=2 -cpu cortex-a57 -accel tcg \
  -smp 2 -m 1024 -nodefaults -display none -monitor none -serial stdio -no-reboot \
  -kernel "$kernel" -initrd "$out/gates-initramfs.cpio.gz" \
  -append 'console=ttyAMA0 earlycon=pl011,mmio32,0x09000000 rdinit=/init panic=1' \
  > "$out/gates-serial.log" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$out/qemu-exit.txt"
grep -Fq '=== DM DEFAULT KEY GATES EXIT 0 ===' "$out/gates-serial.log"
grep -Fq 'PASS gate1:' "$out/gates-serial.log"
grep -Fq 'PASS gate2:' "$out/gates-serial.log"
grep -Fq 'PASS gate3:' "$out/gates-serial.log"
grep -Fq 'PASS error propagation:' "$out/gates-serial.log"
! grep -Ei 'BUG:|WARNING:|kernel panic|Call trace:' "$out/gates-serial.log"
echo 'PASS: QEMU-only dm-default-key gates 1-3'
