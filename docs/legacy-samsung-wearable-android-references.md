# Legacy Samsung wearable Android references: SM-R840 applicability

Research-only note for branch `test/binder-android11-adaptation`. No watch writes, partition access, bootloader changes, or production SELinux policy changes are implied.

## Target hardware evidence

- SM-R840, board `NOBLESSE-LARGE-BT`, Exynos 9110, stock Tizen Linux 4.9.59, ARM64.
- Physical bezel input is `tizen_detent`, with EV_SYN, EV_KEY, EV_REL and REL_WHEEL advertised. The input event number is dynamic.
- Tizen E20 logs show clockwise compositor detent +1 and counterclockwise -1; **the raw evdev sign has not been measured**.
- Stock rootfs uses dm-verity, and `sdb root on` is denied. There is no demonstrated SM-R840 unsigned-image boot path.

## Examined upstream references

1. **Naver Labs AKI:** https://github.com/naverlabs/aki
   - README builds Android `7.0.0_r1` on Samsung Exynos 7270 using `jindory_defconfig` and U-Boot target `espresso7270_sip_aarch64`.
   - `source/` includes `aki-kernel.patch`, `aki-bootloader-u-boot.patch`, Samsung BSP archives and `aki-sensorhub-freertos.zip`.
   - Reuse: study boot handoff, initramfs layout, Android kernel integration, and sensor-hub interfaces. **Do not apply Exynos 7270 U-Boot patches to Exynos 9110.** Complete patch contents were not line-reviewed in this research pass.

2. **TO21 SGSWPlatform:** https://github.com/TO21Consortium/SGSWPlatform/tree/master/device/samsung/smdk7270
   - Contains `BoardConfig.mk`, `device.mk`, `conf/`, `sepolicy/`, `power/`, `bluetooth/`, and Samsung Android HAL wiring.
   - `device.mk` references `init.smdk7270.rc`, `ueventd.smdk7270.rc`, `fstab.smdk7270`, `sensors.exynos5`, `gralloc.exynos5`, `power.smdk7270`, and `lights.smdk7270`.
   - `BoardConfig.mk` declares kernel 3.18, defaults to a 32-bit Android userspace and uses an Exynos 7570 multimedia workaround. These are **not** Watch3 configuration values.
   - Reuse: configuration structure, hardware-service dependency inventory, and SELinux service-label concepts. Android 11 policy must be built from Android 11-compatible types and permissions; never copy old policy verbatim.

3. **Gear S3 kernel:** https://github.com/tids2k/gear_s3_7270_3.18_kernel
   - Tizen-derived Linux 3.18.14 source, with generic `drivers/input/misc/rotary_encoder.c`.
   - Reuse: input subsystem and Samsung wearable kernel comparison. The presence of `rotary_encoder.c` **does not establish** which driver the Gear S3 bezel uses, and cannot override Watch3 `tizen_detent` evidence.

4. **Gear 2 Android kernel:** https://github.com/Biktorgj/Android_b2_Kernel
   - Linux 3.4.39, including `android/configs/android-base.cfg` and `android-recommended.cfg`.
   - Reuse: historical Android kernel feature inventory only. Kernel and hardware differ too much for direct backport.

5. **Gear S3 XDA posts:** https://xdaforums.com/t/gear-s3-root-and-kernel-source-android-wear-port-thread.3584588/page-33#post-78281382 and https://xdaforums.com/t/gear-s3-root-and-kernel-source-android-wear-port-thread.3584588/page-39#post-79816730
   - Exact post bodies not verified; do not rely on specific alleged unlock, recovery, or flash instructions without inspecting primary text and matching SM-R840 hardware.

## Immediate Android 11 QEMU implications

The isolated `ci/binder-adaptation/servicemanager-test.conf` fixture already declares Binder and service_manager classes, labels for `watch3.test.echo` and `watch3.test.denied`, and a negative-control denial. The guest loader in `servicemanager-guest-init.c` already checks that a binary policy can be loaded and read back. Therefore **the older SMDK7270 sepolicy is not a missing drop-in fix**.

If real Android 11 service registration fails:
1. Inspect `samsung-virt-evidence/policy-build.log`, `serial.log`, `test.policy` and the guest `/sys/fs/selinux/load` write result before changing any allow rules.
2. Distinguish successful compilation from a **successful kernel policy load**; an enforcing flag alone is not sufficient.
3. Check the guest registrar SID, service label lookup, Binder transaction status, and SELinux denial logs.
4. Preserve the positive registration and negative denial controls. Never make the fixture permissive just to obtain a green result.
5. Run the existing Android 11 servicemanager QEMU workflow; record actual run/commit IDs and results. No claim of physical-watch Android boot follows from QEMU success.

## Safe next engineering tasks

- Compare AKI patch hunks against the **Samsung 4.9.59 source** in an offline scratch workspace; classify only relevant concepts.
- Inventory Watch3 DT nodes, kernel configs and Android 11 HAL requirements (input, graphics, audio, power, sensors, Bluetooth) without fabricating compatibility.
- Extend rotary host tests only with proven Watch3 `tizen_detent` capabilities; keep raw clockwise sign unverified.
- Continue all code work on `test/binder-android11-adaptation`, never `main`. Never flash or modify the physical watch without a separate explicit authorization.
