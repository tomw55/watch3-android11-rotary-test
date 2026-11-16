#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p evidence
export CI_SERIAL=emulator-5554
image='system-images;android-30;default;x86_64'
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
export ANDROID_AVD_HOME
ANDROID_AVD_HOME=$(mktemp -d)
emu_pid=
stage=host_preflight
adb_ci() { timeout 30 adb -s "$CI_SERIAL" "$@"; }
save_prop() { adb_ci shell getprop "$1" | tr -d '\r'; }
finish() {
    local rc=$?
    trap - EXIT
    set +e
    printf 'stage=%s exit=%s\n' "$stage" "$rc" | tee evidence/result.txt
    if [[ -n $emu_pid ]]; then
        adb_ci logcat -d -v threadtime > evidence/logcat.txt 2>&1
        adb_ci emu kill
        kill "$emu_pid" 2>/dev/null
    fi
    exit "$rc"
}
trap finish EXIT
die() { echo "FAIL [$stage] $*" >&2; exit 1; }

uname -a
df -h .
[[ -c /dev/kvm ]] || die '/dev/kvm unavailable'
sudo chown "$(id -u)" /dev/kvm
[[ -r /dev/kvm && -w /dev/kvm ]] || die 'KVM access denied'
stage=sdk_install
[[ -n $sdk ]] || die 'Android SDK home unavailable'
export PATH="$sdk/platform-tools:$sdk/emulator:$sdk/cmdline-tools/latest/bin:$PATH"
# The standard runner provides an SDK and sdkmanager. Fetch only official packages.
sdkmanager --install platform-tools emulator "$image"
sdkmanager --list_installed > evidence/sdk-installed.txt
emulator -version > evidence/emulator-version.txt 2>&1
emulator -accel-check
adb version
printf 'no\n' | avdmanager create avd --force --name binder-api30 --package "$image"
adb start-server
if adb devices | grep -q "^$CI_SERIAL[[:space:]]"; then
    die "$CI_SERIAL is already in use"
fi
stage=boot
emulator -avd binder-api30 -port 5554 -no-window -no-audio -no-boot-anim \
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

stage=guest_identity
selinux=$(adb_ci shell getenforce | tr -d '\r')
arch=$(adb_ci shell uname -m | tr -d '\r')
printf 'kernel_arch=%s\nselinux=%s\n' "$arch" "$selinux" | tee evidence/guest-security.txt
[[ $arch == x86_64 && $selinux == Enforcing ]] || die 'Expected x86_64 and enforcing SELinux'

stage=apk_build
sdkmanager --install 'platforms;android-30' 'build-tools;33.0.2'
bt="$sdk/build-tools/33.0.2"
jar="$sdk/platforms/android-30/android.jar"
mkdir -p build/classes build/dex
javac -version
javac --release 8 -cp "$jar" -d build/classes Probe.java
"$bt/d8" --min-api 30 --lib "$jar" --output build/dex build/classes/org/watch3/cibinder/*.class
"$bt/aapt" package -f -M AndroidManifest.xml -I "$jar" -F build/unsigned.apk
(cd build/dex && "$bt/aapt" add ../unsigned.apk classes.dex)
"$bt/zipalign" -f 4 build/unsigned.apk build/aligned.apk
keytool -genkeypair -alias ci -keyalg RSA -keysize 2048 -validity 30 \
    -keystore build/ci.p12 -storepass test-only -dname 'CN=Disposable Watch3 CI'
"$bt/apksigner" sign --ks build/ci.p12 --ks-pass pass:test-only \
    --out evidence/BinderSmoke.apk build/aligned.apk
"$bt/apksigner" verify --verbose evidence/BinderSmoke.apk | tee evidence/signature.txt
sha256sum evidence/BinderSmoke.apk | tee evidence/apk.sha256

stage=binder
adb_ci install evidence/BinderSmoke.apk
nonce=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
adb_ci shell am start -W -n org.watch3.cibinder/.Probe --es nonce "$nonce" | tee evidence/activity.txt
for ((i=0; i<30; i++)); do
    adb_ci logcat -d -v threadtime -s Watch3BinderCI:I > evidence/binder-log.txt
    if grep -q "CLIENT $nonce" evidence/binder-log.txt; then break; fi
    sleep 1
done
python3 check.py "$nonce" evidence/binder-log.txt | tee evidence/binder-proof.txt
stage=complete
