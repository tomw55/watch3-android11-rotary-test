#!/usr/bin/env bash
#
# Offline-safe, hash-gated build script for the pinned Samsung
# Exynos9110 "Noblesse" (Tizen Linux 4.9.59) kernel foundation,
# targeting the Galaxy Watch3 SM-R840 (NOBLESSE-LARGE-BT, board
# revision r08).
#
# This script is called by .github/workflows/kernel-build.yml, but is
# also runnable by hand on any Linux machine with network access and
# an aarch64 cross-compiler, for local reproduction.
#
# What this script does NOT do, by design: it never produces a
# flashable boot.img/Odin package, never touches a physical device,
# and never claims a boot-tested result -- see README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$HERE/build-work}"
OUT="${OUT:-$HERE/build-out}"
mkdir -p "$WORK" "$OUT"
WORK="$(realpath "$WORK")"
OUT="$(realpath "$OUT")"
if [[ -e "$OUT/artifacts" || -e "$OUT/exit-codes.txt" ]]; then
    echo "ERROR: use a fresh OUT directory to avoid stale build evidence." >&2
    exit 2
fi

# --- Pinned provenance. Do not change these without re-verifying the
# source against README.md's "Source identification" section. ---
KERNEL_SRC_SHA256="1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f"
KERNEL_SRC_URL="${KERNEL_SRC_URL:-}"   # must be set by the caller (CI secret/var or env)
KERNEL_SRC_LOCAL="${KERNEL_SRC_LOCAL:-}"  # alternative: a local path to the zip, skips download

MODEL=tizen_noblesse
VARIANT_DEFCONFIG="${MODEL}_ci_variant_defconfig"
DTB_TARGET="exynos9110-tizen_noblesse_large_bt-r08.dtb"
ARCH=arm64

echo "== Step 1: obtain the pinned kernel source zip =="
ZIP_PATH="$WORK/kernel_samsung_galileo-master.zip"
if [ -n "$KERNEL_SRC_LOCAL" ]; then
    echo "Using local source: $KERNEL_SRC_LOCAL"
    cp -f "$KERNEL_SRC_LOCAL" "$ZIP_PATH"
elif [ -n "$KERNEL_SRC_URL" ]; then
    echo "Downloading pinned source from the configured URL"
    curl -fL --retry 3 -o "$ZIP_PATH" "$KERNEL_SRC_URL"
else
    echo "ERROR: neither KERNEL_SRC_URL nor KERNEL_SRC_LOCAL is set." >&2
    echo "This build refuses to guess at a source location or substitute" >&2
    echo "a different kernel/device source. Set one of these to point at" >&2
    echo "the exact kernel_samsung_galileo-master.zip this project has" >&2
    echo "already verified (SHA-256 $KERNEL_SRC_SHA256)." >&2
    exit 2
fi

echo "== Step 2: verify SHA-256 against the pinned hash (hard gate) =="
ACTUAL_SHA256="$(sha256sum "$ZIP_PATH" | awk '{print $1}')"
echo "expected: $KERNEL_SRC_SHA256"
echo "actual:   $ACTUAL_SHA256"
if [ "$ACTUAL_SHA256" != "$KERNEL_SRC_SHA256" ]; then
    echo "ERROR: source hash mismatch. Refusing to build from an" >&2
    echo "unverified or substituted source tree. This is not a" >&2
    echo "transient failure to retry -- it means KERNEL_SRC_URL/LOCAL" >&2
    echo "points at the wrong file." >&2
    exit 3
fi
echo "PASS: source hash verified."

echo "== Step 3: extract =="
rm -rf "$WORK/src"
mkdir -p "$WORK/src"
unzip -q "$ZIP_PATH" -d "$WORK/src"
SRC="$(find "$WORK/src" -maxdepth 1 -type d -name 'kernel_samsung_galileo*')"
echo "source tree: $SRC"

echo "== Step 4: apply only the independently accepted safety patches =="
echo "accepted set: $(ls "$HERE/patches/accepted"/*.patch | xargs -n1 basename | tr '\n' ' ')"
echo "held out (not applied) this round: $(ls "$HERE/patches/held"/*.patch 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
cd "$SRC"
# The distribution ZIP carries previously built host tools and .cmd records.
# Keep shipped lexer/parser C sources, but rebuild all bundled host binaries.
rm -f scripts/basic/{fixdep,.fixdep.cmd} \
    scripts/kconfig/{conf,conf.o,zconf.tab.o,.conf.cmd,.conf.o.cmd,.zconf.tab.o.cmd}
for p in "$HERE"/patches/accepted/*.patch; do
    echo "--- applying $(basename "$p") ---"
    patch --batch --forward --fuzz=0 -p1 < "$p"
done
echo "PASS: all accepted patches applied with zero fuzz."
echo "0005 (fuel-gauge) intentionally NOT applied -- held pending resolution of its remaining review findings."

echo "== Step 4b: apply CI compiler-compatibility patches (NOT safety-audit patches) =="
echo "These are evidence-driven source fixes for real GCC build errors seen on"
echo "GitHub Actions (see README.md 'CI fix log'), kept in a separate"
echo "patches/ci-compat/ directory so they are never confused with, and never"
echo "change the count or content of, the independently reviewed safety-audit"
echo "patch set applied above (0001/0002/0003/0004/0006 accepted, 0005 held)."
if ls "$HERE"/patches/ci-compat/*.patch >/dev/null 2>&1; then
    echo "ci-compat set: $(ls "$HERE/patches/ci-compat"/*.patch | xargs -n1 basename | tr '\n' ' ')"
    for p in "$HERE"/patches/ci-compat/*.patch; do
        echo "--- applying $(basename "$p") ---"
        patch --batch --forward --fuzz=0 -p1 < "$p"
    done
    echo "PASS: all ci-compat patches applied with zero fuzz."
else
    echo "no ci-compat patches present this round."
fi

echo "== Step 5: record exact toolchain in use =="
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
export CROSS_COMPILE
export ARCH
if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
    echo "ERROR: ${CROSS_COMPILE}gcc not found on PATH." >&2
    echo "The CI workflow installs this via apt before calling this script;" >&2
    echo "for a local run, install an aarch64 cross-toolchain first." >&2
    exit 4
fi
{
    "${CROSS_COMPILE}gcc" --version
    "${CROSS_COMPILE}gcc" -dumpmachine
    "${CROSS_COMPILE}ld" --version
    "${HOSTCC:-gcc}" --version
    echo "Samsung release.sh uses aarch64-tizen-linux-gnu-; exact DWK2 GCC is unknown."
} | tee "$OUT/toolchain-version.txt"

echo "== Step 6: configure (Noblesse + large + Samsung's default Broadcom fragment) =="
# release.sh appends the brcm fragment for Noblesse when neither hub is explicit.
# LPS22HB in the base config links to sensors_core, which this fragment enables.
{
    cat "arch/$ARCH/configs/${MODEL}_large_defconfig"
    printf '\n'
    cat "arch/$ARCH/configs/${MODEL}_brcm_defconfig"
} > "arch/$ARCH/configs/$VARIANT_DEFCONFIG"
make ARCH=$ARCH "${MODEL}_defconfig" VARIANT_DEFCONFIG="$VARIANT_DEFCONFIG"
if [[ ${ANDROID11_COMPAT:-0} == 1 ]]; then
    echo "== Experimental Android 11 Binder and SELinux configuration =="
    cp .config "$OUT/config.noblesse"
    scripts/config --enable ANDROID --enable ANDROID_BINDER_IPC \
        --set-str ANDROID_BINDER_DEVICES binder,hwbinder,vndbinder \
        --enable SECURITY --enable SECURITY_NETWORK --enable AUDIT \
        --enable SECURITY_SELINUX --disable SECURITY_SMACK \
        --enable DEFAULT_SECURITY_SELINUX \
        --disable SECURITY_SELINUX_DEVELOP \
        --disable SECURITY_SELINUX_BOOTPARAM --disable SECURITY_SELINUX_DISABLE
    make ARCH=$ARCH olddefconfig
    cp .config "$OUT/config.final"
    diff -u "$OUT/config.noblesse" "$OUT/config.final" > "$OUT/config.android11.diff" ||
        [[ $? == 1 ]]
    cat "$OUT/config.android11.diff"
    for expected in CONFIG_ANDROID_BINDER_IPC=y CONFIG_SECURITY_SELINUX=y \
        CONFIG_DEFAULT_SECURITY_SELINUX=y 'CONFIG_DEFAULT_SECURITY="selinux"' \
        'CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"' \
        '# CONFIG_SECURITY_SMACK is not set' \
        '# CONFIG_SECURITY_SELINUX_DEVELOP is not set' \
        '# CONFIG_SECURITY_SELINUX_BOOTPARAM is not set' \
        '# CONFIG_SECURITY_SELINUX_DISABLE is not set'; do
        if ! grep -Fxq "$expected" .config; then
            echo "ERROR: Android 11 configuration did not resolve: $expected" >&2
            exit 5
        fi
    done
fi
cp .config "$OUT/config.final"
required_config=(NOBLESSE NOBLESSE_LARGE INPUT_LPS22HB SENSORS_SSP_BBD SENSORS_SYSFS)
for symbol in "${required_config[@]}"; do
    if ! grep -qx "CONFIG_$symbol=y" .config; then
        echo "ERROR: CONFIG_$symbol did not resolve to y." >&2
        exit 5
    fi
done
grep -E '^CONFIG_(NOBLESSE|NOBLESSE_LARGE|INPUT_LPS22HB|SENSORS_SSP_BBD|SENSORS_SYSFS)=y$' \
    .config | tee "$OUT/config-variant-confirmation.txt"

echo "== Step 7: build Image, the SM-R840 (Noblesse large BT r08) DTB, and modules =="
JOBS="${JOBS:-$(nproc)}"
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: JOBS must be a positive integer."; exit 2; }
# Empty by default. Preserve the kernel's own -Werror warnings policy.
IMAGE_KCFLAGS="${IMAGE_KCFLAGS-}"

set +e
make -k -j"$JOBS" ARCH=$ARCH KCFLAGS="$IMAGE_KCFLAGS" Image 2>&1 | tee "$OUT/build-image.log"
IMAGE_RC=${PIPESTATUS[0]}

# --- Fix 2: arch/arm64/Makefile's own "%.dtb: scripts" pattern rule
# (`$(MAKE) $(build)=$(boot)/dts $(boot)/dts/$@`) ALREADY prepends
# arch/arm64/boot/dts/ to whatever target you pass it. Passing a target
# that already includes that prefix (as this script previously did)
# doubles it into arch/arm64/boot/dts/arch/arm64/boot/dts/..., which has
# no matching rule and fails with "No rule to make target". The correct
# invocation passes only the path relative to arch/arm64/boot/dts/, i.e.
# exynos/<dtb>, exactly as arch/arm64/boot/dts/exynos/Makefile names it.
# Confirmed locally with `make -n` against this exact tree: the old
# (buggy) form produces the doubled path and "No rule to make target";
# this corrected form produces a single, correct dtc invocation.
make -j"$JOBS" ARCH=$ARCH "exynos/${DTB_TARGET}" 2>&1 | tee "$OUT/build-dtb.log"
DTB_RC=${PIPESTATUS[0]}

# --- Fix 3: this defconfig/variant combination may produce a .config with
# `# CONFIG_MODULES is not set`. In that state loadable-module support is
# compiled out entirely, so `make modules` is not a meaningful build step
# and must not be run or scored as pass/fail -- it is skipped, and
# reported with a distinct status rather than an exit code.
if grep -q "^CONFIG_MODULES=y" .config; then
    make -j"$JOBS" ARCH=$ARCH modules 2>&1 | tee "$OUT/build-modules.log"
    MODULES_RC=${PIPESTATUS[0]}
    MODULES_STATUS="$MODULES_RC"
else
    echo "CONFIG_MODULES is not set in .config -- loadable module support is" | tee "$OUT/build-modules.log"
    echo "compiled out for this configuration. Skipping 'make modules'; this" | tee -a "$OUT/build-modules.log"
    echo "is not a build failure." | tee -a "$OUT/build-modules.log"
    MODULES_RC=0
    MODULES_STATUS="SKIPPED (disabled by configuration)"
fi
set -e

echo "== Step 8: collect and hash artifacts =="
mkdir -p "$OUT/artifacts"
cp System.map "$OUT/artifacts/System.map" 2>/dev/null || true
if [[ $IMAGE_RC == 0 ]]; then
    if [[ -s arch/arm64/boot/Image ]] &&
       [[ $(od -An -j56 -N4 -tx1 arch/arm64/boot/Image | tr -d '[:space:]') == 41524d64 ]]; then
        cp arch/arm64/boot/Image "$OUT/artifacts/Image"
    else
        echo "ERROR: make succeeded without a valid ARM64 Image header." >&2
        IMAGE_RC=1
    fi
fi
if [[ $DTB_RC == 0 ]]; then
    dtb="arch/arm64/boot/dts/exynos/${DTB_TARGET}"
    if [[ -s $dtb ]] && [[ $(od -An -N4 -tx1 "$dtb" | tr -d '[:space:]') == d00dfeed ]]; then
        cp "$dtb" "$OUT/artifacts/${DTB_TARGET}"
    else
        echo "ERROR: make succeeded without a valid DTB header." >&2
        DTB_RC=1
    fi
fi
# Note: the cp above addresses the DTB's real filesystem path, which is
# unchanged (arch/arm64/boot/dts/exynos/<dtb>) -- only the make *target
# string* in Step 7 was corrected (Fix 2); the file still lands here.
find . -name '*.ko' -exec cp --parents {} "$OUT/artifacts/modules/" \; 2>/dev/null || true

( cd "$OUT/artifacts" && find . -type f -exec sha256sum {} \; | sort -k2 > "$OUT/ARTIFACT_SHA256SUMS" )
cat "$OUT/ARTIFACT_SHA256SUMS" 2>/dev/null || true

echo "== Step 9: architecture verification =="
if [ -f "$OUT/artifacts/Image" ]; then
    file "$OUT/artifacts/Image" | tee "$OUT/image-file-type.txt"
fi

echo "== Summary =="
echo "Image build exit code:   $IMAGE_RC (KCFLAGS=$IMAGE_KCFLAGS)"
echo "DTB build exit code:     $DTB_RC (target: exynos/${DTB_TARGET})"
echo "Modules build status:    $MODULES_STATUS"
{
  echo "Image build exit code:   $IMAGE_RC (KCFLAGS=$IMAGE_KCFLAGS)"
  echo "DTB build exit code:     $DTB_RC (target: exynos/${DTB_TARGET})"
  echo "Modules build status:    $MODULES_STATUS"
} > "$OUT/exit-codes.txt"

echo
echo "IMPORTANT: a nonzero exit code above here means that stage genuinely"
echo "failed -- it is reported, not hidden or retried silently. A modules"
echo "status of 'SKIPPED (disabled by configuration)' is not a failure --"
echo "it means CONFIG_MODULES was unset in .config, so there is nothing to"
echo "build, and this is reported distinctly rather than scored pass/fail."
echo
echo "This script verifies COMPILATION ONLY. It does not boot, flash, or"
echo "otherwise exercise this kernel on any device, emulator, or bootloader."
echo "SM-R840 remains strictly NO-GO for any hardware interaction."

if [ "$IMAGE_RC" -ne 0 ] || [ "$DTB_RC" -ne 0 ] || [ "$MODULES_RC" -ne 0 ]; then
    exit 1
fi
