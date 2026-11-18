#!/usr/bin/env bash
# Use a fresh, hash-verified Samsung source extraction.
set -euo pipefail
cd "${1:?pass the extracted Samsung source directory}"
export ARCH=arm64
# Start from allnoconfig so unrelated hardware drivers stay out of this guest.
fragment=$(mktemp)
trap 'rm -f "$fragment"' EXIT
cat > "$fragment" <<'CONFIG'
CONFIG_ARCH_VEXPRESS=y
CONFIG_PRINTK=y
CONFIG_TTY=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_BINFMT_ELF=y
CONFIG_DEVTMPFS=y
CONFIG_SHMEM=y
CONFIG_TMPFS=y
CONFIG_TMPFS_XATTR=y
CONFIG_SYSFS=y
CONFIG_PROC_FS=y
CONFIG_PROC_SYSCTL=y
CONFIG_EVENTFD=y
CONFIG_EPOLL=y
CONFIG_TIMERFD=y
CONFIG_SMP=y
CONFIG_HOTPLUG_CPU=y
CONFIG_SCHED_DEBUG=y
CONFIG_SYSCTL=y
CONFIG_EXPERT=y
CONFIG_MULTIUSER=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_SCHED=y
CONFIG_FAIR_GROUP_SCHED=y
CONFIG_MEMCG=y
CONFIG_CMA=y
CONFIG_MIGRATION=y
CONFIG_COMPACTION=y
CONFIG_RT_GROUP_SCHED=y
CONFIG_NET=y
CONFIG_INET=y
CONFIG_AUDIT=y
CONFIG_SECURITY=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITY_SELINUX=y
CONFIG_DEFAULT_SECURITY_SELINUX=y
# CONFIG_SECURITY_SELINUX_DEVELOP is not set
CONFIG_ANDROID=y
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"
CONFIG_VIRTIO_MMIO=y
CONFIG
# The HIDL fixture uses Android's Unix-domain logging/property transports.
# Keep the established native Binder reference configuration unchanged.
if [[ ${HIDL_GUEST:-0} == 1 ]]; then
    echo 'CONFIG_UNIX=y' >> "$fragment"
fi
if [[ -n ${ANDROID_INIT_FRAGMENT:-} ]]; then
    cat "$ANDROID_INIT_FRAGMENT" >> "$fragment"
fi
if [[ ${GRAPHICS_HIDL_GUEST:-0} == 1 ]]; then
    cat "$(dirname "$0")/../drm-buffer-gate/drm.config" >> "$fragment"
    printf 'CONFIG_FUTEX=y\nCONFIG_ADVISE_SYSCALLS=y\n' >> "$fragment"
fi
KCONFIG_ALLCONFIG="$fragment" make allnoconfig
make olddefconfig
for symbol in ARCH_VEXPRESS ARM_GIC ARM_PSCI_FW ARM_ARCH_TIMER VIRTIO_MMIO SERIAL_AMBA_PL011 SERIAL_AMBA_PL011_CONSOLE \
    BLK_DEV_INITRD BINFMT_ELF DEVTMPFS SYSFS PROC_FS SYSCTL EPOLL TIMERFD TMPFS_XATTR SCHED_DEBUG FAIR_GROUP_SCHED MEMCG CMA MIGRATION RT_GROUP_SCHED ANDROID_BINDER_IPC SECURITY_SELINUX DEFAULT_SECURITY_SELINUX; do
    grep -Fxq "CONFIG_$symbol=y" .config || { echo "Missing CONFIG_$symbol=y" >&2; exit 1; }
done
grep -Fx 'CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"' .config
grep -Fx 'CONFIG_DEFAULT_SECURITY="selinux"' .config
if [[ ${HIDL_GUEST:-0} == 1 ]]; then
    grep -Fx 'CONFIG_UNIX=y' .config
fi
for symbol in ARCH_EXYNOS NOBLESSE SECURITY_SMACK SECURITY_SELINUX_DEVELOP; do
    if grep -Eq "^CONFIG_$symbol=[ym]$" .config; then
        echo "Unexpected CONFIG_$symbol" >&2
        exit 1
    fi
done

if [[ ${GRAPHICS_HIDL_GUEST:-0} == 1 ]]; then
    for symbol in PCI PCI_HOST_GENERIC VIRTIO_PCI DRM DRM_VIRTIO_GPU SYNC_FILE FUTEX ADVISE_SYSCALLS; do
        grep -Fx "CONFIG_$symbol=y" .config
    done
fi
