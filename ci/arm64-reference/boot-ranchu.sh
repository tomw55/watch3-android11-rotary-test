#!/usr/bin/env bash
set -euo pipefail
image=${1:?SDK image directory}
out=${2:?evidence directory}
kernel="${out%/*}/ranchu-Image"
if [[ -n ${SAMSUNG_INIT_KERNEL:-} ]]; then
    kernel="$SAMSUNG_INIT_KERNEL"
    echo 'Samsung Linux 4.9.59 ARM64 virt integration build' > "$out/kernel-identity.txt"
else
    gzip -dc "$image/kernel-ranchu" > "$kernel"
    printf '%s\n' 'Stock Google API 30 ARM64 kernel-ranchu, SDK image revision 16' \
        'Samsung Linux 4.9: not used' > "$out/kernel-identity.txt"
fi
test "$(od -An -j56 -N4 -tx1 "$kernel" | tr -d '[:space:]')" = 41524d64
sha256sum "$kernel" > "$out/boot-kernel-sha256.txt"
qemu-system-aarch64 --version > "$out/qemu-version.txt"
# Use adjacent virtio-mmio slots for the guest disks so Android can
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
# Android 11 private/file_contexts labels /metadata and /metadata/vold
# differently. Seed only these labels on the disposable filesystem;
# vold must generate the encryption keys itself.
{
    debugfs -w -R 'ea_set / security.selinux u:object_r:metadata_file:s0' "$work/fs.ext4"
    debugfs -w -R 'mkdir /vold' "$work/fs.ext4"
    debugfs -w -R 'set_inode_field /vold mode 040700' "$work/fs.ext4"
    debugfs -w -R 'ea_set /vold security.selinux u:object_r:vold_metadata_file:s0' "$work/fs.ext4"
    debugfs -R 'ea_list /' "$work/fs.ext4"
    debugfs -R 'ea_list /vold' "$work/fs.ext4"
} > "$out/metadata-labels.txt" 2>&1
grep -Fq 'u:object_r:metadata_file:s0' "$out/metadata-labels.txt"
grep -Fq 'u:object_r:vold_metadata_file:s0' "$out/metadata-labels.txt"
dd if="$work/fs.ext4" of="$metadata" bs=512 seek="$start" conv=notrunc status=none
# Lower MMIO slots enumerate first in the verified stock kernel run.
# Keep metadata at slot 30. Shift vendor and system down one slot so
# the dedicated raw ext4 filesystem is the third disk, /dev/block/vdc.
grep -Eq '^/dev/block/vdc[[:space:]]+/data[[:space:]]+ext4[[:space:]]' "$out/fstab.ranchu"
userdata="$work/userdata.ext4"
truncate -s 1G "$userdata"
mke2fs -q -F -t ext4 -O quota,encrypt -L userdata "$userdata"
blkid -p "$userdata" > "$out/userdata-filesystem.txt"
printf '%s\n' \
    'slot=27 address=a003600 expected=vda role=vendor read_only=yes' \
    'slot=28 address=a003800 expected=vdb role=system read_only=yes' \
    'slot=29 address=a003a00 expected=vdc role=userdata read_only=no' \
    'slot=30 address=a003c00 expected=vdd role=metadata snapshot=yes' \
    > "$out/expected-disks.txt"
sha256sum "$userdata" > "$out/userdata-before.sha256"
# QEMU-only diagnostic: install a logcat service in a disposable copy of system.img.
# Do not alter the downloaded SDK image or the kernel configuration.
system_disk="$image/system.img"
if [[ ${CAPTURE_VOLD_LOGCAT:-1} == 1 && -n ${SAMSUNG_INIT_KERNEL:-} ]]; then
    system_disk="$work/system-diagnostic.img"
    cp --reflink=auto "$image/system.img" "$system_disk"
    cat > "$work/dk-logcat.rc" <<'RC'
service dk_vold_logcat /system/bin/logcat -b main -b system -b crash -v threadtime -s vold:V fscrypt:V Cryptfs:V Keymaster:V keymaster:V *:E
    class core
    user root
    group log readproc
    seclabel u:r:logd:s0
    console
    stdio_to_kmsg
    disabled
    oneshot

on post-fs
    start dk_vold_logcat
RC
    debugfs -w -R "write $work/dk-logcat.rc /system/etc/init/dk-logcat.rc" "$system_disk" > "$out/logcat-injection.txt" 2>&1
    debugfs -w -R "ea_set /system/etc/init/dk-logcat.rc security.selinux u:object_r:system_file:s0" "$system_disk" >> "$out/logcat-injection.txt" 2>&1
    debugfs -R "cat /system/etc/init/dk-logcat.rc" "$system_disk" >> "$out/logcat-injection.txt" 2>&1
    grep -Fq 'service dk_vold_logcat' "$out/logcat-injection.txt"
fi
# Test the shipped SwiftShader EGL libraries with a standard virtio GPU.
# Upstream QEMU does not provide Android Emulator renderControl services.
args=(
    -machine virt,gic-version=2 -cpu cortex-a57 -accel tcg -smp 2 -m 3072
    -nodefaults -display none -monitor none -serial stdio -no-reboot
    -kernel "$kernel" -initrd "$image/ramdisk.img"
    -append 'console=ttyAMA0 earlycon=pl011,mmio32,0x09000000 rdinit=/init androidboot.hardware=ranchu androidboot.console=ttyAMA0 androidboot.logcat=*:V androidboot.hardware.egl=swiftshader androidboot.boot_devices=a003800.virtio_mmio,a003600.virtio_mmio,a003c00.virtio_mmio qemu=1 ignore_loglevel printk.devkmsg=on panic=1'
    -drive "if=none,id=system,file=$system_disk,format=raw,readonly=on"
    -device virtio-blk-device,drive=system,bus=virtio-mmio-bus.28
    -drive "if=none,id=vendor,file=$image/vendor.img,format=raw,readonly=on"
    -device virtio-blk-device,drive=vendor,bus=virtio-mmio-bus.27
    -drive "if=none,id=userdata,file=$userdata,format=raw"
    -device virtio-blk-device,drive=userdata,bus=virtio-mmio-bus.29
    -drive "if=none,id=metadata,file=$metadata,format=raw,snapshot=on"
    -device virtio-blk-device,drive=metadata,bus=virtio-mmio-bus.30
    -device virtio-gpu-pci
)
if [[ -n ${SAMSUNG_INIT_KERNEL:-} ]]; then
    # Preserve every disk argument; remove only the graphics-specific trial.
    filtered=()
    for ((i=0; i<${#args[@]}; i++)); do
        if [[ ${args[i]} == -device && ${args[i+1]} == virtio-gpu-pci ]]; then
            ((i+=1))
            continue
        fi
        filtered+=("${args[i]// androidboot.hardware.egl=swiftshader/}")
    done
    args=("${filtered[@]}")
fi
printf '%q '  qemu-system-aarch64 "${args[@]}" > "$out/qemu-command.txt"
printf '\n' >> "$out/qemu-command.txt"
rc=0
timeout 180 qemu-system-aarch64 "${args[@]}" > "$out/serial.log" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$out/qemu-exit.txt"
# Preserve full serial.log; extract BPF diagnostics before the noisy reboot tail.
python3 "$(dirname "$0")/bpf-init-diagnostics.py" "$out" | tee "$out/bpf-init-diagnostics.txt"
# Preserve early storage failures and Zygote/vold aborts separately from restart loops.
python3 "$(dirname "$0")/storage-zygote-diagnostics.py" "$out" "${SAMSUNG_INIT_KERNEL%/*}/.config" | tee "$out/storage-zygote-summary.txt"
# Correlate the observed exit with the kernel's *built* BPF feature set.
if [[ -n ${SAMSUNG_INIT_KERNEL:-} ]]; then
    config="${SAMSUNG_INIT_KERNEL%/*}/.config"
    if [[ -f "$config" ]]; then
        grep -E '^(CONFIG_(BPF|BPF_SYSCALL|BPF_JIT|BPF_EVENTS|CGROUP_BPF|NET_CLS_BPF|NET_ACT_BPF|NET_SCH_INGRESS|NET_CLS_ACT|BPF_STREAM_PARSER|DEBUG_INFO_BTF)=|# CONFIG_(BPF|BPF_SYSCALL|BPF_JIT|BPF_EVENTS|CGROUP_BPF|NET_CLS_BPF|NET_ACT_BPF|NET_SCH_INGRESS|NET_CLS_ACT|BPF_STREAM_PARSER|DEBUG_INFO_BTF) is not set)' "$config" > "$out/bpf-kernel-config.txt" || true
    else
        echo "Built kernel .config unavailable at $config" > "$out/bpf-kernel-config.txt"
    fi
fi
tail -70 "$out/serial.log"
grep -E 'Linux version|virtio_blk| v[d][a-z]:|__mount|mountFstab|sys.boot_completed|eglQueryStringImplementationANDROID|starting service|SystemServer' \
    "$out/serial.log" > "$out/boot-events.txt" || true
# Inspect the guest's post-run filesystem metadata without mounting it.
dumpe2fs -h "$userdata" > "$out/userdata-after.txt" 2>&1 || true
sha256sum "$userdata" > "$out/userdata-after.sha256"
if [[ -n ${SAMSUNG_INIT_KERNEL:-} ]]; then
    # Surface early service failures even when Binder retries fill the tail.
    grep -Ei 'servicemanager|binderfs|binder.*ioctl|avc:.*denied|context.manager|fatal|not implemented|cannot link|could not.*binder|mount.*binder' \
        "$out/serial.log" > "$out/samsung-binder-diagnostics.txt" || true
    sed -n '1,100p' "$out/samsung-binder-diagnostics.txt"
    python3 "$(dirname "$0")/samsung-init-report.py" "$out" | tee "$out/samsung-init-observations.txt"
else
    python3 "$(dirname "$0")/boot-report.py" "$out"
fi
