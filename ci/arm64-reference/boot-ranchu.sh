#!/usr/bin/env bash
set -euo pipefail
image=${1:?SDK image directory}
out=${2:?evidence directory}
kernel="${out%/*}/ranchu-Image"
gzip -dc "$image/kernel-ranchu" > "$kernel"
test "$(od -An -j56 -N4 -tx1 "$kernel" | tr -d '[:space:]')" = 41524d64
sha256sum "$kernel" > "$out/boot-kernel-sha256.txt"
qemu-system-aarch64 --version > "$out/qemu-version.txt"
# Use adjacent virtio-mmio slots for all three disks so Android can
# match platform parent names when generating /dev/block/by-name links.
# Keep stock GPTs and ramdisk intact. Set no AVB or SELinux overrides.
# fstab.ranchu requires a first-stage metadata partition on this MMIO slot.
grep -Fq '/dev/block/platform/a003c00.virtio_mmio/by-name/metadata' "$out/fstab.ranchu"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
metadata="$work/metadata.img"
start=2048
sectors=126944
truncate -s 64M "$metadata"
printf 'label: gpt\nunit: sectors\n\nstart=%d, size=%d, name="metadata"\n' "$start" "$sectors" \
    | sfdisk "$metadata" > "$out/metadata-create.log" 2>&1
sfdisk --json "$metadata" > "$out/metadata-gpt.json"
truncate -s "$((sectors * 512))" "$work/fs.ext4"
mke2fs -q -F -t ext4 -L metadata "$work/fs.ext4"
dd if="$work/fs.ext4" of="$metadata" bs=512 seek="$start" conv=notrunc status=none
args=(
    -machine virt,gic-version=2 -cpu cortex-a57 -accel tcg -smp 2 -m 3072
    -nodefaults -display none -monitor none -serial stdio -no-reboot
    -kernel "$kernel" -initrd "$image/ramdisk.img"
    -append 'console=ttyAMA0 earlycon=pl011,mmio32,0x09000000 rdinit=/init androidboot.hardware=ranchu androidboot.boot_devices=a003a00.virtio_mmio,a003800.virtio_mmio,a003c00.virtio_mmio qemu=1 ignore_loglevel printk.devkmsg=on panic=1'
    -drive "if=none,id=system,file=$image/system.img,format=raw,readonly=on"
    -device virtio-blk-device,drive=system,bus=virtio-mmio-bus.29
    -drive "if=none,id=vendor,file=$image/vendor.img,format=raw,readonly=on"
    -device virtio-blk-device,drive=vendor,bus=virtio-mmio-bus.28
    -drive "if=none,id=metadata,file=$metadata,format=raw,snapshot=on"
    -device virtio-blk-device,drive=metadata,bus=virtio-mmio-bus.30
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
