# Android 11 focused rotary delivery

Apply the proposal to the root of the public repository. The separate,
proven boot/input feasibility workflow remains available. On GitHub choose
**Actions → Android 11 rotary delivery → Run workflow**. No credentials or
custom secrets are required. The runner uses the existing API 30 x86_64 AOSP
guest and its root, enforcing SELinux, data-directory IDC, and event-free
InputReader preflight.

The job then compiles Claude's revised receiver from source using the API 30
platform JAR, aligns it and verifies its signature using Build Tools 33.0.2.
The test-only key is generated inside each job and stays outside the artifacts.
The parity generator is compiled for guest x86_64 using NDK r25c. The job
installs the fresh APK on the disposable guest. It never uses the stale
APK included in the revision archive.

## Required guest evidence

In the **android11-rotary-delivery** artifact, verify:

- `boot-result.txt` and `input-feasibility.txt`, followed by `rotary-result.txt`.
- `RotaryGuestView.apk`, its SHA-256 and `rotary-apk-build.log`, which includes
  alignment, signature and Android SDK metadata checks.
- `input-classification.txt` and `getevent-capabilities.txt` tie the exact IDC
  and both mappers to the new generator node and InputReader device ID.
- `cw-getevent.txt`, `ccw-getevent.txt`, and `x-getevent.txt` record the real
  `REL_WHEEL=+1`, `REL_WHEEL=-1` and `REL_X`-only frames respectively.
- `cw-app.txt` and `ccw-app.txt` must each contain exactly one correlated
  `SOURCE_ROTARY_ENCODER` (`0x400000`) `ACTION_SCROLL`, with `AXIS_SCROLL`
  `+1` and `-1` respectively, delivered to the focused fixture at rotation 0.
  The `REL_X`-only frame must generate no rotary scroll. Cursor motion can
  still occur.
- `*-cursor.txt` and `cases.txt` report app-observed cursor events
  separately. A mouse wheel uses `AXIS_VSCROLL` and cannot satisfy the
  rotary assertions. The cursor can hit-test outside the receiver. App
  silence about cursor events cannot overturn a mapper seen in dumpsys.
  The automated run does not require a decoy hit or certify hover routing.

The job fails on missing or mismatched raw frames or required rotary events.
Read `job-result.txt` for the failed stage and `logcat-final.txt` for
guest diagnostics. Per-frame capture is scoped to the synthetic node and
the app tests filter on device name and InputReader ID. This run tests
Android guest delivery only. Physical Watch3 remains NO-GO.

For local parser checks, run `cd ci/android11 && python3 test-delivery-host.py`.

Stock R840 identity, source-verified Hall framing, updated host-only tests and
remaining cursor/wake issues are documented in [physical/README.md](physical/README.md).
The current guest generator uses bus/vendor/product/version 0006/0001/0001/0100;
previous guest passes do not revalidate this updated identity automatically.
