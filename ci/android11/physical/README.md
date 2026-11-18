# SM-R840 rev08 bezel: physical evidence and offline integration

Scope: `test/binder-android11-adaptation` only. No watch contact, root,
driver enablement, policy relaxation, flashing or changes to the accepted/held
kernel patches. Physical Android bring-up remains **NO-GO**.

## Evidence boundaries

`watch3-r08-observation.json` records the user's stock DWK2 SDB/sysfs and dlog
observations. They were not independently recaptured in this session. The
reported input18/event18 paths identify one boot only; no consumer selects them.
The key-bitmap text is retained verbatim, without guessing its word grouping or
inferring the stock kernel's bitness. The modalias independently identifies
`BTN_LEFT` (0x110).

| Finding | Evidence and status |
|---|---|
| Name `tizen_detent`, bus 0006, vendor/product 0001, version 0100 | User stock observation; independently matches Samsung source |
| EV_SYN, EV_KEY/BTN_LEFT, EV_REL/X/Y/WHEEL | User masks/modalias; source registration matches. Linux input core adds EV_SYN |
| Tizen CW +1, CCW -1; dashboard enum 1/0 | User's compositor/application logs; dashboard 0 is **not** Linux neutral direction |
| Raw WHEEL +1/-1 and accompanying REL_X | Independently established for the pinned Samsung source, not captured from running DWK2 |
| Stock `LCDOn:bezel` | User-observed Tizen wake request; Android wake not tested |
| Raw device reading | NOT RUN: user's owner account cannot read the root:input 0660 node; no escalation proposed |
| Actual Android/Wear OS on Watch3 | NOT RUN; no such claim |

## Samsung source trace

Authoritative inspected archive SHA-256:
`1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f`.
This identifies the supplied source, not a proven DWK2 binary/source match.

`drivers/input/misc/tizen_bezel.c`, SHA-256
`1d328f906788b0e30567d1f136ec42838ef00fe0440f335503e0611f8337fe90`:

| Function / lines | Verified behaviour |
|---|---|
| enum and `bezel_get_direction`, 42–80 | CC=-1, NA=0, CW=+1; table indexed **[current][previous]** |
| `bezel_get_status`, 83–97 | Active-low Hall inputs; A/B/C form bits 0/1/2 |
| `bezel_check_validation`, 100–129 | Normal valid states 0/1/2/4; factory mode has different acceptance |
| `bezel_work_func`, 131–164 | Validation then direction; NA updates baseline without reporting; otherwise WHEEL direction, X=`(~state)&7`, then sync |
| `bezel_detect_handler`, 209–224 | Requires probe_done/open_state, schedules work; IRQs can coalesce |
| `bezel_setup_input_dev`, 571–610 | Exact name/phys, capability bits and all four identity fields |
| `bezel_regulator_init`/power methods, 613–677 | Configured rail set to 1.8 V and enabled/disabled: this is not a GPIO-only driver |
| IRQ wake, 511–525; probe, 835 | Enables IRQ wake and device wake capability; not proof of Android display wake |
| DT parsing, 761–785 | Three `hall_sensor,gpio_*` properties and `regulator_name` |

`include/linux/input/tizen_bezel.h:20` defines `BEZEL_NAME`.
`drivers/input/input.c:2191` adds EV_SYN during input registration.

Source CW active-state cycle is **1 → 2 → 4 → 1**, reporting X=5,3,6.
CCW is **1 → 4 → 2 → 1**, reporting X=3,5,6. Every valid reported movement
has a wheel delta of one; this does not establish mechanical notches per
revolution, interrupt timing or loss under load. Repeats, invalid states and
state 0/reset can produce no frame. The first sample can establish a baseline.

The synthetic generator now follows those cycles from an explicitly synthetic
initial A state. Its first CW/CCW pair remains WHEEL +1/X5, WHEEL -1/X6,
preserving the existing guest assertion. `x` remains an artificial REL_X-only
negative control, not a claimed stock rotation frame. `--reverse` deliberately
reverses the synthetic event direction and corresponding Hall sequence.

## Android 11 r48 integration

Primary sources, all under `android-11.0.0_r48` in
[frameworks/native/services/inputflinger](https://android.googlesource.com/platform/frameworks/native/+/refs/tags/android-11.0.0_r48/services/inputflinger/):

| File and lines | Consequence |
|---|---|
| [reader/EventHub.cpp:1331–1343](https://android.googlesource.com/platform/frameworks/native/+/refs/tags/android-11.0.0_r48/services/inputflinger/reader/EventHub.cpp#1331) | BTN_MOUSE (=BTN_LEFT) plus REL_X/Y adds cursor class. IDC rotaryEncoder **adds** rotary class; it does not remove cursor |
| [reader/InputDevice.cpp:150–152,181–183](https://android.googlesource.com/platform/frameworks/native/+/refs/tags/android-11.0.0_r48/services/inputflinger/reader/InputDevice.cpp#150) | Both rotary and cursor mappers can be created |
| [reader/mapper/RotaryEncoderInputMapper.cpp:36–51,84–131](https://android.googlesource.com/platform/frameworks/native/+/refs/tags/android-11.0.0_r48/services/inputflinger/reader/mapper/RotaryEncoderInputMapper.cpp#36) | Existing `device.scalingFactor=1.0` is supported; wheel sync produces SOURCE_ROTARY_ENCODER ACTION_SCROLL/AXIS_SCROLL. At orientation 180 the sign reverses |
| [reader/EventHub.cpp:1615–1628](https://android.googlesource.com/platform/frameworks/native/+/refs/tags/android-11.0.0_r48/services/inputflinger/reader/EventHub.cpp#1615) | IDC selected through the device identifier, not event number. Updated IDs may change which ID-specific file takes precedence; guest tests require the exact staged IDC |
| [reader/EventHub.cpp:1648–1655](https://android.googlesource.com/platform/frameworks/native/+/refs/tags/android-11.0.0_r48/services/inputflinger/reader/EventHub.cpp#1648) and mapper:107–110 | BUS_VIRTUAL is not external by default; rotary mapper adds POLICY_FLAG_WAKE only for external devices that scroll. Current IDC has no external override |

Reviewed file SHA-256s: EventHub
`722bd47874e3e2475145498bcbb3725a0613e611655ecd2a7286f00fe7ae6bb9`;
InputDevice `60aea34005d3394576d1775d37ba9971c96b3b5ed67577a19fde3e311a130e69`;
RotaryEncoderInputMapper
`74269eb09d5689671c07b82f36c5f3061811e26c5c0ec99d268a7f6cba03dbba`.

The IDC remains byte-identical (SHA-256
`ae2f9cdd2750a277fea33b2f82185b0bbe7113ad5efa44cb1fde272e8e99cf95`).
No resolution/notches-per-revolution or wake property is invented.
Future guest tests discover by exact name, validate capabilities and four
sysfs ID fields, require the selected IDC, and obtain the current evdev node
and Android deviceId dynamically.

**Production issues remain:** REL_X Hall metadata can move a cursor and WHEEL
can create a separate mouse-wheel event. Do not remove capabilities from the
parity fixture to conceal this. A later reviewed driver/input-policy design
must isolate Hall metadata from Android pointer handling. Wear OS system UI,
app focus and scroll conventions still need runtime verification; AOSP source
analysis is not a Wear OS runtime PASS.

Display wake needs a deliberate Android power/input-policy design after the
kernel/PMIC/suspend audit. Do not mark the internal bezel external or inject a
fake wake key merely to obtain a green test. Tizen's compositor wake request,
CPU IRQ wake and Android display wake are separate mechanisms.

## Executed tests and reproduction

From the repository root:

```sh
python3 ci/android11/rotary/tests/run-physical-host.py --out /your/writable/host-evidence
python3 ci/android11/rotary/tests/test-samsung-source.py /path/to/kernel_samsung_galileo-master.zip
```

Or pass `--samsung-archive /path/to/kernel_samsung_galileo-master.zip` to the
first command. GCC/Clang, Linux input headers, Python 3 and sha256sum suffice;
no Android SDK or hardware access is required. The source archive is never
uploaded by these tests. CI runs without the archive and explicitly reports
that source-extraction test NOT RUN there.

Local results: strict C11 and ASan/UBSan PASS for the actual generator and
probe with intercepted open/ioctl/write/close; ordered requests and actual
arguments checked; default/reverse/wrong-name cases; repeated Hall cycles;
REL_X-only negative control. Seven independently compiled mutants (vendor,
version, wheel, REL_Y, button, direction and Hall mask) are rejected in both
strict and sanitized builds. Existing case-log contamination/device-ID/source
parser tests also pass. Extracted **actual Samsung functions and enums** pass
121 bounded direction cases and 128 work/state cases in both builds.

The source harness excludes optional Knox GearPay/SMC and sleep-monitor branches;
it does not validate the kernel input core, IRQ timing or any probe/power path.

Local LeakSanitizer was disabled because this environment uses ptrace;
ASan/UBSan ran. CI retains leak detection. No revised Android guest runtime,
physical evdev stream, screen wake or hardware driver was exercised.

CI status will be linked after execution. Logs and SHA-256 manifests are
produced in the chosen output directory and uploaded by the host workflow.

## Next gates

1. Re-run the existing API30 rotary-delivery workflow on this branch; verify
   all four updated identity fields, exact IDC, dynamic IDs, both directions,
   repeated events, orientation 180 and cursor side effects. Existing default
   guest test covers the first CW/CCW pair and REL_X-only control; repeated and
   orientation cases still need runtime extension/execution.
2. Choose and review a production solution for cursor/Hall-data isolation and
   bezel display wake. Preserve the capability-parity fixture as a control.
3. Only after separate developer-boot authorization, recovery and driver-safety
   gates could stock/source direction predictions be compared with physical
   Android evdev and focused Wear OS UI behaviour. No such trial is authorized.
