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

# --- Pinned provenance. Do not change these without re-verifying the
# source against README.md's "Source identification" section. ---
KERNEL_SRC_SHA256="1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f"
KERNEL_SRC_URL="${KERNEL_SRC_URL:-}"   # must be set by the caller (CI secret/var or env)
KERNEL_SRC_LOCAL="${KERNEL_SRC_LOCAL:-}"  # alternative: a local path to the zip, skips download

MODEL=tizen_noblesse
VARIANT_DEFCONFIG="${MODEL}_large_defconfig"
DTB_TARGET="exynos9110-tizen_noblesse_large_bt-r08.dtb"
ARCH=arm64

mkdir -p "$WORK" "$OUT"

echo "== Step 1: obtain the pinned kernel source zip =="
ZIP_PATH="$WORK/kernel_samsung_galileo-master.zip"
if [ -n "$KERNEL_SRC_LOCAL" ]; then
    echo "Using local source: $KERNEL_SRC_LOCAL"
    cp -f "$KERNEL_SRC_LOCAL" "$ZIP_PATH"
elif [ -n "$KERNEL_SRC_URL" ]; then
    echo "Downloading pinned source from: $KERNEL_SRC_URL"
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
for p in "$HERE"/patches/accepted/*.patch; do
    echo "--- applying $(basename "$p") ---"
    patch --batch --forward --fuzz=0 -p1 < "$p"
done
echo "PASS: all accepted patches applied with zero fuzz."
echo "0005 (fuel-gauge) intentionally NOT applied -- held pending resolution of its remaining review findings."

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
"${CROSS_COMPILE}gcc" --version | tee "$OUT/toolchain-version.txt"
echo "NOTE: the original Samsung/Tizen build used CROSS_COMPILE=aarch64-tizen-linux-gnu-" \
     "(the Tizen SDK's own cross-gcc, exact version not recorded in this source tree)." \
     "This build substitutes the public ${CROSS_COMPILE}gcc toolchain shown above." \
     "This is a documented, intentional deviation -- see README.md -- and means this" \
     "build is reproducible/deterministic in CI, not byte-identical to Samsung's" \
     "factory image." | tee -a "$OUT/toolchain-version.txt"

echo "== Step 6: configure (base defconfig + Watch3/SM-R840 size variant) =="
make ARCH=$ARCH "${MODEL}_defconfig" VARIANT_DEFCONFIG="$VARIANT_DEFCONFIG"
cp .config "$OUT/config.final"
grep -E "^CONFIG_NOBLESSE_(LARGE|SMALL)=y" .config | tee "$OUT/config-variant-confirmation.txt"
if ! grep -q "^CONFIG_NOBLESSE_LARGE=y" .config; then
    echo "ERROR: CONFIG_NOBLESSE_LARGE not set -- the large (45mm, SM-R840-class)" >&2
    echo "variant fragment did not take effect. Refusing to continue silently" >&2
    echo "with the wrong board variant." >&2
    exit 5
fi
echo "PASS: configured for the NOBLESSE_LARGE (45mm, SM-R840-class) variant."

echo "== Step 7: build Image, the SM-R840 (Noblesse large BT r08) DTB, and modules =="
JOBS="$(nproc)"
set +e
make -j"$JOBS" ARCH=$ARCH Image 2>&1 | tee "$OUT/build-image.log"
IMAGE_RC=${PIPESTATUS[0]}
make -j"$JOBS" ARCH=$ARCH "arch/arm64/boot/dts/exynos/${DTB_TARGET}" 2>&1 | tee "$OUT/build-dtb.log"
DTB_RC=${PIPESTATUS[0]}
make -j"$JOBS" ARCH=$ARCH modules 2>&1 | tee "$OUT/build-modules.log"
MODULES_RC=${PIPESTATUS[0]}
set -e

echo "== Step 8: collect and hash artifacts =="
mkdir -p "$OUT/artifacts"
cp System.map "$OUT/artifacts/System.map" 2>/dev/null || true
if [ -f arch/arm64/boot/Image ]; then
    cp arch/arm64/boot/Image "$OUT/artifacts/Image"
fi
if [ -f "arch/arm64/boot/dts/exynos/${DTB_TARGET}" ]; then
    cp "arch/arm64/boot/dts/exynos/${DTB_TARGET}" "$OUT/artifacts/${DTB_TARGET}"
fi
find . -name '*.ko' -exec cp --parents {} "$OUT/artifacts/modules/" \; 2>/dev/null || true

( cd "$OUT/artifacts" && find . -type f -exec sha256sum {} \; | sort -k2 > "$OUT/ARTIFACT_SHA256SUMS" )
cat "$OUT/ARTIFACT_SHA256SUMS" 2>/dev/null || true

echo "== Step 9: architecture verification =="
if [ -f "$OUT/artifacts/Image" ]; then
    file "$OUT/artifacts/Image" | tee "$OUT/image-file-type.txt"
fi

echo "== Summary =="
echo "Image build exit code:   $IMAGE_RC"
echo "DTB build exit code:     $DTB_RC"
echo "Modules build exit code: $MODULES_RC"
{
  echo "Image build exit code:   $IMAGE_RC"
  echo "DTB build exit code:     $DTB_RC"
  echo "Modules build exit code: $MODULES_RC"
} > "$OUT/exit-codes.txt"

echo
echo "IMPORTANT: a nonzero exit code above here means that stage genuinely"
echo "failed -- it is reported, not hidden or retried silently."
echo
echo "This script verifies COMPILATION ONLY. It does not boot, flash, or"
echo "otherwise exercise this kernel on any device, emulator, or bootloader."
echo "SM-R840 remains strictly NO-GO for any hardware interaction."

if [ "$IMAGE_RC" -ne 0 ] || [ "$DTB_RC" -ne 0 ] || [ "$MODULES_RC" -ne 0 ]; then
    exit 1
fi
