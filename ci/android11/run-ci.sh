#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p evidence
exec > >(tee evidence/runner.log) 2>&1
export CI_SERIAL=emulator-5554
image='system-images;android-30;default;x86_64'
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
export ANDROID_AVD_HOME
ANDROID_AVD_HOME=$(mktemp -d)
stage=host_preflight
emu_pid=
adb_ci() { timeout 20 adb -s "$CI_SERIAL" "$@"; }
save_prop() { adb_ci shell getprop "$1" | tr -d '\r'; }
finish() {
    local rc=$?
    trap - EXIT
    set +e
    printf 'stage=%s exit=%s\n' "$stage" "$rc" | tee evidence/job-result.txt
    if [[ -n $emu_pid ]]; then
        adb_ci shell getprop > evidence/guest-getprop.txt 2>&1
        adb_ci shell dumpsys input > evidence/input-final.txt 2>&1
        adb_ci shell getevent -lp > evidence/getevent-final.txt 2>&1
        adb_ci logcat -d -v threadtime > evidence/logcat-final.txt 2>&1
        adb_ci shell dmesg > evidence/guest-dmesg.txt 2>&1
        adb_ci emu kill
        kill "$emu_pid" 2>/dev/null
    fi
    if ((rc != 0)); then
        if [[ $stage == rotary_* && $(head -c 7 evidence/rotary-result.txt) == 'NOT RUN' ]]; then
            printf 'FAIL stage=%s; see runner.log and diagnostics\n' "$stage" > evidence/rotary-result.txt
        fi
        case "$stage" in
            host_preflight|sdk_install|boot) printf 'FAIL stage=%s\n' "$stage" > evidence/boot-result.txt ;;
            rotary_*) ;;
            *) printf 'FAIL stage=%s; see runner.log and guest diagnostics\n' "$stage" > evidence/input-feasibility.txt ;;
        esac
    fi
    exit "$rc"
}
trap finish EXIT
die() { echo "FAIL [$stage] $*" >&2; exit 1; }

printf 'NOT RUN\n' > evidence/rotary-result.txt
printf 'NOT RUN\n' > evidence/boot-result.txt
printf 'NOT RUN\n' > evidence/input-feasibility.txt
uname -a
df -h .
[[ -c /dev/kvm ]] || die '/dev/kvm unavailable'
sudo chown "$(id -u)" /dev/kvm
[[ -r /dev/kvm && -w /dev/kvm ]] || die 'KVM access denied'
sha256sum -c fixture.sha256
stage=sdk_install
[[ -n $sdk ]] || die 'Android SDK home unavailable'
export PATH="$sdk/platform-tools:$sdk/emulator:$sdk/cmdline-tools/latest/bin:$PATH"
# The standard runner provides an SDK and sdkmanager. Fetch only official packages.
sdkmanager --install platform-tools emulator "$image"
sdkmanager --list_installed > evidence/sdk-installed.txt
emulator -version > evidence/emulator-version.txt 2>&1
emulator -accel-check
adb version
printf 'no\n' | avdmanager create avd --force --name rotary-api30 --package "$image"
adb start-server
if adb devices | grep -q "^$CI_SERIAL[[:space:]]"; then
    die "$CI_SERIAL is already in use"
fi
stage=boot
emulator -avd rotary-api30 -port 5554 -no-window -no-audio -no-boot-anim \
    -no-snapshot -gpu swiftshader_indirect -accel on > evidence/emulator.log 2>&1 &
emu_pid=$!
for ((i=0; i<150; i++)); do
    kill -0 "$emu_pid" || die 'emulator exited; see emulator.log'
    if [[ $(timeout 3 adb -s "$CI_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d "\r") == 1 ]]; then break; fi
    sleep 2
done
[[ $(adb_ci get-state) == device && $(save_prop sys.boot_completed) == 1 ]] ||
    die 'ADB device or completed boot missing'
[[ $(save_prop ro.build.version.sdk) == 30 && $(save_prop ro.build.version.release) == 11 ]] ||
    die 'Guest is not Android 11/API 30'
[[ $(save_prop ro.kernel.qemu) == 1 && $(save_prop ro.product.cpu.abi) == x86_64 ]] ||
    die 'Unexpected guest identity or ABI'
{
    printf 'PASS Android 11 API 30 boot and ADB\n'
    for key in sys.boot_completed ro.build.version.release ro.build.version.sdk ro.build.fingerprint ro.build.type ro.debuggable; do
        printf '%s=%s\n' "$key" "$(save_prop "$key")"
    done
} | tee evidence/boot-result.txt

if [[ ${CHECK_INPUT:-true} == false ]]; then
    printf 'NOT RUN — input preflight disabled by workflow input\n' > evidence/input-feasibility.txt
    stage=complete
    exit 0
fi

stage=guest_root
adb_ci root | tee evidence/adb-root.txt
for ((i=0; i<20; i++)); do
    if [[ $(timeout 3 adb -s "$CI_SERIAL" shell id -u 2>/dev/null | tr -d '\r') == 0 ]]; then break; fi
    sleep 1
done
[[ $(adb_ci shell id -u | tr -d '\r') == 0 ]] || die 'guest adbd did not grant UID 0'
adb_ci shell 'id; id -Z; getenforce; ls -lZ /dev/uinput /dev/input || true' |
    tee evidence/guest-capabilities.txt
[[ $(adb_ci shell getenforce | tr -d '\r') == Enforcing ]] || die 'Expected enforcing guest'
adb_ci shell test -c /dev/uinput || die 'No guest /dev/uinput character device'

stage=idc_staging
idc=/data/system/devices/idc/tizen_detent.idc
adb_ci shell "mkdir -p /data/system/devices/idc && test ! -e $idc" ||
    die 'Cannot prepare guest data IDC directory, or an IDC already exists'
adb_ci push fixture/tizen_detent.idc "$idc"
adb_ci shell "chown 0:0 $idc && chmod 0644 $idc && restorecon -R /data/system/devices && ls -lZ $idc" |
    tee evidence/idc-staging.txt
adb_ci exec-out cat "$idc" > evidence/idc-readback.txt
cmp fixture/tizen_detent.idc evidence/idc-readback.txt || die 'IDC bytes differ'

stage=build_uinput_probe
sdkmanager --install 'ndk;25.2.9519653'
ndk="$sdk/ndk/25.2.9519653/toolchains/llvm/prebuilt/linux-x86_64/bin"
"$ndk/x86_64-linux-android30-clang" -std=c11 -Wall -Wextra -Werror -O2 \
    fixture/uinput-probe.c -o uinput-probe
file uinput-probe > evidence/probe-abi.txt
adb_ci push uinput-probe /data/local/tmp/uinput-probe
adb_ci shell chmod 0755 /data/local/tmp/uinput-probe

stage=guest_uinput_idc_selection
python3 check-discovery.py
printf '%s\n' 'PASS prerequisites: root, enforcing SELinux, uinput open/create, exact IDC selected, both mappers visible.' \
    'Full focused-app rotary delivery is NOT RUN.' > evidence/input-feasibility.txt
if [[ ${CHECK_ROTARY:-false} == true ]]; then
    stage=rotary_build
    sha256sum -c rotary-sources.sha256
    sdkmanager --install 'platforms;android-30' 'build-tools;33.0.2'
    sdkmanager --list_installed > evidence/sdk-installed.txt
    javac -version
    ANDROID_JAR="$sdk/platforms/android-30/android.jar" BUILD_TOOLS="$sdk/build-tools/33.0.2" \
        sh rotary/app/build-apk.sh > evidence/rotary-apk-build.log 2>&1
    cp rotary/app/out/RotaryGuestView.apk evidence/RotaryGuestView.apk
    (cd evidence && sha256sum RotaryGuestView.apk > RotaryGuestView.apk.sha256)
    "$ndk/x86_64-linux-android30-clang" -std=c11 -Wall -Wextra -Werror -O2 \
        rotary/rotary-uinput.c -o rotary-uinput-ci
    file rotary-uinput-ci > evidence/rotary-generator-abi.txt
    sha256sum rotary-uinput-ci > evidence/rotary-generator.sha256

    stage=rotary_install
    adb_ci install evidence/RotaryGuestView.apk
    adb_ci push rotary-uinput-ci /data/local/tmp/rotary-uinput-ci
    adb_ci shell chmod 0755 /data/local/tmp/rotary-uinput-ci
    adb_ci shell input keyevent KEYCODE_WAKEUP
    adb_ci shell wm dismiss-keyguard
    adb_ci shell settings put system accelerometer_rotation 0
    adb_ci shell settings put system user_rotation 0
    adb_ci shell am start -W -n org.watch3.rotary/.MainActivity

    stage=rotary_events
    python3 test-delivery.py
fi
stage=complete
