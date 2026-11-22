# Noblesse Linux 4.19 compile-only gate

Separate from Samsung Linux 4.9, the Watch3 production baseline, Android rotary
runtime and all accepted/held driver-safety patches. Physical SM-R840: **NO-GO**.
No Image, boot.img, recovery image, module, panel registration or DT enablement.

The pinned Google Exynos source commit is
`1c06f4ebe0a9788b9d5f0f4ecb43209dee28950b` (Linux 4.19.269). The exact Git object
is fetched from the public `xanderlent/COMBINED_android-kernel-exynos` mirror.
This is not Samsung's Linux 4.9.59 source or a claim of firmware authentication.

Use GCC 7.5.0 and binutils 2.32 from the existing SHA-256-verified installer.
The previous full 4.19 Image used Clang 16; this gate independently verifies
GCC-based ARM64 objects, and does not reproduce that Image.

```sh
# x86_64 Linux prerequisites: git, make, a host C compiler, flex, bison, m4,
# bc, libssl development headers, curl, xz, patch, Python3/core utilities.
git init /path/to/empty/exynos419
git -C /path/to/empty/exynos419 remote add origin https://github.com/xanderlent/COMBINED_android-kernel-exynos.git
git -C /path/to/empty/exynos419 fetch --depth=1 origin 1c06f4ebe0a9788b9d5f0f4ecb43209dee28950b
git -C /path/to/empty/exynos419 checkout --detach FETCH_HEAD
cross=$(bash scripts/install-kernel-toolchain.sh /path/to/toolchain)
bash ci/noblesse419-panel/build-objects.sh /path/to/empty/exynos419 "$cross" /path/to/empty/evidence
```

Requires a clean disposable checkout and fresh output directory. All source
patches apply only there. No root is needed after installing host dependencies.

## Patches

1. `0001`: existing, unchanged default-off panel command/transport/GPIO proposal.
2. `0002`: existing, unchanged default-off per-instance dimming/brightness proposal.
3. `0003`: move `lcd_status_notifier_list` from `decon.h` to `helper.c`, its only
   consumer. Same static object type, initializer, consumers and synchronization;
   avoids unused private copies in every header consumer. The owner also compiles
   with `-Werror`, and nm verifies its storage exists only in that owner.
4. `0004`: real-kernel header fixes discovered by this gate: keep host logging
   stubs out of `__KERNEL__`, and namespace packet macros `ND_TX_WRITE/ND_TX_LONG`.
   No gamma formulas, tables, voltage values or packet bytes change.

Hashes are checked before patching. This directory does not alter the earlier
downloaded panel/dimming review bundles.

## Checks and limits

- Real `erd9110_defconfig`, baseline fragment merge, `olddefconfig` and generated
  kernel headers; actual resolved configurations saved for review-off/on.
- Both review booleans default disabled. Kconfig may omit the dependent dimming
  symbol entirely while its parent is disabled. After enabling both, all parent
  and review symbols must resolve to y, or the gate fails.
- Common panel driver compiled with review off and on. New sequence, transport
  and dimming objects plus the notifier owner compiled for AArch64 with
  per-object `-Werror`. This does not activate hardware or register a new panel.
- ELF architecture and helper symbol checks, relocatable `ld -r` link and hashes.
  Undefined symbols from the rest of the kernel remain listed explicitly. This
  is not a final vmlinux link, modpost or a runtime test.
- Existing upstream VDSO `BIT` redefinition and duplicate thermal defconfig
  assignments remain visible. Global `KCFLAGS=-Werror` would reject that
  unrelated preparation warning; no blanket `-Wno-*` suppression is used.

Artifacts include final configurations, verbose compiler commands, logs, object
files and SHA256SUMS. Failed stages stay failed; artifact upload runs regardless.
The workflow runs only on `test/binder-android11-adaptation` when these files
change. No main registration or main modification is needed for the push trigger.

Next work after this gate: a separately reviewed calibration-read adapter with
explicit ID/length/error contracts and mocked short-read tests. Real panel power,
DSIM/DECON operation, calibration validity, thermal policy, image authorization
and independent recovery remain outside this gate.
