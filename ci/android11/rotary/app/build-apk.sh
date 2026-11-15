#!/bin/sh
set -eu
cd "$(dirname "$0")"
: "${ANDROID_JAR:?Set to the Android 30 android.jar}"
: "${BUILD_TOOLS:?Set to the Android SDK build-tools 33.0.2 directory}"
out=out
mkdir -p "$out/classes" "$out/dex"

if [ -n "${ECJ_JAR:-}" ]; then
    java -jar "$ECJ_JAR" -source 8 -target 8 -classpath "$ANDROID_JAR" \
        -proc:none -d "$out/classes" src/org/watch3/rotary/MainActivity.java
else
    javac --release 8 -classpath "$ANDROID_JAR" \
        -proc:none -d "$out/classes" src/org/watch3/rotary/MainActivity.java
fi
"$BUILD_TOOLS/d8" --lib "$ANDROID_JAR" --min-api 30 --output "$out/dex" \
    "$out/classes/org/watch3/rotary/MainActivity.class"
"$BUILD_TOOLS/aapt" package -f -M AndroidManifest.xml -I "$ANDROID_JAR" -F "$out/resources.apk"

# Normalize input ZIP metadata before alignment and signing.
python3 - <<'PY'
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

out = Path("out")
with ZipFile(out / "resources.apk") as original, ZipFile(out / "unsigned.apk", "w") as apk:
    entries = {name: original.read(name) for name in original.namelist()}
    entries["classes.dex"] = (out / "dex/classes.dex").read_bytes()
    for name, payload in sorted(entries.items()):
        apk.writestr(ZipInfo(name, (1980, 1, 1, 0, 0, 0)), payload,
                     compress_type=ZIP_DEFLATED)
PY
"$BUILD_TOOLS/zipalign" -f 4 "$out/unsigned.apk" "$out/aligned.apk"

# Keep the local test signing key private. Reuse it for APK updates.
keystore=${ROTARY_TEST_KEYSTORE:-"$out/rotary-local-test.p12"}
if [ ! -e "$keystore" ]; then
    keytool -genkeypair -noprompt -keystore "$keystore" -storetype PKCS12 \
        -storepass android -keypass android -alias rotarytest -keyalg RSA -keysize 2048 \
        -validity 3650 -dname "CN=Rotary Guest View Local Test"
fi
"$BUILD_TOOLS/apksigner" sign --ks "$keystore" --ks-key-alias rotarytest \
    --ks-pass pass:android --out "$out/RotaryGuestView.apk" "$out/aligned.apk"
"$BUILD_TOOLS/apksigner" verify --verbose --print-certs "$out/RotaryGuestView.apk"
"$BUILD_TOOLS/zipalign" -c 4 "$out/RotaryGuestView.apk"
"$BUILD_TOOLS/aapt" dump badging "$out/RotaryGuestView.apk" | \
    grep -E '^(package:|sdkVersion:|targetSdkVersion:|application-label:|launchable-activity:)'
(cd "$out" && sha256sum RotaryGuestView.apk > SHA256SUMS)
cat "$out/SHA256SUMS"
