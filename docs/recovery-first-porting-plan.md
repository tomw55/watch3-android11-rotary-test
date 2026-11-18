# Galaxy Watch3 SM-R840 recovery-first Wear OS port: research plan

**Status: RESEARCH / NO FLASH / NO HARDWARE WRITES.** Target is the existing SM-R840 rev08 Watch3 kernel audit. This document changes the priority of the porting investigation; it does not establish a working port or safe installation.

## Why change the approach

A publicly described Wear OS 3 / Android 11 port to the first-generation Galaxy Watch SM-R800 reportedly uses Samsung's device-specific **combination firmware** to obtain a development S-Boot and rooted factory Tizen shell, then places a custom kernel+ramdisk in its recovery partition. Recovery boot launches the experimental system; normal boot returns to the firmware's Tizen path. This is an **account from the porter**, not an independently reproduced Watch3 procedure.

The Galaxy Watch SM-R800 and Watch3 SM-R840 share the Exynos 9110 SoC. Shared CPU architecture does **not** imply interchangeable S-Boot, combination packages, PIT layouts, ramdisks, device trees or peripherals.

Original discussion:
- https://www.reddit.com/r/GalaxyWatch/comments/1xw283p/update_galaxy_watch_now_runs_pixel_watch_wearos/
- https://github.com/prakashdivyy/py-netodin

## SM-R840-specific evidence

- This project's kernel audit targets **SM-R840 rev08**, not SM-R800.
- Third-party firmware listings and historical forum posts mention **COMBINATION-FT55_R840XXU1ATG1** (spelling/punctuation vary). That is **only a candidate for offline research**: no image provenance, exact integrity hash, hardware revision match, firmware anti-rollback compatibility, bootloader behavior or safe restoration has been verified.
- The R800 porter cited **COMBINATION-FT40_R800XXU1ARI2**. **NEVER use the R800 package on an R840.**
- Py-NetOdin's own README lists R800/R810 and several other Tizen watches, but does **not explicitly list R840**. Protocol/PIT compatibility with R840 must be established independently before relying on it.
- An R840 firmware listing or a successful network handshake cannot establish that engineering S-Boot is permissive, that recovery boots arbitrary images, or that normal Tizen will remain usable.

## Prioritized, non-destructive gates

1. **Identify exact unit**: collect the SM-R840 model identifier, hardware revision, current AP/CP/CSC and bootloader/software version, existing recovery mode behavior, and battery/charging state without unlocking or writing.
2. **Image provenance and offline inspection**: locate a trustworthy matching stock firmware and a candidate R840 combination image; record source, size, SHA-256 and signatures; list archive members and inspect S-Boot/kernel/ramdisk metadata. Do not distribute firmware through this repo.
3. **Partition map safety**: compare PIT/partition names and sizes from firmware artifacts with read-only device metadata, if available. Do not assume recovery is mmcblk0pN by looking at R800 instructions; do not copy any published partition number blindly.
4. **Recovery pathway audit**: check whether the candidate R840 combination firmware really allows an engineering shell and whether **a verified restore method** exists for bootloader, stock boot/recovery and calibration/device-identity data. A factory combination boot is not the same as a saved stock Tizen fallback.
5. **Hardware-target kernel packaging**: use the audited Exynos 9110/SM-R840 kernel/DTB as a starting point; compare the porter's kernel config, initramfs device setup, SELinux and input/display modules. Build a minimal diagnostic initramfs artifact and validate image format **offline** before any target test.
6. **Only after a separate explicit go/no-go review**: consider an experiment with a known-good physical recovery path, full backups and agreed device-specific rollback instructions. Never touch retail partitions as a side effect of CI or documentation.

## Reposition existing CI

Keep Android 11 QEMU Binder / `servicemanager` experiments as **secondary userspace compatibility checks**. They cannot answer whether SM-R840 engineering S-Boot accepts a recovery boot image or whether its kernel initializes display, touch, Bluetooth, storage and power management. New primary work is model-specific firmware provenance, kernel/recovery image inspection and safe rollback planning.

## Outstanding questions for the R800 porter

- Can they share boot image unpacking/packing parameters, kernel config and device tree assumptions, recovery partition naming and a sanitized boot log?
- What exact bootloader/combination firmware properties allow unsigned recovery boot? Are checks disabled for recovery only or for additional partitions?
- Which Pixel Watch image components are reused, and which Samsung drivers, device nodes, init rc files and SELinux policies were adapted?
- How is normal boot restored to stock rather than simply to factory combination Tizen? Was rollback tested?
- Can they share source/patches with explicit redistribution permissions?

**Hard stops:** no device flashing, no `dd` to block devices, no flash/recovery command examples presented as safe, no use of R800 firmware on Watch3, and no changes to `main`.
