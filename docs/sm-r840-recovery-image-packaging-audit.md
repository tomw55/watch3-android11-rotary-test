# SM-R840 recovery image packaging audit (offline)

Source inspected: user-provided `kernel_samsung_galileo-master(1).zip`, `release.sh` and `arch/arm64/boot/dts/exynos/exynos9110-tizen_noblesse_large_bt-r08.dts`. This is a source-level packaging audit, **not** a successful recovery boot or proof of permissive secure boot.

## Confirmed release.sh pipeline

For the **noblesse large, non-LTE** target, `release.sh` builds an ARM64 kernel `Image`, runs `dtbtool -o arch/arm64/boot/merged-dtb -p scripts/dtc/ -v arch/arm64/boot/dts/exynos/`, then runs `mkdzimage -o arch/arm64/boot/dzImage -k arch/arm64/boot/Image -d arch/arm64/boot/merged-dtb`.

It sets `LOCAL_BUILD_SECURE_BOOT=1` and `SECURITY_KEY=SM-R840_NA_USA_USA0` for the non-LTE large noblesse variant. It renames `dzImage` to `dzImage.u`, appends **272 zero bytes**, then calls `java -jar ./scripts/signclient.jar -runtype ss_exynos40_all -model SM-R840_NA_USA_USA0 -input .../dzImage.u -output .../dzImage`. Finally it wraps `dzImage` in `System_noblesse_large_*.tar`.

**Crucial:** A model key string in a public build script does **not** grant access to Samsung signing keys, and `signclient.jar` does not prove a developer can produce a retail-accepted signed image. The `mkdzimage` and `dtbtool` executable implementations were **not found in this uploaded source archive**; their output format cannot be fully verified from `release.sh` alone. The script packages a kernel `dzImage`, **not** a verified recovery-partition kernel+ramdisk image. No inference should be made that the R800 recovery procedure works on R840.

## Device-tree target

`arch/arm64/boot/dts/exynos/exynos9110-tizen_noblesse_large_bt-r08.dts` is the board-revision-08 Bluetooth large model target. This matches the project's existing SM-R840 rev08 kernel audit, but the physical watch's board revision has **not** been independently read.

## Next evidence required

1. Acquire a trustworthy SM-R840 **stock** and candidate **combination** firmware archive, without flashing either. Capture SHA-256, archive contents, provenance and any available signatures.
2. Compare the candidate engineering S-Boot and recovery image packaging to **actual R840** stock firmware; check whether the recovery partition contains `dzImage`, separate ramdisk, or another format.
3. Obtain `mkdzimage`/`dtbtool` source or reproducible binaries and inspect their exact headers and layout offline. Do not assume `dzImage` is a generic Android boot image.
4. Confirm the current watch's firmware/bootloader revision and hardware revision read-only before evaluating anti-rollback or compatibility.
5. Do not flash, write partitions, invoke `dd` or treat a normal Tizen reboot as guaranteed fallback.

**Status: NO-GO for flashing.** All findings above are offline-only. Keep `main` untouched.
