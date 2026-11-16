#!/usr/bin/env bash
# Use a fresh, hash-verified Samsung source extraction.
set -euo pipefail
cd "${1:?pass the extracted Samsung source directory}"
export ARCH=arm64
make defconfig
scripts/config --enable ARCH_VEXPRESS --disable ARCH_EXYNOS --enable SERIAL_AMBA_PL011 \
    --enable SERIAL_AMBA_PL011_CONSOLE --enable BLK_DEV_INITRD \
    --enable DEVTMPFS --enable TMPFS --enable TMPFS_XATTR \
    --enable ANDROID --enable ANDROID_BINDER_IPC \
    --set-str ANDROID_BINDER_DEVICES binder,hwbinder,vndbinder \
    --enable SECURITY --enable SECURITY_NETWORK --enable AUDIT \
    --enable SECURITY_SELINUX --enable DEFAULT_SECURITY_SELINUX \
    --disable SECURITY_SMACK --disable SECURITY_SELINUX_DEVELOP \
    --disable SECURITY_SELINUX_BOOTPARAM --disable SECURITY_SELINUX_DISABLE
make olddefconfig
for symbol in ARCH_VEXPRESS ARM_GIC ARM_PSCI_FW ARM_ARCH_TIMER VIRTIO_MMIO SERIAL_AMBA_PL011 SERIAL_AMBA_PL011_CONSOLE \
    BLK_DEV_INITRD DEVTMPFS TMPFS_XATTR ANDROID_BINDER_IPC SECURITY_SELINUX DEFAULT_SECURITY_SELINUX; do
    grep -Fxq "CONFIG_$symbol=y" .config || { echo "Missing CONFIG_$symbol=y" >&2; exit 1; }
done
grep -Fx 'CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"' .config
grep -Fx 'CONFIG_DEFAULT_SECURITY="selinux"' .config
for symbol in ARCH_EXYNOS NOBLESSE SECURITY_SMACK SECURITY_SELINUX_DEVELOP; do
    if grep -Eq "^CONFIG_$symbol=[ym]$" .config; then
        echo "Unexpected CONFIG_$symbol" >&2
        exit 1
    fi
done
