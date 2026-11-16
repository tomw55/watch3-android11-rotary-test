#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out="$repo/samsung-virt-evidence"
mkdir -p "$out"
stage=source
trap 'rc=$?; printf "stage=%s exit=%s\n" "$stage" "$rc" > "$out/result.txt"' EXIT
work=$(mktemp -d)
cd "$work"
curl -fL --retry 3 -o source.zip \
  https://github.com/tomw55/watch3-android11-rotary-test/releases/download/kernel-source-4.9.59/kernel_samsung_galileo-master.zip
echo '1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f  source.zip' | sha256sum -c - | tee "$out/source-hash.txt"
unzip -q source.zip
cd kernel_samsung_galileo-master
rm -f scripts/basic/{fixdep,.fixdep.cmd} \
  scripts/kconfig/{conf,conf.o,zconf.tab.o,.conf.cmd,.conf.o.cmd,.zconf.tab.o.cmd}
stage=config
export ARCH=arm64
export CROSS_COMPILE
CROSS_COMPILE=$("$repo/scripts/install-kernel-toolchain.sh" "$work/toolchain")
{
    "${CROSS_COMPILE}gcc" --version
    "${CROSS_COMPILE}ld" --version
    aarch64-linux-gnu-gcc --version
    qemu-system-aarch64 --version
    checkpolicy -V
} > "$out/tools.txt"
cp "$repo/ci/samsung-virt/test.conf" "$out/"
# Use the existing accepted and compiler compatibility series, in order.
for patchfile in "$repo"/patches/{accepted,ci-compat}/*.patch; do
    patch --batch --fuzz=0 -p1 < "$patchfile"
done 2>&1 | tee "$out/patches.log"
# Generic CPU hotplug has a Samsung header include but uses none of its declarations.
# Remove that dependency only in this disposable non-Exynos source tree.
grep -Fxq '#include <soc/samsung/exynos-powermode.h>' kernel/cpu.c
sed -i '\|^#include <soc/samsung/exynos-powermode.h>$|d' kernel/cpu.c
# No graphics are needed for this serial-only guest. Samsung's unconditional
# GPU entry otherwise expects arm/built-in.o even with Mali deselected.
grep -Eq '^obj-y[[:space:]]*\+=[[:space:]]*gpu/[[:space:]]*$' drivers/Makefile
sed -i -E '/^obj-y[[:space:]]*\+=[[:space:]]*gpu\/[[:space:]]*$/d' drivers/Makefile
echo "Excluded the GPU subtree from this headless virt build."
# The schedutil object owns this sysctl variable. Do not advertise the
# control when the guest does not build that governor into the kernel.
python3 - <<'PYFIX'
from pathlib import Path
path = Path("kernel/sysctl.c")
source = path.read_text()
old = '#ifndef CONFIG_CPU_FREQ_DEFAULT_GOV_TIZEN_MORION\n\t{\n\t\t.procname\t= "sched_rt_remove_ratio_for_freq",'
new = old.replace(
    "#ifndef CONFIG_CPU_FREQ_DEFAULT_GOV_TIZEN_MORION",
    "#if defined(CONFIG_CPU_FREQ_GOV_SCHEDUTIL) && !defined(CONFIG_CPU_FREQ_DEFAULT_GOV_TIZEN_MORION)",
)
if source.count(old) != 1:
    raise SystemExit("Expected Samsung schedutil sysctl guard exactly once")
path.write_text(source.replace(old, new))
PYFIX
if [[ -n ${REFERENCE_POLICY:-} ]]; then
    # Report the full write result from the kernel. Android's reference
    # policy need not permit this native PID 1 to write to the console.
    python3 - <<'PYLOAD'
from pathlib import Path
p = Path("security/selinux/selinuxfs.c")
s = p.read_text()
old = "\tvfree(data);\n\treturn length;\n}\n\nstatic const struct file_operations sel_load_ops"
assert s.count(old) == 1
new = old.replace(
    "\treturn length;",
    '\tpr_info("virt-policy: load result=%zd bytes=%zu enforcing=%d\\n", length, count, selinux_enforcing);'
    "\n\treturn length;",
)
p.write_text(s.replace(old, new))
PYLOAD
fi
bash "$repo/ci/samsung-virt/configure.sh" "$PWD" 2>&1 | tee "$out/configure.log"
cp .config "$out/config.final"
stage=build
make -k -j"$(nproc)" Image 2>&1 | tee "$out/build.log"
cp arch/arm64/boot/Image System.map "$out/"
test "$(od -An -j56 -N4 -tx1 "$out/Image" | tr -d '[:space:]')" = 41524d64
for symbol in binder_init selinux_init pl011_console_write gic_init_bases psci_dt_init arch_timer_of_init; do
    grep -w "$symbol" "$out/System.map" || echo "Symbol absent: $symbol"
done | tee "$out/symbols.txt"
grep -qw binder_init "$out/System.map"
grep -qw selinux_init "$out/System.map"
(cd "$out" && sha256sum Image System.map config.final > SHA256SUMS)
stage=initramfs
mkdir -p "$work/uapi/linux/android"
cp include/uapi/linux/android/binder.h "$work/uapi/linux/android/"
aarch64-linux-gnu-gcc -std=c11 -Wall -Wextra -Werror -static -O2 \
    -I "$work/uapi" "$repo/ci/samsung-virt/probe.c" -o "$work/init"
checkpolicy -c 30 -o "$work/test.policy" "$out/test.conf" 2>&1 | tee "$out/policy-build.log"
cc -O2 usr/gen_init_cpio.c -o "$work/gen_init_cpio"
cat > "$work/initramfs.list" <<LIST
dir /dev 755 0 0
nod /dev/console 600 0 0 c 5 1
dir /sys 755 0 0
file /init $work/init 755 0 0
file /test.policy $work/test.policy 644 0 0
LIST
"$work/gen_init_cpio" "$work/initramfs.list" > "$out/initramfs.cpio"
cp "$work/test.policy" "$out/"
(cd "$out" && sha256sum Image System.map config.final initramfs.cpio test.policy > SHA256SUMS)
stage=qemu
# A PASS marker must be present even if QEMU is terminated by the timeout.
rc=0
timeout 100 qemu-system-aarch64 -machine virt,gic-version=2 -cpu cortex-a57 \
    -accel tcg -smp 2 -m 1024 -nodefaults -display none -monitor none \
    -serial stdio -no-reboot -kernel "$out/Image" -initrd "$out/initramfs.cpio" \
    -append 'console=ttyAMA0 rdinit=/init rootfstype=ramfs ignore_loglevel audit=1 panic=1' > "$out/serial.log" 2>&1 || rc=$?
printf '%d\n' "$rc" > "$out/qemu-exit.txt"
cat "$out/serial.log"
for marker in 'PASS guest init started' 'PASS /dev/binder protocol=' \
    'PASS /dev/hwbinder protocol=' 'PASS /dev/vndbinder protocol=' \
    'PASS Binder transaction client=' 'PASS SELinux v30 load enforcing allow and denial' \
    'PASS all guest checks'; do
    grep -Fq "$marker" "$out/serial.log" || { echo "Missing: $marker" >&2; exit 1; }
done
stage=complete

if [[ -n ${REFERENCE_POLICY:-} ]]; then
    stage=android_policy
    cp "$REFERENCE_POLICY" "$out/android-policy-v30.bin"
    (cd "$out" && echo 'cefa481b0011472ba4ba9447bb66fe1663716992eda114fb7162408598fb91b5  android-policy-v30.bin' | sha256sum -c -)
    aarch64-linux-gnu-gcc -std=c11 -Wall -Wextra -Werror -static -O2 \
        -DREFERENCE_POLICY -I "$work/uapi" "$repo/ci/samsung-virt/probe.c" -o "$work/init"
    cp "$out/android-policy-v30.bin" "$work/test.policy"
    "$work/gen_init_cpio" "$work/initramfs.list" > "$out/android-policy-initramfs.cpio"
    qemu_rc=0
    timeout 45 qemu-system-aarch64 -machine virt,gic-version=2 -cpu cortex-a57 \
        -accel tcg -smp 2 -m 1024 -nodefaults -display none -monitor none \
        -serial stdio -no-reboot -kernel "$out/Image" -initrd "$out/android-policy-initramfs.cpio" \
        -append 'console=ttyAMA0 rdinit=/init rootfstype=ramfs ignore_loglevel audit=1 panic=1' \
        > "$out/android-policy-serial.log" 2>&1 || qemu_rc=$?
    printf '%s\n' "$qemu_rc" > "$out/android-policy-qemu-exit.txt"
    tail -100 "$out/android-policy-serial.log"
    grep -Fq 'virt-policy: load result=520276 bytes=520276 enforcing=1' "$out/android-policy-serial.log"
    grep -Fq 'policy loaded' "$out/android-policy-serial.log"
    (cd "$out" && sha256sum android-policy-v30.bin android-policy-initramfs.cpio >> SHA256SUMS)
    stage=complete
fi
