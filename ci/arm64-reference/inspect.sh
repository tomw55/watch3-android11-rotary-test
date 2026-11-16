#!/usr/bin/env bash
set -euo pipefail
out="$PWD/arm64-reference-evidence"
mkdir -p "$out"
stage=download
trap 'rc=$?; printf "stage=%s exit=%s\n" "$stage" "$rc" > "$out/result.txt"' EXIT
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:?Android SDK is required}}
pkg='system-images;android-30;google_apis;arm64-v8a'
sdkmanager --install "$pkg" 2>&1 | tee "$out/sdk-install.log"
image="$sdk/system-images/android-30/google_apis/arm64-v8a"
cp "$image/source.properties" "$out/"
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*16$' "$image/source.properties"
stage=inventory
(cd "$image" && find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 -r sha256sum) > "$out/SHA256SUMS"
file "$image"/* > "$out/file-types.txt"
work=$(mktemp -d)
# SDK system/vendor partitions can be Android sparse or raw ext4.
for part in system vendor; do
    input="$image/$part.img"
    raw="$work/$part.raw"
    if [[ $(od -An -N4 -tx1 "$input" | tr -d '[:space:]') == 3aff26ed ]]; then
        simg2img "$input" "$raw"
    else
        raw="$input"
    fi
    debugfs -R 'ls -l /' "$raw" > "$out/$part-root.txt" 2>&1
    for tree in / /system; do
        for dir in etc etc/init etc/selinux; do
            debugfs -R "ls -l ${tree%/}/$dir" "$raw" >> "$out/$part-layout.txt" 2>&1
        done
    done
    if [[ $part == system ]]; then
        for init in /bin/init /system/bin/init; do
            debugfs -R "dump $init $work/init" "$raw" >> "$out/init-inspection.txt" 2>&1
            if [[ -s "$work/init" ]]; then break; fi
        done
        readelf -h -l -d "$work/init" >> "$out/init-inspection.txt"
        grep -q 'AArch64' "$out/init-inspection.txt"
    fi
done
stage=inventory_complete
printf '%s\n' 'ARM64 init and storage image inventory complete.' \
 'Guest boot, Android policy load and second-stage init: NOT RUN.' > "$out/scope.txt"
