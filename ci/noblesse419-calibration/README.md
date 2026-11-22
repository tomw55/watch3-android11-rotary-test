# Noblesse calibration reader — offline-only gate

This adds an isolated default-off reader to the previously passing Linux 4.19
panel proposal. **It supplies no DSIM backend and must not be connected to the
legacy DSIM read function.** Physical SM-R840 remains NO-GO.

The component is production C compiled against actual ARM64 kernel headers, with
synthetic callbacks for host tests. It is not a full panel driver or runtime test.
There is no panel/backlight registration, probe caller, reset, brightness command,
firmware upload, factory-MTP sysfs path or physical-device communication.

## Implemented logic

`nc_read_create()` calls `nc_read_snapshot()`, then the real existing `nd_create()`
only after successful reads **and key-off cleanup**. No fallback MTP is supplied.

1. Validate SDC variant, externally verified large-panel identity, transport-ready
   assertion and an independently justified exact expected three-byte panel ID.
2. `begin()` acquires whole-transaction serialization and rechecks readiness.
   This callback is a caller contract, not a mutex implementation supplied here.
3. Send exact `F0 5A 5A` key-on. A failed attempt still triggers key-off cleanup.
4. DCS-read `04`, exactly 3 bytes. Compare every byte with the expected ID.
5. DCS-read `BA`, exactly 8 bytes. Use byte 7 as the VBIAS base.
6. DCS-read `C8`, exactly 46 bytes. Retain the first 34 for dimming; ignore date
   bytes. No unique data is logged by the adapter.
7. Attempt exact `F0 A5 A5` key-off, then release serialization with `end()`.
8. Publish a complete snapshot / construct a dimming context only after cleanup
   succeeds. A failed call clears caller-visible output. Preserve the primary
   error and separately record cleanup error; a lone cleanup error is fatal.

Any short, zero or oversized returned byte count is `-EMSGSIZE`; negative errors
are preserved. Wrong identity is `-ENODEV`; incomplete readiness is `-EAGAIN`.
No subsequent normal reads occur after the first failure. Snapshot `complete`
means exact reads completed, not that calibration is electrically valid. Real
`nd_create()` still rejects all-zero/all-FF calibration and arithmetic failures.

The operation is **not write-free**: F0 key commands change panel control state.
The read request itself also requires DSI control traffic in a future transport.
No assertion of volatile or persistent panel semantics is inferred from names.
Key-off is best-effort cleanup, not proof of panel rollback.

## Verified source mapping

Samsung archive SHA-256:
`1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f`.
Source directory: `drivers/video/fbdev/exynos/dpu_9110/panels/`.

- `s6e36w4x01_param.h:75–91`: BA/8, C8/34+12, ID 04/3.
- Same header `:206–214`: exact key-on/off commands.
- `s6e36w4x01_lcd_ctrl_noblesse.c:1315–1428`, `read_init_info()`:
  key scope, ID, VBIAS last byte and first 34 MTP bytes. Stock rejects only
  negative returns; the new reader deliberately requires exact lengths.
- Earlier dimming helper: ID `40 64 83` selects low-nibble revision 3.
  That ID is a historical boot-argument fixture here, not a new hardware read.

## Critical transport block found in the exact 4.19 source

Source pin `1c06f4ebe0a9788b9d5f0f4ecb43209dee28950b`,
`drivers/video/fbdev/exynos/dpu30/dsim_drv.c`, `dsim_read_data()`:

- **Lines 658–678:** the response's 16-bit `rx_size` controls writes into `buf`
  without a `rx_size <= cnt` destination-capacity check. The outer FIFO-loop
  limit does not bound that inner payload copy. Checking the returned size after
  the function returns cannot prevent a pre-return buffer overrun.
- **Lines 595–605:** write errors are logged but processing continues, and the
  command-wait result is ignored. A callback cannot assume a successful setup
  merely because a later read returns a byte count.
- **Lines 607–620:** timeout can call `dsim_reset_panel()` and hardware recovery,
  depending on link/controller state. It returns before the common hibernation
  unblock at the end of the function; cleanup needs separate review.

`dsim.h:272` declares the byte-count-returning read signature. The new
`noblesse-calibration-api-check.c` uses compile-time type checks for read/write
signatures and DCS_READ=0x06. This verifies API shape only. It does not dispatch
to those functions, produce a live backend or prove their implementation safe.

`nc_io.read` explicitly requires a bounded destination write before returning.
A malicious or broken callback can violate that contract; no generic wrapper can
retroactively make such an overflow safe. The mock never overwrites its buffer,
even when reporting an oversized return. The kernel reader object must contain
no direct undefined reference to `dsim_read_data`/`dsim_write_data`.

## Actual-source tests

`tests/run-tests.py` compiles the actual reader and the actual dimming helper from
the patched kernel directory. Only transport callbacks are mocked. A linker
wrapper counts calls to `nd_create()` and delegates to the real implementation;
it asserts construction happens outside the lock, after cleanup. It does not
replace gamma computation with a model.

- Three revision branches × 101 brightness values × two hop flags: **606**
  end-to-end frame comparisons with direct real `nd_create()` input.
- All 57 short lengths across ID/BA/C8, plus six oversized counts and six
  distinct negative-error cases: **69** length/error cases. Each is also checked
  through `nc_read_create()` to prove no false-ready construction.
- Additional assertions: every ID byte, begin/key-on/key-off failures, primary
  and cleanup error precedence, missing callbacks, NULL arguments, gate failures,
  output clearing, all-zero/all-FF calibration and failed/successful retries.
- Strict C11 and ASan/UBSan. LeakSanitizer is disabled in this fixture; no leak
  detection PASS is claimed.
- Four actual-source mutation tests must fail: accept short reads, skip identity,
  ignore failed key-off, and use the wrong VBIAS byte.

Host results do not test real serialization, panel state, DSIM FIFO behavior,
calibration validity or runtime timing.

## Build / reproduce

Use a fresh disposable checkout of the pinned kernel and fresh output directory:

```sh
cross=$(bash scripts/install-kernel-toolchain.sh /path/to/toolchain)
bash ci/noblesse419-calibration/build-objects.sh /path/to/fresh/kernel "$cross" /path/to/fresh/evidence
```

The recipe applies the same four earlier panel patches, then the calibration
patch. Calibration patch number **0005 in this directory is unrelated to the
held fuel-gauge safety patch 0005**; that workstream is not modified or included.

Real Kconfig must resolve the three review options to y for compilation, with all
defaulting disabled before explicit configuration. Selected objects compile with
per-object `-Werror` and undergo ELF/symbol/relocatable-link checks. Host tests run
from those exact applied sources. No Image, boot.img, module or flashable artifact
is requested. Existing baseline/workflow files remain unchanged.

The new GitHub workflow is `.github/workflows/noblesse419-calibration.yml`,
restricted to `test/binder-android11-adaptation` and its own file paths. Logs,
resolved configurations, ELF objects, checksums and host results are uploaded.

**Next blocking task:** review a bounded DSIM receive path, setup-error handling
and timeout/recovery cleanup before supplying any real transport backend. Do not
enable this reader on hardware simply because its compile/tests pass.
