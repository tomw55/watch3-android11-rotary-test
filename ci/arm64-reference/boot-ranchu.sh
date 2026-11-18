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
qemu-system-aarch64 -machine virt -display none -device help > "$out/qemu-device-models.txt" 2>&1
qemu-system-aarch64 -machine virt,help > "$out/qemu-virt-options.txt" 2>&1
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
# QEMU-only diagnostic: Android mounts logical vendor from system.img super.
# Modify a disposable copy of that logical partition, preserving its size.
vendor_disk="$image/vendor.img"
system_disk="$image/system.img"
if [[ ${CAPTURE_VOLD_LOGCAT:-1} == 1 && -n ${SAMSUNG_INIT_KERNEL:-} ]]; then
    system_disk="$work/system-diagnostic.img"
    cp --reflink=auto "$image/system.img" "$system_disk"
    sfdisk --json "$system_disk" > "$out/vendor-diagnostic-gpt.json"
    read -r vendor_offset vendor_length < <(python3 - "$out/vendor-diagnostic-gpt.json" <<'PYGPT'
import json, sys
table = json.load(open(sys.argv[1]))["partitiontable"]
parts = [p for p in table["partitions"] if p.get("name") == "super"]
if len(parts) != 1:
    raise SystemExit("Expected exactly one super partition")
print(parts[0]["start"] * table["sectorsize"], parts[0]["size"] * table["sectorsize"])
PYGPT
    )
    [[ $vendor_length -gt 0 && $((vendor_offset + vendor_length)) -le $(stat -c %s "$system_disk") ]]
    dd if="$system_disk" of="$work/super-diagnostic.img" bs=4M \
        iflag=skip_bytes,count_bytes skip="$vendor_offset" count="$vendor_length" status=none
    python3 "$(dirname "$0")/extract-logical.py" "$work/super-diagnostic.img" vendor "$work/vendor-diagnostic.ext4" \
        > "$out/diagnostic-vendor-liblp.json"
    test "$(od -An -j1080 -N2 -tx1 "$work/vendor-diagnostic.ext4" | tr -d '[:space:]')" = 53ef
    # Explicit v1 file encryption for the fresh QEMU filesystem. Metadata
    # encryption keeps its independently validated dm-default-key v2 contract.
    fstab_path=/etc/fstab.ranchu
    debugfs -R "dump $fstab_path $work/fstab.ranchu" "$work/vendor-diagnostic.ext4" > "$out/fscrypt-v1-injection.txt" 2>&1
    test -s "$work/fstab.ranchu"
    cp "$work/fstab.ranchu" "$out/fstab.before-v1"
    python3 "$(dirname "$0")/fscrypt-v1-fstab.py" "$work/fstab.ranchu"
    cp "$work/fstab.ranchu" "$out/fstab.effective-v1"
    debugfs -w -R "rm $fstab_path" "$work/vendor-diagnostic.ext4" >> "$out/fscrypt-v1-injection.txt" 2>&1
    debugfs -w -R "write $work/fstab.ranchu $fstab_path" "$work/vendor-diagnostic.ext4" >> "$out/fscrypt-v1-injection.txt" 2>&1
    debugfs -w -R "set_inode_field $fstab_path uid 0" "$work/vendor-diagnostic.ext4" >> "$out/fscrypt-v1-injection.txt" 2>&1
    debugfs -w -R "set_inode_field $fstab_path gid 0" "$work/vendor-diagnostic.ext4" >> "$out/fscrypt-v1-injection.txt" 2>&1
    debugfs -w -R "set_inode_field $fstab_path mode 0100644" "$work/vendor-diagnostic.ext4" >> "$out/fscrypt-v1-injection.txt" 2>&1
    debugfs -w -R "ea_set $fstab_path security.selinux u:object_r:vendor_configs_file:s0" "$work/vendor-diagnostic.ext4" >> "$out/fscrypt-v1-injection.txt" 2>&1
    debugfs -R "dump $fstab_path $work/fstab.readback" "$work/vendor-diagnostic.ext4" >> "$out/fscrypt-v1-injection.txt" 2>&1
    cmp "$work/fstab.ranchu" "$work/fstab.readback"
    # Use the already-imported ranchu rc rather than relying on new-file discovery.
    rc_path=/etc/init/hw/init.ranchu.rc
    debugfs -R "dump $rc_path $work/init.ranchu.rc" "$work/vendor-diagnostic.ext4" > "$out/logcat-injection.txt" 2>&1
    test -s "$work/init.ranchu.rc"
    cp "$work/init.ranchu.rc" "$work/init.ranchu.original.rc"
    cat >> "$work/init.ranchu.rc" <<'RC'

# QEMU-only diagnostic using the stock shell console domain and serial output.
service dk_vold_logcat /system/bin/sh -c "if [ -d /sys/fs/fuse/connections ]; then echo PASS_QEMU_FUSE_CONNECTIONS; else echo FAIL_QEMU_FUSE_CONNECTIONS; fi; if grep -q ' /sys/fs/fuse/connections fusectl ' /proc/mounts; then echo PASS_QEMU_FUSECTL_MOUNT; else echo NOT_OBSERVED_QEMU_FUSECTL_MOUNT; fi; exec /system/bin/logcat -b main -b system -b crash -v threadtime -s vold:V fscrypt:V Cryptfs:V Keymaster:V keymaster:V Zygote:I ZygoteInit:I installd:V AndroidRuntime:I *:E"
    class core
    user root
    group shell log readproc
    seclabel u:r:shell:s0
    console console
    disabled

on post-fs
    start dk_vold_logcat
RC
    if [[ ${FRAMEWORK_SYSCALL_DIAG:-0} == 1 ]]; then
        cat >> "$work/init.ranchu.rc" <<'TELEMETRY'

# Read-only QEMU diagnostics; no property changes, no policy relaxation.
service qemu_framework_telemetry /system/bin/sh -c "sleep 30; echo QEMU_TELEMETRY_BEGIN; getprop; echo QEMU_SYSTEM_SERVER_PIDS; pidof system_server; cat /proc/meminfo; cat /proc/swaps; grep -E 'pgmajfault|allocstall|pswpin|pswpout' /proc/vmstat; echo QEMU_TELEMETRY_END; sleep 30; echo QEMU_TELEMETRY_BEGIN; getprop; echo QEMU_SYSTEM_SERVER_PIDS; pidof system_server; cat /proc/meminfo; cat /proc/swaps; grep -E 'pgmajfault|allocstall|pswpin|pswpout' /proc/vmstat; echo QEMU_TELEMETRY_END; sleep 30; echo QEMU_TELEMETRY_BEGIN; getprop; echo QEMU_SYSTEM_SERVER_PIDS; pidof system_server; cat /proc/meminfo; cat /proc/swaps; grep -E 'pgmajfault|allocstall|pswpin|pswpout' /proc/vmstat; echo QEMU_TELEMETRY_END; sleep 30; echo QEMU_TELEMETRY_BEGIN; getprop; echo QEMU_SYSTEM_SERVER_PIDS; pidof system_server; cat /proc/meminfo; cat /proc/swaps; grep -E 'pgmajfault|allocstall|pswpin|pswpout' /proc/vmstat; echo QEMU_TELEMETRY_END; true"
    class core
    user root
    group shell log readproc
    seclabel u:r:shell:s0
    console console
    disabled
    oneshot

on post-fs-data
    start qemu_framework_telemetry
TELEMETRY
    fi
    debugfs -w -R "rm $rc_path" "$work/vendor-diagnostic.ext4" >> "$out/logcat-injection.txt" 2>&1
    debugfs -w -R "write $work/init.ranchu.rc $rc_path" "$work/vendor-diagnostic.ext4" >> "$out/logcat-injection.txt" 2>&1
    debugfs -w -R "set_inode_field $rc_path uid 0" "$work/vendor-diagnostic.ext4" >> "$out/logcat-injection.txt" 2>&1
    debugfs -w -R "set_inode_field $rc_path gid 0" "$work/vendor-diagnostic.ext4" >> "$out/logcat-injection.txt" 2>&1
    debugfs -w -R "set_inode_field $rc_path mode 0100644" "$work/vendor-diagnostic.ext4" >> "$out/logcat-injection.txt" 2>&1
    debugfs -w -R "ea_set $rc_path security.selinux u:object_r:vendor_configs_file:s0" "$work/vendor-diagnostic.ext4" >> "$out/logcat-injection.txt" 2>&1
    debugfs -R "stat $rc_path" "$work/vendor-diagnostic.ext4" >> "$out/logcat-injection.txt" 2>&1
    debugfs -R "ea_list $rc_path" "$work/vendor-diagnostic.ext4" >> "$out/logcat-injection.txt" 2>&1
    debugfs -R "cat $rc_path" "$work/vendor-diagnostic.ext4" >> "$out/logcat-injection.txt" 2>&1
    grep -Fq 'service dk_vold_logcat' "$out/logcat-injection.txt"
    grep -Fq 'Mode:  0644' "$out/logcat-injection.txt" || grep -Eq 'Mode: +0100644|Mode: +0644' "$out/logcat-injection.txt"
    grep -Fq 'vendor_configs_file' "$out/logcat-injection.txt"
    python3 "$(dirname "$0")/extract-logical.py" "$work/super-diagnostic.img" vendor "$work/vendor-diagnostic.ext4" --replace
    dd if="$work/super-diagnostic.img" of="$system_disk" bs=4M \
        oflag=seek_bytes seek="$vendor_offset" conv=notrunc status=none
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
    -drive "if=none,id=vendor,file=$vendor_disk,format=raw,readonly=on"
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
    python3 "$(dirname "$0")/check-filecrypto.py" "$out/serial.log" | tee "$out/filecrypto-acceptance.txt"
    grep -Fq 'PASS_QEMU_FUSE_CONNECTIONS' "$out/serial.log"
    if grep -Fq 'No such file or directory [/sys/fs/fuse/connections]' "$out/serial.log"; then
        echo 'FAIL: vold still aborts while enumerating FUSE connections' >&2
        exit 1
    fi
    echo 'PASS: FUSE connections directory present; missing-directory abort absent' > "$out/fuse-acceptance.txt"
else
    python3 "$(dirname "$0")/boot-report.py" "$out"
fi
