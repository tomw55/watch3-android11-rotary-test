#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p evidence
export CI_SERIAL=emulator-5554
image='system-images;android-30;default;x86_64'
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
export ANDROID_AVD_HOME
ANDROID_AVD_HOME=$(mktemp -d)
stage=host
emu_pid=
adb_ci() { timeout 45 adb -s "$CI_SERIAL" "$@"; }
save_prop() { adb_ci shell getprop "$1" | tr -d '\r'; }
finish() {
    local rc=$?
    trap - EXIT
    set +e
    printf 'stage=%s exit=%s\n' "$stage" "$rc" > evidence/result.txt
    if [[ -n $emu_pid ]]; then
        adb_ci emu kill
        kill "$emu_pid" 2>/dev/null
    fi
    exit "$rc"
}
trap finish EXIT
die() { printf '%s\n' "$*" >&2; exit 1; }
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
printf 'no\n' | avdmanager create avd --force --name policy-api30 --package "$image"
adb start-server
if adb devices | grep -q "^$CI_SERIAL[[:space:]]"; then
    die "$CI_SERIAL is already in use"
fi
stage=boot
emulator -avd policy-api30 -port 5554 -no-window -no-audio -no-boot-anim \
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

stage=collect
adb_ci root | tee evidence/adb-root.txt
timeout 90 adb -s "$CI_SERIAL" wait-for-device
adb_ci shell 'id; getenforce; cat /sys/fs/selinux/policyvers' | tee evidence/guest-policy.txt
[[ $(adb_ci shell getenforce | tr -d '\r') == Enforcing ]] || die 'Expected enforcing reference guest'
adb_ci shell sh -s < compile-guest.sh | tee evidence/secilc.log
stage=result
adb_ci pull /data/local/tmp/watch3-policy-v30/policy.bin evidence/policy-v30.bin
python3 - <<'PYPROOF' | tee evidence/policy-header.txt
import struct
from pathlib import Path
data = Path("evidence/policy-v30.bin").read_bytes()
magic, identifier_len = struct.unpack_from("<II", data)
assert magic == 0xf97cff8c and data[8:8 + identifier_len] == b"SE Linux"
version, = struct.unpack_from("<I", data, 8 + identifier_len)
assert version == 30, version
print("PASS policy binary header version=30")
PYPROOF
sha256sum evidence/policy-v30.bin | tee evidence/policy.sha256
stage=complete
