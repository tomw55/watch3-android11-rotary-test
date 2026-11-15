# SM-R840 rev08 kernel build audit

## Reproduce the compile

This branch targets the Samsung/Tizen Linux 4.9.59 source archive pinned to
`1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f`.
Use a new work and output directory. Host prerequisites are GNU Make, host
GCC, binutils, libc development headers, curl, unzip, xz, bc, OpenSSL
development headers, and standard Linux file utilities.

```sh
prefix=$(scripts/install-kernel-toolchain.sh "$PWD/toolchain")
KERNEL_SRC_LOCAL=/absolute/path/to/kernel_samsung_galileo-master.zip \
  CROSS_COMPILE="$prefix" WORK="$PWD/build-work" OUT="$PWD/build-out" \
  JOBS=8 bash scripts/build-kernel.sh
(cd build-out/artifacts && sha256sum -c ../ARTIFACT_SHA256SUMS)
```

For CI, push a review branch and manually dispatch **Watch3 SM-R840 kernel
build** on that branch with the existing hash-gated source URL. Inspect the
exit codes, source/compiler log, configuration, artifact headers and
manifest before considering a merge. No boot or watch interaction is part of
the build.

## Toolchain decision

Samsung's `release.sh:17–21` points at
`/opt/toolchain-aarch64/bin/aarch64-tizen-linux-gnu-`.
`packaging/linux-4.9-exynos9110.spec:32–34,145–150` requires Tizen's
AArch64 GCC/binutils packages and uses the same prefix. Neither pins the
version shipped for retail DWK2. The Android Goldfish GCC 4.9 settings in
this archive are emulator settings. They do not identify the Noblesse
release compiler.

The prior GitHub workflow mentioned GCC 8 but installed the same unversioned
meta-package in both branches. The [actual build artifact](https://github.com/tomw55/watch3-android11-rotary-test/actions/runs/43769512974)
records Ubuntu GCC 11.4.0. For the compile baseline choose kernel.org
GCC 7.5.0 and binutils 2.32, with archive SHA-256
`2399ecb4d622810e47096e931a7f21b6edb136844a4064f5c0983b5879b1bdf9`,
matching the [publisher manifest](https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/x86_64/7.5.0/sha256sums.asc).
The installer fails on mismatch and has no compiler fallback. It is a
public replacement toolchain, with no claim that it matches Samsung's.
The default build uses empty KCFLAGS and keeps Samsung's -Werror.
The compiler is pinned, while host dependencies are logged and build
timestamps/metadata can still differ.

## Run 43769512974 and keep-going diagnosis

The original artifact includes 12 compiler-error lines and the rev08 DTB
of 141,766 bytes. Its Image make exited 2, DTB make exited 0, and modules
were skipped. All four observed error groups are covered below.

| Original diagnostic | Disposition |
| --- | --- |
| Nine SCTP packed-alignment diagnostics in `include/uapi/linux/sctp.h:331,604–605,617–618,659–665,766–772`, included from `security/lsm_audit.c:31` | These exported structs specify packed layout and 4-byte alignment, with some address members at offset four. Increasing alignment or dropping packing can change UAPI. Preserve it and build with pinned GCC 7.5. The enabled netfilter SCTP consumers can also see these headers even with IP SCTP disabled. |
| Conflicting `jiffies_64` sections in `kernel/time/timer.c:58` versus `include/linux/jiffies.h:70,77` | Put the definition in the declared .data section and retain the SMP alignment-only attribute. Verify arm64's `jiffies = jiffies_64` linker alias. |
| Overlapping source and destination in `fs/ext4/mballoc.c:2401` | Append bounded text with scnprintf to an advancing offset. Keep the 14 labels, comma delimiters and final newline without reading from the output being written. |
| Packed `fbi_step.data_offset` address in `kernel/swap/modules/parser/msg_parser.c:521` | Read into an aligned local, then assign the packed field. `msg_buf.c:get_u64` also uses an unaligned-safe native-endian load at the existing checked input boundary. No wire layout changes. |

A local Arm GCC 11.2.1 keep-going build from the same source and original
profile reproduced all four groups. It also reported packed ALSA compat,
Bluetooth, network and regmap cases, a codec copy-size diagnostic, four
interior zero-length bounds sites, string truncation/overflow and overlap
sites, five touchscreen array-clear size errors, Broadcom
maybe-uninitialized paths, power/ACPM indentation, CAL clock
sizeof-pointer division and a DPP array-parameter mismatch. The full log is
in the handoff. These findings are not all fixed by this branch.
Packed Bluetooth command output already emits values via
`put_unaligned_le16`. ALSA compat and SCTP layouts need ABI review before
modernizing their alignment. Do not disable packed diagnostics globally.

This series also fixes the naturally alignable private regcache rbtree
structure, uses a checked-size literal copy for the Speedy codec, clears
the full touchscreen gap arrays rather than the first half of their
16-bit elements, initializes the DHD RTT response descriptor, and removes
one unreachable SSP motor-notifier log. The accepted audit patches and
held 0005 remain byte-for-byte identical. The touchscreen changes are in
the CI compatibility directory and leave its audit exclusion intact.

## Configuration blocker and release profile

After compilation, the previous size-only configuration fails to link four
`sensors_*` symbols referenced by `lps22hb_core.c` at
2329, 2337, 2380, 2414 and 2418. Samsung's `release.sh:74–100` adds its
Broadcom fragment by default for Noblesse. In that profile
`SENSORS_SSP_BBD=y` brings in the Noblesse sensorhub directory and
`SENSORS_SYSFS=y` links its `sensors_core.o`. CI now combines the
base defconfig, the large fragment and that vendor fragment, and checks
the resulting board and sensor symbols before building. This intentionally
adds the vendor Broadcom sensor configuration that was missing from CI.
Modules stay disabled.

The build installs the accepted offline audit switches into the source
but leaves them at their default-off values in this release-derived
configuration. It does not certify any driver as hardware-safe. A raw
compiled Image and DTB do not establish boot authorization or stock
recovery. **SM-R840 remains NO-GO.**

## Validation on this branch

| Status | Evidence |
| --- | --- |
| PASS | Fresh extraction, accepted and CI patch application with zero fuzz, pinned GCC 7.5.0/binutils 2.32 and host GCC 14.2; Image and exact BT r08 DTB both exited 0 with empty KCFLAGS. |
| PASS | ARM64 Image header, size 16,334,856 bytes, SHA-256 `e15c5ee1eee56a2c86e0b2aa29f753d89a9ce6d5e7fcc38619725383414f716c`. DTB size 141,766 bytes, byte-identical to the failed GitHub run's successful DTB. |
| PASS | Linked ELF resolves the four sensor-core symbols and aliases cache-line-aligned jiffies and jiffies_64 at the same address. |
| PASS | Targeted GCC 11.2.1 compilation of timer, ext4, regcache, Speedy and both SWAP parser objects with only the two original diagnostic demotions. |
| PASS | Android rotary host parser regressions. Accepted/held patch directories and Android workflow and source files have no changes. |
| FAIL | Original GCC 11.4 GitHub Image build, reproduced locally with GCC 11.2.1. Pre-fix GCC 7.5 trials separately exposed compile and missing sensor-core link errors. |
| NOT RUN | CI on the proposed branch (no authenticated write/dispatch access), full modern-compiler build after fixes, module builds (disabled), and all boot and hardware tests. |
