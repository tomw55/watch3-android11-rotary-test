# Android 11 on GitHub Actions

Copy the supplied .github/workflows/android11-boot-proof.yml and ci/android11/
files to the matching paths on the default branch of
tomw55/watch3-android11-rotary-test. Alternatively apply the companion
android11-boot-proof.patch from the repository root. In Actions select
**Android 11 boot and input preflight**, then **Run workflow**. Uncheck
`check_input` for boot proof only. No secrets or third-party service account
are required. Leave the repository public to use GitHub's standard public
runner allowance.

## What the workflow does

- Runs on `ubuntu-24.04` x86_64. Checks access to `/dev/kvm` and invokes
  `emulator -accel-check`. The emulator uses `-accel on` with no software
  fallback. The disposable runner grants its own user access to KVM.
- Uses the official SDK package `system-images;android-30;default;x86_64`.
  It checks the emulator serial, guest CPU ABI, release 11, SDK 30, ADB device
  state and `sys.boot_completed=1`. The workflow pins the Actions revisions,
  selects an exact SDK image package and pins NDK r25c. Emulator, platform-tools
  and the SDK image revision within that package can update. The runner logs
  their installed revisions and the guest fingerprint for comparison.
- If enabled, checks UID 0 through guest ADB and verifies enforcing SELinux.
  Stages the byte-verified IDC in `/data/system/devices/idc` before the
  synthetic node exists. This is an Android 11 configuration lookup path.
  The workflow keeps the system partition and verified boot settings intact.
  It requires EventHub to report that exact IDC for the newly discovered node.
- Compiles the included event-free C probe. The probe runs in the guest shell
  context, opens guest `/dev/uinput`, advertises the parity capabilities,
  creates a node without emitting any input frames, and destroys it after the
  host checks the node. A successful open and the setup ioctls under enforcing
  SELinux are separate from stat-based evidence that a node exists.
- No receiver APK is installed and no full rotary event test is performed.
  Input feasibility PASS covers the prerequisites only. Missing guest
  capabilities or uncertain IDC selection fail the job and preserve the
  independent boot result.

## Expected downloadable evidence

Open the completed Actions run and download **android11-boot-proof**.

| File | Evidence |
|---|---|
| boot-result.txt | Boot PASS with SDK, release, fingerprint and boot property, or failure stage |
| emulator.log, emulator-version.txt, sdk-installed.txt | Start output and installed component versions |
| input-feasibility.txt, rotary-result.txt | Separate prerequisite status and explicit NOT RUN for app dispatch |
| adb-root.txt, guest-capabilities.txt | ADB root response, guest UID/context, SELinux mode and node labels |
| idc-staging.txt, idc-readback.txt | File staging and byte read-back |
| uinput-probe.txt, probe-getevent.txt, input-while-probe-open.txt | Actual guest open/create, evdev capability list, selected IDC and mappers |
| runner.log, job-result.txt, logcat-final.txt, guest-dmesg.txt | Failing stage and best-effort guest diagnostics |

Availability depends on how far the run gets. A boot failure can leave
guest diagnostics empty or populated with connection errors. If the runner
rejects KVM or SDK packages, see runner.log. If the AOSP image lacks
uinput, adbd root, or a usable SELinux policy, retain that failure as
evidence. The job does not switch to permissive SELinux. If another IDC
takes precedence or the event dump uses an unexpected format, inspect
the raw dump instead of inferring a runtime result.

## Local validation

Shell syntax, strict C11 compilation syntax, the fixture manifest and
positive/negative discovery-parser examples passed locally. The local
no-KVM negative check exited 1 at host preflight. GitHub runner boot,
guest SELinux/uinput access, IDC selection and Android event delivery
remain untested. No unpublished files or credentials are required.
