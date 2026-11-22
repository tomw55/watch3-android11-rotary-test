#!/usr/bin/env bash
# Compile-only isolated ARM64 Kbuild check. Never produces Image/boot.img/modules.
set -euo pipefail
[[ $# == 3 ]] || { echo "usage: $0 KERNEL_SOURCE CROSS_COMPILE_PREFIX OUTPUT" >&2; exit 2; }
inputs=$(cd -- "$(dirname -- "$0")" && pwd)
src=$(cd -- "$1" && pwd)
cross=$2
mkdir -p -- "$3"
out=$(cd -- "$3" && pwd)
[[ ! -e "$out/kbuild" ]] || { echo 'Use a fresh output directory' >&2; exit 2; }
mkdir -p "$out/tmp"
export TMPDIR="$out/tmp"
pin=1c06f4ebe0a9788b9d5f0f4ecb43209dee28950b
panel=drivers/video/fbdev/exynos/dpu30/panels
[[ $(git -C "$src" rev-parse HEAD) == "$pin" ]]
git -C "$src" diff --exit-code
[[ -z $(git -C "$src" ls-files --others --exclude-standard) ]]
[[ $("${cross}gcc" -dumpmachine) == aarch64-linux ]]
[[ $("${cross}gcc" -dumpversion) == 7.5.0 ]]
"${cross}gcc" --version > "$out/compiler.txt"
"${cross}ld" --version > "$out/linker.txt"
git -C "$src" rev-parse HEAD > "$out/source-commit.txt"
(cd "$inputs/patches" && sha256sum -c SHA256SUMS) | tee "$out/patch-hashes.log"
for name in 0001-noblesse-panel-review.patch 0002-noblesse-dimming-review.patch 0003-dpu30-notifier-private-storage.patch 0004-dimming-real-kernel-macro-hygiene.patch; do
    patch --dry-run -d "$src" -p1 < "$inputs/patches/$name"
    patch -d "$src" -p1 < "$inputs/patches/$name"
done > "$out/patch-apply.log" 2>&1
build=(make -C "$src" O="$out/kbuild" ARCH=arm64 CROSS_COMPILE="$cross" V=1)
mkdir -p "$out/kbuild"
"${build[@]}" erd9110_defconfig 2>&1 | tee "$out/defconfig.log"
"$src/scripts/kconfig/merge_config.sh" -m -O "$out/kbuild" \
    "$out/kbuild/.config" "$inputs/watch3-baseline.config" 2>&1 | tee "$out/merge.log"
"${build[@]}" olddefconfig 2>&1 | tee "$out/default-resolution.log"
cp "$out/kbuild/.config" "$out/config.review-off"
for sym in EXYNOS_NOBLESSE_PANEL_REVIEW EXYNOS_NOBLESSE_DIMMING_REVIEW; do
    if grep -Eq "^CONFIG_${sym}=(y|m)$" "$out/config.review-off"; then
        echo "Unexpected enabled review option: $sym" >&2; exit 1
    fi
    # Kconfig can omit dependency-disabled booleans instead of emitting '# ...'.
    printf '%s\n' "CONFIG_${sym} disabled in resolved configuration"
done
strict=(CFLAGS_exynos_panel_drv.o=-Werror CFLAGS_noblesse-panel-seq.o=-Werror
    CFLAGS_noblesse-panel-transport.o=-Werror CFLAGS_noblesse-dimming.o=-Werror)
"${build[@]}" -j"${JOBS:-2}" "${strict[@]}" "$panel/exynos_panel_drv.o" 2>&1 | tee "$out/compile-review-off.log"
cp "$out/kbuild/$panel/exynos_panel_drv.o" "$out/exynos_panel_drv.review-off.o"
"$src/scripts/config" --file "$out/kbuild/.config" \
    --enable EXYNOS_NOBLESSE_PANEL_REVIEW --enable EXYNOS_NOBLESSE_DIMMING_REVIEW
"${build[@]}" olddefconfig 2>&1 | tee "$out/review-resolution.log"
cp "$out/kbuild/.config" "$out/config.review-on"
for sym in EXYNOS_DPU30 EXYNOS_COMMON_PANEL EXYNOS_NOBLESSE_PANEL_REVIEW EXYNOS_NOBLESSE_DIMMING_REVIEW; do
    grep -Fx "CONFIG_${sym}=y" "$out/config.review-on"
done
targets=(exynos_panel_drv noblesse-panel-seq noblesse-panel-transport noblesse-dimming)
args=()
for name in "${targets[@]}"; do args+=("$panel/$name.o"); done
"${build[@]}" -j"${JOBS:-2}" "${strict[@]}" "${args[@]}" 2>&1 | tee "$out/compile-review-on.log"
"${build[@]}" -j"${JOBS:-2}" CFLAGS_helper.o=-Werror drivers/video/fbdev/exynos/dpu30/helper.o 2>&1 | tee "$out/compile-notifier-owner.log"
cp "$out/kbuild/drivers/video/fbdev/exynos/dpu30/helper.o" "$out/dpu30-helper.o"
"${cross}readelf" -h "$out/dpu30-helper.o" > "$out/dpu30-helper.elf.txt"
grep -Eq 'Machine:[[:space:]]+AArch64' "$out/dpu30-helper.elf.txt"
objects=("$out/dpu30-helper.o")
for name in "${targets[@]}"; do
    cp "$out/kbuild/$panel/$name.o" "$out/$name.o"
    "${cross}readelf" -h "$out/$name.o" > "$out/$name.elf.txt"
    grep -Eq 'Machine:[[:space:]]+AArch64' "$out/$name.elf.txt"
    objects+=("$out/$name.o")
done
"${cross}nm" --defined-only "$out/dpu30-helper.o" > "$out/notifier-owner-symbols.txt"
grep -Eq ' [db] lcd_status_notifier_list$' "$out/notifier-owner-symbols.txt"
for name in "${targets[@]}"; do
    ! "${cross}nm" --defined-only "$out/$name.o" | grep -Eq ' [db] lcd_status_notifier_list$'
done
"${cross}ld" -r -o "$out/noblesse-panel-review-linked.o" "${objects[@]}"
"${cross}nm" -u "$out/noblesse-panel-review-linked.o" > "$out/unresolved-kernel-symbols.txt"
"${cross}nm" --defined-only "$out/noblesse-panel-review-linked.o" > "$out/defined-symbols.txt"
for symbol in np_run noblesse_panel_sequence nd_create nd_prepare nd_send nd_destroy; do
    grep -Eq " [Tt] ${symbol}$" "$out/defined-symbols.txt"
    ! grep -Eq " U ${symbol}$" "$out/unresolved-kernel-symbols.txt"
done
git -C "$src" diff --stat > "$out/applied-diff-stat.txt"
if find "$out" -type f \( -name Image -o -name boot.img -o -name '*.ko' \) | grep -q .; then
    echo 'Unexpected image/module artifact' >&2; exit 1
fi
(cd "$out" && sha256sum *.o config.review-* source-commit.txt > SHA256SUMS)
printf '%s\n' 'PASS: real ARM64 Kbuild objects, review off/on, helper relocatable link.' > "$out/result.txt"
cat "$out/result.txt"
