#!/usr/bin/env bash
set -euo pipefail
image=${1:?SDK image directory}
out=${2:?evidence directory}
kernel="${out%/*}/ranchu-Image"
gzip -dc "$image/kernel-ranchu" > "$kernel"
test "$(od -An -j56 -N4 -tx1 "$kernel" | tr -d '[:space:]')" = 41524d64
sha256sum "$kernel" > "$out/boot-kernel-sha256.txt"
qemu-system-aarch64 --version > "$out/qemu-version.txt"
# These PCI positions are a test mapping based on the API 30 reference
# emulator. The ARM64 stock fstab is captured for comparison.
# Keep stock GPTs and ramdisk intact. Set no AVB or SELinux overrides.
args=(
    -machine virt,gic-version=2 -cpu cortex-a57 -accel tcg -smp 2 -m 3072
    -nodefaults -display none -monitor none -serial stdio -no-reboot
    -kernel "$kernel" -initrd "$image/ramdisk.img"
    -append 'console=ttyAMA0 earlycon=pl011,mmio32,0x09000000 rdinit=/init androidboot.hardware=ranchu androidboot.boot_devices=pci0000:00/0000:00:03.0,pci0000:00/0000:00:06.0 qemu=1 loglevel=7 panic=1'
    -drive "if=none,id=system,file=$image/system.img,format=raw,readonly=on"
    -device virtio-blk-pci,drive=system,addr=0x3
    -drive "if=none,id=vendor,file=$image/vendor.img,format=raw,readonly=on"
    -device virtio-blk-pci,drive=vendor,addr=0x6
)
printf '%q ' qemu-system-aarch64 "${args[@]}" > "$out/qemu-command.txt"
printf '\n' >> "$out/qemu-command.txt"
rc=0
timeout 120 qemu-system-aarch64 "${args[@]}" > "$out/serial.log" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$out/qemu-exit.txt"
tail -70 "$out/serial.log"
first='NOT OBSERVED'
second='NOT OBSERVED'
if grep -qi 'init first stage started' "$out/serial.log"; then first=OBSERVED; fi
if grep -qi 'init second stage started' "$out/serial.log"; then second=OBSERVED; fi
printf 'first_stage=%s\nsecond_stage=%s\n' "$first" "$second" > "$out/boot-observations.txt"
[[ $first == OBSERVED && $second == OBSERVED ]]
