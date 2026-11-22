# Depth118 SM-R800 Wear OS reference vs SM-R840 test branch

Status: **source comparison only — NO-GO for hardware flashing**.

Reference: https://github.com/Depth118/galaxy-watch-wearos (SM-R800 only).
Target: https://github.com/tomw55/watch3-android11-rotary-test/tree/test/binder-android11-adaptation (SM-R840).

## Confirmed source facts

| Topic | Depth118 SM-R800 | Our SM-R840 test branch | Implication |
| --- | --- | --- | --- |
| Kernel | AOSP Exynos 9110 Linux 4.19, `src/kernel/r800.config`, `src/kernel/r800-wearos.patch` | Samsung/Tizen Linux 4.9 baseline; see `docs/kernel-build-audit.md` | Kernel patch and config cannot be applied directly across versions |
| Binder | `CONFIG_ANDROID_BINDER_IPC=y`; `CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"`; binderfs disabled | Android 11 Binder compatibility and QEMU testing in progress | Use 4.19 config as requirements reference, not proof of 4.9 compatibility |
| Android facilities | `CONFIG_ASHMEM=y`, `CONFIG_MEMFD_CREATE=y`, `CONFIG_SECURITY_SELINUX=y`, `CONFIG_SECCOMP_FILTER=y`, `CONFIG_NAMESPACES=y` | Must independently check target config and actual runtime | Check individual kernel options and ABI semantics |
| Boot | `payload/start.sh` mounts system/vendor images and executes `switch_root /newroot /init` | Targeted Android 11 ARM64 servicemanager acquisition and guest packaging | Full Android boot and isolated servicemanager execution are distinct milestones |
| Rotary | `CONFIG_INPUT_TIZEN_DETENT=y`; patch emits `REL_WHEEL` from Hall-sensor transitions | Rotary input parser tests | Add direction/step fixtures; do not assume GPIO wiring matches |
| Hardware | SM-R800-specific device tree `src/dt/r800.dts`, HALs and partition layout | SM-R840-specific device tree and validation required | Never reuse R800 boot images, partition numbers or flashing tools on R840 |

## CI gates and evidence

1. **Source/config gate:** verify expected Binder, SELinux, ashmem, memfd, seccomp and rotary definitions in the Depth118 reference. This is a source-level check, **not** a boot or hardware validation.
2. **Android 11 acquisition gate:** extract a genuine Android 11 ARM64 `servicemanager` ELF plus recursive dynamic dependencies and save hashes/manifest. Extraction alone does not establish execution.
3. **QEMU execution gate:** require logs proving the real Android `servicemanager` process starts and a test service registers and is looked up through Binder. Kernel/Binder selftests alone **do not** satisfy this gate.
4. **SM-R840 kernel gate:** verify target-specific compile, ABI and hardware differences before even considering a device boot plan. Existing audit is NO-GO.
5. **Hardware gate:** blocked; no flashing, bootloader changes, partition writes or `main` changes authorized.

## Implementation priorities

- Keep existing Binder acquisition and QEMU workflow independent of the new reference-source gate.
- Inventory SM-R840 device-tree nodes, bezel event interface, display/touch/power dependencies, and partition map against SM-R800.
- Investigate feasibility of 4.19 adaptation separately from incremental Linux 4.9 Binder compatibility.
- Use Depth118's boot sequence as architectural documentation only; its release payload is assembled partly from an already-working SM-R800 watch tree.
